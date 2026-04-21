# Cisco XRd for GNS3 — Troubleshooting

Issues are ordered roughly by the stage in the boot sequence they occur.

---

## GNS3 server won't start / web UI doesn't load after patching

If you ran an earlier bash-based version of the docker_vm.py patch and
GNS3 3.x broke:

```bash
# Find the backup
TARGET=$(sudo find / -type f -name "docker_vm.py" -path "*/gns3server/*" 2>/dev/null | head -1)
sudo ls -la "${TARGET}".bak.*

# Restore the most recent backup
LATEST=$(sudo ls -t "${TARGET}".bak.* | head -1)
sudo cp "$LATEST" "$TARGET"

# Validate Python syntax
sudo python3 -c "import ast; ast.parse(open('$TARGET').read()); print('OK')"

# Restart
sudo systemctl restart gns3-server
```

If no backup exists, reinstall:

```bash
sudo apt install --reinstall gns3-server
sudo systemctl restart gns3-server
```

Then use `patch-gns3-docker-ast.py` (not the old `.sh` one). The AST
patcher validates the result parses before writing and cannot leave
you with a broken file.

---

## Node won't start / no container created

`docker ps` shows nothing and console stays blank.

```bash
# Check GNS3 logs for the actual error
sudo journalctl -u gns3-server -n 80 --no-pager | tail -40

# Check for exited containers (they die quickly when something is wrong)
docker ps -a | head -10

# Inspect the most recent exited container
CID=$(docker ps -aq | head -1)
docker logs $CID 2>&1 | tail -40
```

---

## "not enough inotify instance resources"

The most common XRd startup failure. Fix:

```bash
sudo ~/xrd-gns3-package/scripts/prep-gns3-vm.sh
```

That sets `fs.inotify.max_user_instances=64000` (default is 128, and XRd
needs ~4000 per node). Then restart the XRd node in GNS3.

To verify the settings stuck:

```bash
sysctl fs.inotify.max_user_instances fs.inotify.max_user_watches fs.file-max
```

---

## Container exits immediately / XRd fails to boot

Check `docker logs` on the dying container. Common causes:

| Log message | Cause | Fix |
|-------------|-------|-----|
| `inotify` / `max_user_instances` | inotify limits too low | `sudo ./scripts/prep-gns3-vm.sh` |
| `fuse: device not found` | FUSE module not loaded | `sudo modprobe fuse` (prep script does this) |
| `/dev/shm` too small | ShmSize not set | `sudo python3 ./scripts/patch-gns3-docker-ast.py` |
| OOM / cannot allocate memory | RAM = 0 in template | Template → Max RAM = 4096 |
| Kernel version too old | GNS3 VM kernel < 5.x | Upgrade the GNS3 VM |
| Image architecture mismatch | x86_64 image on ARM host | Use an x86_64 GNS3 VM |

---

## Maximum RAM / CPU = 0 in the GNS3 template

This is a GNS3 3.x quirk — the Docker template schema doesn't expose
these through `.gns3a`. Every import defaults them to 0.

Fix: after import, **Preferences → Docker containers → [template] →
Edit → Max RAM = 4096, Max CPU = 1 → Save**. Do this before starting
any node.

Depending on your Docker daemon version, `Memory: 0` either means
"unlimited" (20.10+, harmless but risky) or "no memory allowed"
(older, will OOM-kill XRd). Setting explicit values is always safer.

---

## `show ip interface brief` / `show interfaces brief` shows nothing

Three main causes:

### 1. Links not connected in the topology

XRd only enables interfaces that are wired to something else in GNS3.
Connect at least one cable from the XRd node before starting it. After
connecting, the interface shows up (possibly admin-down).

### 2. Environment variables missing or wrong

```bash
CID=$(docker ps -q --filter "ancestor=xrd-cp-gns3:latest" | head -1)
docker inspect $CID --format '{{range .Config.Env}}{{println .}}{{end}}' | grep XR_
```

Should show all three of `XR_FIRST_BOOT_CONFIG`, `XR_MGMT_INTERFACES`,
and `XR_INTERFACES`. If any are missing, edit the template:

**Preferences → Docker containers → [template] → Edit → Environment**

Paste the env block from `./scripts/gns3-xrd-env.sh <adapter_count>`.
Recreate any running nodes — existing ones keep their original env vars
from creation time.

### 3. Adapters enabled but admin-down

XRd interfaces come up admin-down by default. Bring them up:

```
RP/0/RP0/CPU0:router# config
RP/0/RP0/CPU0:router(config)# interface GigabitEthernet0/0/0/0
RP/0/RP0/CPU0:router(config-if)# no shutdown
RP/0/RP0/CPU0:router(config-if)# commit
RP/0/RP0/CPU0:router(config-if)# end
```

Or use `show interfaces brief` (not `show ip int brief`) to see all
interfaces regardless of IP config.

---

## Container runs but `/pkg/bin/xr_cli.sh` not found / "waiting system"

XRd hasn't fully initialized yet. Typical boot time is 2–3 minutes.
Check readiness:

```bash
CID=$(docker ps -q --filter "ancestor=xrd-cp-gns3:latest" | head -1)
docker exec $CID pgrep parser_server
# Empty output = still booting. Non-empty = ready.
```

Once `parser_server` is running, `/pkg/bin/xr_cli.sh` works.

---

## Image `xrd-cp-gns3:latest` not found

The default `.gns3a` expects exactly `xrd-cp-gns3:latest`. Check what
you actually have:

```bash
docker images | grep xrd-cp-gns3
```

If empty, rebuild:

```bash
cd ~/xrd-gns3-package/docker-image
./build-image.sh ios-xr/xrd-control-plane:<version>
```

If tagged differently, either retag (`docker tag <actual>
xrd-cp-gns3:latest`) or use `make-gns3a.sh` to generate an appliance
file that matches your actual tag.

---

## Default login admin/cisco is rejected

The `firstboot.cfg` is only applied on the **first** boot of a given
container. If you've previously started the node and changed config,
those changes persist across container lifecycles via GNS3's project
storage.

Clean way to get back to defaults: delete the node in GNS3 and drag a
fresh one onto the canvas — the new container boots from scratch and
applies the firstboot config cleanly.

---

## Standalone `docker run` test worked but GNS3 node doesn't

You ran XRd manually from the command line; that container had no
veth pairs from GNS3 and had to exit cleanly before testing in GNS3.
Confirm nothing is still running:

```bash
docker ps -a | grep xrd-cp-gns3
docker rm -f $(docker ps -aq --filter "ancestor=xrd-cp-gns3:latest") 2>/dev/null || true
```

Then restart via GNS3 as normal.

---

## AST patcher says "No HostConfig dict found"

GNS3 source layout changed on your version. Run:

```bash
sudo python3 ./scripts/patch-gns3-docker-ast.py --dry-run
```

This prints what the patcher sees. If it truly can't find a HostConfig,
open the file:

```bash
sudo find / -name docker_vm.py -path "*/gns3server/*" 2>/dev/null
```

and look for the `params = {...}` dict inside the `create()` method.
If the structure is very different from what this package was tested
against (GNS3 3.0.5), post the `HostConfig` block and we'll adjust the
patcher.

As a manual fallback, add these two keys inside the HostConfig dict,
alongside `CapAdd`, `Privileged`, etc.:

```python
"ShmSize": 1073741824,
"Devices": [{"PathOnHost": "/dev/fuse",
             "PathInContainer": "/dev/fuse",
             "CgroupPermissions": "rwm"}],
```

Then: `sudo systemctl restart gns3-server`.

---

## Native Windows/macOS Docker

XRd does not run on Docker Desktop for Windows or macOS directly — it
needs specific Linux kernel features. You must run it on the GNS3 VM
(Linux VM running under VMware, VirtualBox, KVM, etc.) or on a native
Linux GNS3 server.
