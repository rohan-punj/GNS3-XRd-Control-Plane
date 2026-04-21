# Cisco XRd Control Plane for GNS3

A complete GNS3-ready package for running Cisco IOS XR as a Docker container.
Adapted from an EVE-NG integration (`xrd.yml`, `prep_xrd.sh`, `init_xrd.sh`)
into a working set of GNS3 appliance files, helper scripts, and a GNS3-VM
preparation patcher.

Tested on GNS3 3.0.5.

---

## Package contents

```
xrd-gns3-package/
├── cisco-xrd-controlplane.gns3a     # GNS3 appliance file (default: latest tag)
├── docker-image/
│   ├── Dockerfile                    # builds xrd-cp-gns3:<tag>
│   ├── firstboot.cfg                 # default bootstrap config (admin/cisco)
│   └── build-image.sh                # one-shot builder (supports version tags)
├── scripts/
│   ├── prep-gns3-vm.sh               # sysctl + FUSE for XRd (run once per VM)
│   ├── patch-gns3-docker-ast.py      # AST-based: adds /dev/fuse + 1 GiB shm
│   ├── gns3-xrd-env.sh               # env-var generator for N adapters
│   └── make-gns3a.sh                 # per-version .gns3a generator
└── docs/
    ├── README.md                     # this file
    ├── QUICKSTART.md                 # 5-minute getting-started
    ├── MULTI-VERSION.md              # side-by-side XRd versions
    └── TROUBLESHOOTING.md            # common issues & fixes
```

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| GNS3 3.0+ with the GNS3 VM | XRd needs Linux kernel features; on native Linux hosts substitute "the GNS3 VM" with "the local GNS3 server" everywhere below |
| Cisco XRd Control Plane image | From Cisco CCO or the [XRd sandbox](https://developer.cisco.com) |
| 4 GiB+ RAM per XRd node | Hard requirement — XRd will OOM below this |
| Recent kernel on the GNS3 VM | 5.x+ recommended; Ubuntu 22.04+ base is fine |

---

## Complete workflow

### Step 1 — Transfer the official XRd image to the GNS3 VM

From your workstation:

```bash
scp xrd-control-plane-<version>.tar.gz gns3@<GNS3_VM_IP>:~
scp -r xrd-gns3-package gns3@<GNS3_VM_IP>:~
```

### Step 2 — Load the image into Docker

On the GNS3 VM:

```bash
docker load -i ~/xrd-control-plane-<version>.tar.gz
docker images | grep xrd
# Note the full tag, e.g. ios-xr/xrd-control-plane:24.4.1
```

### Step 3 — Build the custom GNS3 image

```bash
cd ~/xrd-gns3-package/docker-image
./build-image.sh ios-xr/xrd-control-plane:24.4.1
# Produces image: xrd-cp-gns3:latest (used by the default .gns3a)
```

Edit `firstboot.cfg` first if you want different credentials or any day-0
configuration (SSH, mgmt DHCP, etc.) — the config is baked into the image.

### Step 4 — Prepare the GNS3 VM for XRd (one-time, shared by all XRd nodes)

```bash
cd ~/xrd-gns3-package
sudo ./scripts/prep-gns3-vm.sh
```

This sets the kernel parameters XRd needs:

| Setting | Value | Why |
|---------|-------|-----|
| `fs.inotify.max_user_instances` | 64000 | XRd uses ~4000 per node; default 128 breaks everything |
| `fs.inotify.max_user_watches` | 524288 | Supports many XRd file watchers |
| `fs.file-max` | 1000000 | XRd opens many files |
| FUSE kernel module | loaded | XRd uses FUSE filesystems internally |

All persist across reboots. `--revert` removes the changes.

### Step 5 — Patch GNS3 for extra Docker requirements (one-time)

GNS3 already runs containers with `Privileged=True` and `CapAdd=["ALL"]`,
but the `.gns3a` schema can't express two things XRd needs:

- `/dev/fuse` device in the container
- 1 GiB `/dev/shm` (Docker default is only 64 MiB)

```bash
# Preview what the patch will do (safe, writes nothing):
sudo python3 ./scripts/patch-gns3-docker-ast.py --dry-run

# Apply:
sudo python3 ./scripts/patch-gns3-docker-ast.py
```

The patcher parses `docker_vm.py` into a Python AST, adds `ShmSize` and
`Devices` keys, and **refuses to write the file** unless the result parses
cleanly. Timestamped backup is created before every apply. See
`--status` and `--revert` for those operations.

### Step 6 — Import the appliance into GNS3

1. GNS3 GUI → **File → Import appliance**
2. Select `cisco-xrd-controlplane.gns3a`
3. Choose **Run the appliance on the GNS3 VM**
4. Click **Finish**

### Step 7 — Set Max RAM and CPU in the template (IMPORTANT)

GNS3 3.x imports this appliance with **Maximum RAM = 0** and **Maximum CPU
= 0**. Zero means different things to different Docker versions; you need
to set explicit values so XRd behaves predictably.

1. **Edit → Preferences → Docker containers → Cisco XRd Control Plane → Edit**
2. Set **Maximum RAM**: `4096` (MB)
3. Set **Maximum CPU**: `1` (or 2 if the VM has capacity)
4. Save

### Step 8 — Drag, connect, start, use

1. Drag the template onto the canvas
2. **Connect at least one link** from the node to something else — XRd won't
   enable an interface that isn't wired up in the topology
3. Right-click → **Start**
4. Wait ~2–3 minutes
5. Right-click → **Console** (opens telnet; you land in the Linux shell)
6. Enter the XR CLI:
   ```
   /pkg/bin/xr_cli.sh
   ```
7. Log in: `admin` / `cisco`
8. Check your interfaces:
   ```
   show interfaces brief
   config
   interface GigabitEthernet0/0/0/0
    no shutdown
   commit
   end
   ```

---

## Multiple XRd versions side-by-side

See `MULTI-VERSION.md` for the full workflow. Short version:

```bash
# Load and build each version with its own tag
docker load -i xrd-control-plane-24.4.1.tar.gz
./docker-image/build-image.sh ios-xr/xrd-control-plane:24.4.1  xrd-cp-gns3:24.4.1

docker load -i xrd-control-plane-25.1.1.tar.gz
./docker-image/build-image.sh ios-xr/xrd-control-plane:25.1.1  xrd-cp-gns3:25.1.1

# Generate a per-version appliance file
./scripts/make-gns3a.sh 24.4.1
./scripts/make-gns3a.sh 25.1.1

# Import both in GNS3 — each appears as its own appliance.
```

The GNS3 VM prep and `docker_vm.py` patch only need to be done once,
regardless of how many versions you run.

---

## Changing the adapter count

The default template has 4 adapters (1 mgmt + 3 data). To change:

```bash
./scripts/gns3-xrd-env.sh 8          # for 8-adapter nodes
./scripts/make-gns3a.sh 24.4.1 8     # new per-version .gns3a with 8 adapters
```

Or edit an existing template: **Preferences → Docker containers → [name] →
Edit**, change **Adapters** to the new count, then paste the env-var output
from `gns3-xrd-env.sh` into the **Environment** field. Recreate any running
nodes — existing ones keep their original env vars.

---


