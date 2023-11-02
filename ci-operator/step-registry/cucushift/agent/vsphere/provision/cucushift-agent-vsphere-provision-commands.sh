#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM
# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - failed to acquire lease"
  exit 1
fi

export HOME=/tmp

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
declare target_hw_version
declare vsphere_datacenter
declare vsphere_datastore
declare vsphere_portgroup
source "${SHARED_DIR}/vsphere_context.sh"

installer_dir=/tmp/installer

echo "$(date -u --rfc-3339=seconds) - Copying agent files from shared dir..."

mkdir -p "${installer_dir}/auth"
pushd ${installer_dir}

cp -t "${installer_dir}" \
  "${SHARED_DIR}/.openshift_install_state.json"

cp -t "${installer_dir}/auth" \
  "${SHARED_DIR}/kubeadmin-password" \
  "${SHARED_DIR}/kubeconfig"

export KUBECONFIG="${installer_dir}/auth/kubeconfig"

agent_iso=$(<"${SHARED_DIR}"/agent-iso.txt)

source "${SHARED_DIR}/govc.sh"

total_host="$((MASTERS + WORKERS))"
declare -a mac_addresses
mapfile -t mac_addresses <"${SHARED_DIR}"/mac-addresses.txt
declare -a hostnames
mapfile -t hostnames <"${SHARED_DIR}"/hostnames.txt

folder_name=$(<"${SHARED_DIR}"/cluster-name.txt)
govc folder.create "/${vsphere_datacenter}/vm/${folder_name}"

[[ ${MASTERS} -eq 1 ]] && cpu="8" || cpu="4"

for ((i = 0; i < total_host; i++)); do
  vm_name=${hostnames[$i]}
  echo "creating Vm $vm_name.."
  govc vm.create \
    -m=16384 \
    -g=coreos64Guest \
    -c=${cpu} \
    -disk=120GB \
    -net="${vsphere_portgroup}" \
    -firmware=efi \
    -on=false \
    -version vmx-"${target_hw_version}" \
    -folder="/${vsphere_datacenter}/vm/${folder_name}" \
    -iso-datastore="${vsphere_datastore}" \
    -iso=agent-installer-isos/"${agent_iso}" \
    "$vm_name"

  govc vm.change \
    -e="disk.EnableUUID=1" \
    -vm="/${vsphere_datacenter}/vm/${folder_name}/${vm_name}"

  govc vm.change \
    -nested-hv-enabled=true \
    -vm="/${vsphere_datacenter}/vm/${folder_name}/${vm_name}"

  govc device.boot \
    -secure \
    -vm="/${vsphere_datacenter}/vm/${folder_name}/${vm_name}"

  govc vm.network.change \
    -vm="/${vsphere_datacenter}/vm/${folder_name}/${vm_name}" \
    -net "${vsphere_portgroup}" \
    -net.address "${mac_addresses[$i]}" ethernet-0

  govc vm.power \
    -on=true "/${vsphere_datacenter}/vm/${folder_name}/${vm_name}"
done
## Monitor for `bootstrap-complete`
echo "$(date -u --rfc-3339=seconds) - Monitoring for bootstrap to complete"
openshift-install --dir="${installer_dir}" agent wait-for bootstrap-complete &

if ! wait $!; then
  echo "ERROR: Bootstrap failed. Aborting execution."
  exit 1
fi

if [ "${MASTERS}" -ne 1 ]; then
  # Remove the Taint manually
  oc wait --for=condition=Ready node --all --timeout=15m
  node_count="$(oc get nodes -o json | jq -r '.items | length')"
  if [ "$node_count" -eq $total_host ]; then
    nodes=$(oc get nodes -o wide | awk '{print $1}' | tail -n +2)
    for NODE in $nodes; do
      oc adm taint nodes "$NODE" node.cloudprovider.kubernetes.io/uninitialized:NoSchedule- || true
    done
  else
    echo "$(date -u --rfc-3339=seconds) - Waiting for all nodes to be ready. Currently, $node_count are ready, but the expected number of nodes is $total_host."
    sleep 15
  fi
fi

## Monitor for cluster completion/.
echo "$(date -u --rfc-3339=seconds) - Monitoring for cluster completion..."

# When using line-buffering there is a potential issue that the buffer is not filled (or no new line) and this waits forever
# or in our case until the four hour CI timer is up.
openshift-install --dir="${installer_dir}" agent wait-for install-complete 2>&1 | stdbuf -o0 grep -v password &

if ! wait "$!"; then
  echo "ERROR: Installation failed. Aborting execution."
  exit 1
fi
