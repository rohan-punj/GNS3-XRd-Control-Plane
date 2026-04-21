#!/bin/bash
#
# gns3-xrd-env.sh
# -----------------------------------------------------------------------------
# Generates XRd environment variables for a given number of adapters,
# adapted from the EVE-NG prep_xrd.sh script for use with GNS3.
#
# In GNS3, eth0 is the management interface and eth1..ethN-1 are data ports
# mapped to Gi0/0/0/0 .. Gi0/0/0/N-2.
#
# Usage:
#   ./gns3-xrd-env.sh <num_adapters> [output_file|--gns3|--json]
#
# Examples:
#   ./gns3-xrd-env.sh 4                 # print in GNS3 template paste format
#   ./gns3-xrd-env.sh 8 xrd.env         # write env vars to xrd.env
#   ./gns3-xrd-env.sh 16 --json         # print JSON snippet for .gns3a file
# -----------------------------------------------------------------------------
set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $0 <num_adapters> [output_file|--gns3|--json]

  num_adapters   Total interfaces including eth0 (management).
                 Must be >= 2 (1 mgmt + at least 1 data port).
  output_file    Optional file path to write env vars to.
  --gns3         (Default) Print in GNS3 template paste-ready format.
  --json         Print a JSON snippet suitable for splicing into a .gns3a file.

Examples:
  $0 4
  $0 8 xrd.env
  $0 16 --json
EOF
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || usage

count="$1"
output="${2:---gns3}"

# Validate count
if ! [[ "$count" =~ ^[0-9]+$ ]] || (( count < 2 )); then
  echo "ERROR: num_adapters must be an integer >= 2" >&2
  usage
fi

# Management interface (eth0 -> MgmtEth0/RP0/CPU0/0)
mgmt="linux:eth0,xr_name=MgmtEth0/RP0/CPU0/0,chksum,snoop_v4,snoop_v6"

# Data interfaces (eth1..ethN-1 -> Gi0/0/0/0..Gi0/0/0/N-2)
xr=""
for ((i=1; i<count; i++)); do
  xr+="linux:eth${i},xr_name=Gi0/0/0/$((i-1));"
done
# Strip trailing semicolon
xr="${xr%;}"

case "$output" in
  --gns3)
    echo "# Paste the following into the GNS3 Docker template's"
    echo "# 'Environment variables' field (one per line):"
    echo "# ---------------------------------------------------"
    echo "XR_FIRST_BOOT_CONFIG=/firstboot.cfg"
    echo "XR_MGMT_INTERFACES=${mgmt}"
    echo "XR_INTERFACES=${xr}"
    echo "# ---------------------------------------------------"
    echo "# Adapters: $count  (eth0 = mgmt, eth1..eth$((count-1)) = Gi0/0/0/0..Gi0/0/0/$((count-2)))"
    ;;
  --json)
    echo "# JSON snippet for the .gns3a file's \"docker\" block:"
    echo "# ---------------------------------------------------"
    cat <<EOF
        "adapters": ${count},
        "environment": "XR_FIRST_BOOT_CONFIG=/firstboot.cfg\\nXR_MGMT_INTERFACES=${mgmt}\\nXR_INTERFACES=${xr}"
EOF
    ;;
  *)
    {
      echo "XR_FIRST_BOOT_CONFIG=/firstboot.cfg"
      echo "XR_MGMT_INTERFACES=${mgmt}"
      echo "XR_INTERFACES=${xr}"
    } > "$output"
    echo "OK: wrote $count-adapter XRd env vars to $output" >&2
    ;;
esac
