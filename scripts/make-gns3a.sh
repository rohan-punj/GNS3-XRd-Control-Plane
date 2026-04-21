#!/bin/bash
#
# make-gns3a.sh
# ---------------------------------------------------------------------------
# Generate a version-specific .gns3a appliance file for an XRd image.
# Use this when you want multiple XRd versions (24.4.1, 25.1.1, etc.)
# available side-by-side in the same GNS3 install.
#
# Each generated file has:
#   - a unique appliance_id (UUID) so GNS3 treats it as a distinct appliance
#   - a unique display name ("Cisco XRd Control Plane 24.4.1")
#   - the matching Docker image tag (xrd-cp-gns3:24.4.1)
#
# Usage:
#   ./make-gns3a.sh <version> [adapters] [image-tag]
#
# Examples:
#   ./make-gns3a.sh 24.4.1                     # default 4 adapters, tag xrd-cp-gns3:24.4.1
#   ./make-gns3a.sh 25.1.1 8                   # 8 adapters
#   ./make-gns3a.sh my-lab 4 xrd-cp-gns3:dev   # custom tag
#
# Output is written to cisco-xrd-controlplane-<version>.gns3a in the
# package root.
# ---------------------------------------------------------------------------
set -euo pipefail

VERSION="${1:-}"
ADAPTERS="${2:-4}"
IMAGE="${3:-xrd-cp-gns3:$VERSION}"

usage() {
  sed -n '2,24p' "$0"
  exit 1
}

[[ -n "$VERSION" ]] || usage
[[ "$ADAPTERS" =~ ^[0-9]+$ ]] || { echo "ERROR: adapters must be an integer" >&2; exit 1; }
(( ADAPTERS >= 2 )) || { echo "ERROR: need at least 2 adapters (1 mgmt + 1 data)" >&2; exit 1; }

# Generate a stable UUID from the image tag + version so re-running produces
# the same ID (so re-imports update the same appliance rather than creating
# duplicates).
UUID=$(python3 -c "
import uuid
ns = uuid.UUID('372b422c-1124-4449-94da-8b17c77719ac')  # package namespace
print(uuid.uuid5(ns, '$IMAGE'))
")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Build XR_INTERFACES string for the chosen adapter count
XR_INTERFACES=""
for ((i=1; i<ADAPTERS; i++)); do
  XR_INTERFACES+="linux:eth${i},xr_name=Gi0/0/0/$((i-1));"
done
XR_INTERFACES="${XR_INTERFACES%;}"

OUT="$PKG_ROOT/cisco-xrd-controlplane-${VERSION}.gns3a"

python3 - "$UUID" "$VERSION" "$IMAGE" "$ADAPTERS" "$XR_INTERFACES" "$OUT" <<'PYEOF'
import json, sys

uuid_str, version, image, adapters, xr_ifs, out = sys.argv[1:7]
adapters = int(adapters)

env = (
    "XR_FIRST_BOOT_CONFIG=/firstboot.cfg\n"
    "XR_MGMT_INTERFACES=linux:eth0,xr_name=MgmtEth0/RP0/CPU0/0,chksum,snoop_v4,snoop_v6\n"
    f"XR_INTERFACES={xr_ifs}"
)

appliance = {
    "appliance_id": uuid_str,
    "name": f"Cisco XRd Control Plane {version}",
    "category": "router",
    "description": (
        f"Cisco IOS XR {version} running as a Docker container (XRd Control Plane variant).\n\n"
        "XRd Control Plane is designed for routing protocol labs and automation. It runs\n"
        "the full IOS XR control plane with Linux-kernel data plane — ideal for BGP/OSPF\n"
        "/IS-IS/MPLS/SR topologies that don't need raw forwarding performance.\n\n"
        f"Expects the custom image '{image}' on the GNS3 VM, built via build-image.sh\n"
        "from the official Cisco XRd image of this version.\n\n"
        "Default login: admin / cisco\n"
        "Enter XR CLI from the Linux prompt with: /pkg/bin/xr_cli.sh"
    ),
    "vendor_name": "Cisco",
    "vendor_url": "https://www.cisco.com/",
    "documentation_url": "https://xrdocs.io/virtual-routing/",
    "product_name": "XRd Control Plane",
    "product_url": "https://www.cisco.com/c/en/us/products/collateral/routers/ios-xrd/datasheet-c78-744298.html",
    "registry_version": 6,
    "status": "experimental",
    "maintainer": "Lab User",
    "maintainer_email": "lab@example.com",
    "usage": (
        "Before importing this appliance:\n\n"
        f"1. Load the official Cisco XRd {version} image on the GNS3 VM:\n"
        f"     docker load -i xrd-control-plane-{version}.tar.gz\n\n"
        f"2. Build the custom image using the included Dockerfile:\n"
        f"     ./build-image.sh ios-xr/xrd-control-plane:{version} {image}\n\n"
        "3. Prepare the GNS3 VM for XRd (one-time, shared by all XRd versions):\n"
        "     sudo ./scripts/prep-gns3-vm.sh\n"
        "     sudo python3 ./scripts/patch-gns3-docker-ast.py\n\n"
        "Then import this .gns3a file into GNS3.\n\n"
        f"Defaults: {adapters} adapters, Login: admin / cisco\n\n"
        "Note: in GNS3 3.x, the Maximum RAM and Maximum CPU fields default to 0\n"
        "after import. Edit the template to set RAM=4096 MB and CPU=1 before\n"
        "starting nodes (XRd Control Plane needs ~4 GiB minimum)."
    ),
    "symbol": ":/symbols/affinity/square/blue/router.svg",
    "first_port_name": "Mg0/RP0/CPU0/0",
    "port_name_format": "Gi0/0/0/{port0}",
    "docker": {
        "adapters": adapters,
        "image": image,
        "console_type": "telnet",
        "start_command": "",
        "environment": env
    }
}

with open(out, "w") as f:
    json.dump(appliance, f, indent=4)
    f.write("\n")
PYEOF

echo "OK: generated $OUT"
echo ""
echo "Next steps:"
echo "  1. (If not done) Build the Docker image for this version:"
echo "       ./docker-image/build-image.sh ios-xr/xrd-control-plane:$VERSION $IMAGE"
echo ""
echo "  2. Import the appliance in GNS3:"
echo "       File -> Import appliance -> select $OUT"
echo ""
echo "  3. After import, edit the template to set Maximum RAM=4096 MB, CPU=1"
