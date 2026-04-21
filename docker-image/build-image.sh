#!/bin/bash
#
# build-image.sh
# ---------------------------------------------------------------------------
# Build the custom XRd GNS3 image from an official Cisco XRd Control Plane
# image. Supports versioned tagging so multiple XRd versions can coexist
# in the same GNS3 VM.
#
# Usage:
#   ./build-image.sh <base-image-tag> [output-tag]
#
# Examples:
#   # Single version (default tag: xrd-cp-gns3:latest — used by the basic
#   # .gns3a appliance file):
#   ./build-image.sh ios-xr/xrd-control-plane:24.4.1
#
#   # Versioned tag (for multiple XRd versions side-by-side):
#   ./build-image.sh ios-xr/xrd-control-plane:24.4.1  xrd-cp-gns3:24.4.1
#   ./build-image.sh ios-xr/xrd-control-plane:25.1.1  xrd-cp-gns3:25.1.1
#
#   # Pair each with its own appliance file via:
#   #   ../scripts/make-gns3a.sh 24.4.1
#   #   ../scripts/make-gns3a.sh 25.1.1
# ---------------------------------------------------------------------------
set -euo pipefail

BASE="${1:-}"
OUTPUT_TAG="${2:-xrd-cp-gns3:latest}"

usage() {
  sed -n '2,24p' "$0"
  exit 1
}

[[ -n "$BASE" ]] || usage

if ! docker image inspect "$BASE" >/dev/null 2>&1; then
  echo "ERROR: base image '$BASE' not found locally." >&2
  echo "       Load it first:   docker load -i xrd-control-plane-<version>.tar.gz" >&2
  echo "       Then list tags:  docker images | grep xrd" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Building image '$OUTPUT_TAG' from base '$BASE' ..."
docker build \
  --build-arg "BASE_IMAGE=$BASE" \
  -t "$OUTPUT_TAG" \
  "$SCRIPT_DIR"

echo ""
echo "OK: image '$OUTPUT_TAG' is ready."
echo ""
echo "If this is your only XRd version, import the default appliance:"
echo "    cisco-xrd-controlplane.gns3a"
echo ""
echo "For multiple XRd versions, generate a per-version appliance file:"
echo "    ../scripts/make-gns3a.sh ${OUTPUT_TAG##*:}"
