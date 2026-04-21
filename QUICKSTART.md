# Cisco XRd for GNS3 — Quickstart

From zero to a working XRd node on the GNS3 VM. Assumes you already
scp'd this package and the XRd tar.gz to the VM.

```bash
# --- On the GNS3 VM ---

# 1. Load the official XRd image
docker load -i xrd-control-plane-24.4.1.tar.gz

# 2. Build the custom image
cd ~/xrd-gns3-package/docker-image
./build-image.sh ios-xr/xrd-control-plane:24.4.1

# 3. Prep the GNS3 VM (inotify, FUSE) — one time
cd ~/xrd-gns3-package
sudo ./scripts/prep-gns3-vm.sh

# 4. Patch GNS3 docker_vm.py (/dev/fuse + 1 GiB shm) — one time
sudo python3 ./scripts/patch-gns3-docker-ast.py

# --- On your workstation (GNS3 GUI) ---

# 5. File -> Import appliance -> cisco-xrd-controlplane.gns3a
#    Run on the GNS3 VM -> Finish

# 6. Edit -> Preferences -> Docker containers -> Cisco XRd Control Plane
#    -> Edit -> set Maximum RAM = 4096 (MB), Maximum CPU = 1 -> Save
#    (REQUIRED — GNS3 3.x imports these as 0)

# 7. Drag the node onto the canvas, CONNECT a link to something, then Start
# 8. Wait ~2-3 min, open Console (telnet), then:
#       /pkg/bin/xr_cli.sh
#       Username: admin
#       Password: cisco
#       show interfaces brief
```

## Troubleshooting in one glance

| Symptom | Fix |
|---|---|
| Node won't start at all | `docker ps -a` → check exit logs of recent XRd container |
| "inotify instance" error | Run `sudo ./scripts/prep-gns3-vm.sh` |
| Container starts but crashes | Set RAM=4096 in template (step 6) |
| No interfaces in `show int brief` | **Connect** links in topology before starting |
| `show int brief` empty after connecting | Check `XR_INTERFACES` env var matches adapter count |
| GNS3 server won't load web UI | You ran the old bash patch script — see TROUBLESHOOTING.md |

Full details: `README.md`. Side-by-side versions: `MULTI-VERSION.md`.
Problems: `TROUBLESHOOTING.md`.
