#!/bin/bash
#
# prep-gns3-vm.sh
# ---------------------------------------------------------------------------
# Prepares the GNS3 VM to run Cisco XRd containers. Applies kernel/sysctl
# settings that XRd requires but GNS3's stock VM doesn't set by default:
#
#   - fs.inotify.max_user_instances   (XRd needs ~4000 per node)
#   - fs.inotify.max_user_watches     (raise if below recommended)
#   - fs.file-max                      (XRd opens many files)
#   - FUSE kernel module loaded at boot
#
# Safe to re-run (idempotent) and reversible with --revert.
#
# Usage:
#   sudo ./prep-gns3-vm.sh                # apply all prerequisites
#   sudo ./prep-gns3-vm.sh --status       # check current state
#   sudo ./prep-gns3-vm.sh --revert       # remove our sysctl file
# ---------------------------------------------------------------------------
set -euo pipefail

SYSCTL_FILE=/etc/sysctl.d/99-xrd.conf
MODULES_FILE=/etc/modules-load.d/xrd-fuse.conf

# Tune these to match your VM size; defaults are sized for ~15 concurrent XRd nodes
INSTANCES=64000
WATCHES=524288
FILE_MAX=1000000

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run with sudo." >&2
    exit 1
  fi
}

status() {
  echo "=== Current inotify / fs settings ==="
  sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches fs.file-max

  echo ""
  echo "=== Persistent config files ==="
  if [[ -f "$SYSCTL_FILE" ]]; then
    echo "sysctl config: $SYSCTL_FILE (present)"
    cat "$SYSCTL_FILE" | sed 's/^/  /'
  else
    echo "sysctl config: $SYSCTL_FILE (absent)"
  fi

  if [[ -f "$MODULES_FILE" ]]; then
    echo "modules config: $MODULES_FILE (present)"
    cat "$MODULES_FILE" | sed 's/^/  /'
  else
    echo "modules config: $MODULES_FILE (absent)"
  fi

  echo ""
  echo "=== FUSE kernel module ==="
  if lsmod | grep -q '^fuse'; then
    echo "FUSE: loaded"
  else
    echo "FUSE: NOT loaded"
  fi

  echo ""
  echo "=== Docker daemon ==="
  if command -v docker &>/dev/null; then
    docker info 2>/dev/null | grep -E "Server Version|Operating System|Kernel Version|Total Memory|CPUs" || true
  else
    echo "Docker: not installed (this is not the GNS3 VM?)"
  fi
}

apply() {
  require_root

  echo "Writing $SYSCTL_FILE ..."
  cat > "$SYSCTL_FILE" <<EOF
# GNS3-XRD-PREP: kernel settings required by Cisco XRd containers
fs.inotify.max_user_instances = $INSTANCES
fs.inotify.max_user_watches   = $WATCHES
fs.file-max                    = $FILE_MAX
EOF

  echo "Applying sysctls now ..."
  sysctl --system >/dev/null

  echo "Ensuring FUSE module loads at boot ..."
  echo "fuse" > "$MODULES_FILE"
  if ! lsmod | grep -q '^fuse'; then
    modprobe fuse || echo "WARN: could not load fuse module (kernel may lack it)" >&2
  fi

  echo ""
  echo "=== Applied settings ==="
  sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches fs.file-max
  echo ""
  echo "OK: GNS3 VM is prepared for XRd."
  echo "    Settings persist across reboots via $SYSCTL_FILE and $MODULES_FILE."
}

revert() {
  require_root
  local changed=0
  if [[ -f "$SYSCTL_FILE" ]]; then
    rm -f "$SYSCTL_FILE"
    echo "Removed $SYSCTL_FILE"
    changed=1
  fi
  if [[ -f "$MODULES_FILE" ]]; then
    rm -f "$MODULES_FILE"
    echo "Removed $MODULES_FILE"
    changed=1
  fi
  if [[ $changed -eq 1 ]]; then
    sysctl --system >/dev/null
    echo "OK: reverted. A reboot will restore stock kernel values fully."
  else
    echo "Nothing to revert — no XRd-prep files present."
  fi
}

case "${1:-apply}" in
  apply)   apply ;;
  --apply) apply ;;
  --status|status)  status ;;
  --revert|revert)  revert ;;
  -h|--help|help)
    sed -n '2,20p' "$0"
    ;;
  *)
    echo "Unknown option: $1" >&2
    sed -n '2,20p' "$0"
    exit 1
    ;;
esac
