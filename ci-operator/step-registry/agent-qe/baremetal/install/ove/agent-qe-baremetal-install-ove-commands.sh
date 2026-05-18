#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
if [ "${DISCONNECTED}" == "true" ]; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")

yq -r e -o=j -I=0 ".[0].host" "${SHARED_DIR}/hosts.yaml" >"${SHARED_DIR}"/host-id.txt

function mount_virtual_media() {
  local host="${1}"
  local iso_path="${2}"
  echo "Mounting the ISO image in #${host} via virtual media..."
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" mount.vmedia "${host}" "${iso_path}"
  local ret=$?
  if [ $ret -ne 0 ]; then
    echo "Failed to mount the ISO image in #${host} via virtual media."
    touch /tmp/virtual_media_mount_failure
    return 1
  fi
  return 0
}

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  (
   name=$(echo "$bmhost" | jq -r '.name')
   host=$(echo "$bmhost" | jq -r '.host')
   transfer_protocol_type=$(echo "$bmhost" | jq -r '.transfer_protocol_type // ""')
   if [ "${transfer_protocol_type}" == "cifs" ]; then
     IP_ADDRESS="$(dig +short "${AUX_HOST}")"
     iso_path="${IP_ADDRESS}/isos/${AGENT_ISO}"
   else
     # Assuming HTTP or HTTPS
     # IF _SNAPSHOT_ is not empty, this is a konflux job
     OVE_ISO_STORAGE_HOST=$(<"${CLUSTER_PROFILE_DIR}/ove_iso_storage_host")
     if [ ! -z "${SNAPSHOT}" ]; then
        iso_path="${transfer_protocol_type:-http}://${OVE_ISO_STORAGE_HOST}/${CLUSTER_NAME}.agent-ove.x86_64.iso"
     else
        iso_path="${transfer_protocol_type:-http}://192.168.80.2/${AGENT_ISO}"
     fi
   fi
   vendor=$(echo "$bmhost" | jq -r '.vendor')

   if [[ "${vendor}" == "hpe" ]]; then
     bmc_user=$(echo "$bmhost" | jq -r '.bmc_user')
     bmc_pass=$(echo "$bmhost" | jq -r '.bmc_pass')
     bmc_address=$(echo "$bmhost" | jq -r '.bmc_address')
     boot_selection="UefiHttp"
     steps=(
       "Configuring http boot Url|PATCH|/Bios/Settings/|{\"Attributes\":{\"PreBootNetwork\":\"Auto\",\"UrlBootFile\":\"$iso_path\"}}"
       "Setting serial console|PATCH|/Bios/Settings/|{\"Attributes\":{\"RedirectionAfterPOST\":\"Enabled\"}}"
       "Applying one time boot|PATCH||{\"Boot\":{\"BootSourceOverrideTarget\":\"$boot_selection\",\"BootSourceOverrideEnabled\":\"Once\"}}"
       "Powering on the host|POST|/Actions/ComputerSystem.Reset/|{\"ResetType\":\"On\"}"
     )
     for step in "${steps[@]}"; do
       IFS="|" read -r desc method uri payload <<< "$step"
       echo "$name $desc..."

       # Run curl silently (-s), capture stdout, extract MessageId from iLO JSON if present
       resp=$(curl -s -k -u "${bmc_user}:${bmc_pass}" -X "$method" \
         "https://${bmc_address}/redfish/v1/Systems/1${uri}" \
         -H "Content-Type: application/json" -d "$payload")

       # Print simple completion or format explicit iLO notices cleanly
       msg=$(echo "$resp" | sed -n 's/.*"MessageId":"\([^"]*\)".*/\1/p')
       [[ -n "$msg" ]] && echo "   -> Result: $msg" || echo "   -> Done."
     done
   else
     mount_virtual_media "${host}" "${iso_path}"
     echo "Power on #${host} (${name})..."
     if ! timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" prepare_host_for_boot "${host}" "${BOOT_MODE}"; then
       echo "Failed to power on ${host} (${name})"
     fi
   fi
  ) &
  sleep 2s
done
sleep 18m
#wait
#
#if [ -f /tmp/virtual_media_mount_failed ]; then
#  echo "Failed to mount the ISO image in one or more hosts"
#  exit 1
#fi