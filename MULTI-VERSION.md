# Running multiple XRd versions side-by-side

Use case: you want XRd 24.4.1 and XRd 25.1.1 (or any mix of versions)
available as distinct appliances in the same GNS3 project, each drag-
and-droppable independently.

## One-time GNS3 VM setup (shared by ALL versions)

These steps only need to be done once per GNS3 VM, regardless of how
many XRd versions you later add:

```bash
# On the GNS3 VM, inside the xrd-gns3-package/ directory:
sudo ./scripts/prep-gns3-vm.sh               # inotify / FUSE / file-max
sudo python3 ./scripts/patch-gns3-docker-ast.py   # /dev/fuse + 1 GiB shm
```

## Adding each XRd version

Repeat these three steps for every XRd release you want to support.

### Step A — Load and tag the official image

```bash
# On the GNS3 VM:
docker load -i xrd-control-plane-24.4.1.tar.gz
docker images | grep xrd
# e.g. ios-xr/xrd-control-plane  24.4.1  <image_id>
```

### Step B — Build a version-tagged custom image

The second argument is the *output* tag. Use a version suffix so each
build is distinct:

```bash
cd ~/xrd-gns3-package/docker-image

# For 24.4.1:
./build-image.sh ios-xr/xrd-control-plane:24.4.1  xrd-cp-gns3:24.4.1

# Later, for 25.1.1:
./build-image.sh ios-xr/xrd-control-plane:25.1.1  xrd-cp-gns3:25.1.1
```

Confirm both images exist:

```bash
docker images | grep xrd-cp-gns3
# xrd-cp-gns3  24.4.1  ...
# xrd-cp-gns3  25.1.1  ...
```

### Step C — Generate a per-version `.gns3a` appliance file

```bash
cd ~/xrd-gns3-package

./scripts/make-gns3a.sh 24.4.1
# -> cisco-xrd-controlplane-24.4.1.gns3a

./scripts/make-gns3a.sh 25.1.1
# -> cisco-xrd-controlplane-25.1.1.gns3a
```

Each generated file:

- Has a **unique, stable `appliance_id`** (UUID derived from the image
  tag, so re-running produces the same ID — re-imports update rather
  than duplicate).
- Has a **distinct display name** (e.g. "Cisco XRd Control Plane 24.4.1").
- References the matching **Docker image tag** (`xrd-cp-gns3:24.4.1`).
- Has its own environment variables — if you pass a custom adapter
  count, that's baked in.

### Step D — Import in GNS3

On your workstation, import each `.gns3a`:

1. **File → Import appliance** → select `cisco-xrd-controlplane-24.4.1.gns3a`
2. Run on GNS3 VM → Finish
3. Repeat for `cisco-xrd-controlplane-25.1.1.gns3a`

Both appear in the Routers panel as separate templates.

### Step E — Set RAM/CPU on each imported template

Same as the single-version workflow — GNS3 3.x imports with Max RAM=0
and CPU=0, which is broken. For each imported XRd template:

**Preferences → Docker containers → [Cisco XRd Control Plane NN.N.N] →
Edit → Max RAM = 4096, Max CPU = 1 → Save**

## Example: custom adapter counts per version

You can give different versions different defaults. For instance a
lightweight 4-adapter 24.4.1 and a wider 16-adapter 25.1.1:

```bash
./scripts/make-gns3a.sh 24.4.1  4
./scripts/make-gns3a.sh 25.1.1  16
```

## Switching a running project from version A to version B

Templates are per-project references — simply swap the node:

1. Right-click the old XRd node → Copy its config (or export its config file)
2. Delete the node
3. Drag the other-version template onto the canvas
4. Restore the config

There's no in-place version upgrade — XRd containers are stateless
from GNS3's perspective. Anything persistent needs to live in the
firstboot config or a bind mount.

## Caveats

- **Disk usage grows fast.** Each XRd image is ~2 GiB. Multiple versions
  × many GNS3 VM snapshots can fill the VM disk quickly. Clean up
  unused images with `docker image prune` on the GNS3 VM.
- **UUID stability.** The `make-gns3a.sh` script derives a stable UUID
  from the image tag. If you rebuild the image under the same tag, the
  UUID stays the same and re-importing updates the existing appliance.
  If you rename an image, GNS3 will treat the new `.gns3a` as a new
  appliance — you'll have two entries.
- **Shared kernel features.** All XRd versions share the one set of
  kernel sysctl tweaks from `prep-gns3-vm.sh`. If a future XRd release
  has different requirements, re-run the prep script — it's idempotent.

## Removing a version

```bash
# On the GNS3 VM:
docker rmi xrd-cp-gns3:24.4.1
docker rmi ios-xr/xrd-control-plane:24.4.1   # optional — removes the base too

# In GNS3 GUI: Preferences -> Docker containers -> select template -> Delete
# And delete the .gns3a file if you want:
rm cisco-xrd-controlplane-24.4.1.gns3a
```

The GNS3 VM prep and `docker_vm.py` patch stay in place — they're
version-agnostic.
