#!/usr/bin/env python3
"""
patch-gns3-docker-ast.py
----------------------------------------------------------------------------
Safely patches the GNS3 server's docker_vm.py to add /dev/fuse device mount
and 1 GiB shared memory in the HostConfig dict.

Unlike regex-based patching, this script parses the file into an actual
Python AST, modifies the specific dict node, and re-emits the source with
`ast.unparse()`. It validates the result parses before overwriting.

Works on any GNS3 version whose docker_vm.py contains a HostConfig dict
literal — the AST walker doesn't care about surrounding keys or formatting.

Usage (run as root on the GNS3 VM):
    sudo python3 patch-gns3-docker-ast.py              # apply
    sudo python3 patch-gns3-docker-ast.py --revert     # restore backup
    sudo python3 patch-gns3-docker-ast.py --status     # check state
    sudo python3 patch-gns3-docker-ast.py --dry-run    # show changes, don't write
"""
from __future__ import annotations

import argparse
import ast
import glob
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


MARKER_COMMENT = "GNS3-XRD-PATCH"
SHM_SIZE_BYTES = 1_073_741_824  # 1 GiB

# Keys to add if not already present
KEYS_TO_ADD = {
    "ShmSize": ast.Constant(value=SHM_SIZE_BYTES),
    "Devices": ast.List(
        elts=[
            ast.Dict(
                keys=[
                    ast.Constant(value="PathOnHost"),
                    ast.Constant(value="PathInContainer"),
                    ast.Constant(value="CgroupPermissions"),
                ],
                values=[
                    ast.Constant(value="/dev/fuse"),
                    ast.Constant(value="/dev/fuse"),
                    ast.Constant(value="rwm"),
                ],
            )
        ],
        ctx=ast.Load(),
    ),
}


def find_docker_vm() -> Path | None:
    """Locate docker_vm.py across common GNS3 install paths."""
    candidates: list[str] = []
    candidates += glob.glob(
        "/usr/share/gns3/gns3-server/lib/python*/site-packages/gns3server/compute/docker/docker_vm.py"
    )
    candidates += glob.glob(
        "/usr/lib/python3/dist-packages/gns3server/compute/docker/docker_vm.py"
    )
    candidates += glob.glob(
        "/opt/gns3/*/lib/python*/site-packages/gns3server/compute/docker/docker_vm.py"
    )
    candidates += glob.glob(
        "/home/*/.local/lib/python*/site-packages/gns3server/compute/docker/docker_vm.py"
    )
    candidates += glob.glob(
        "/home/*/venv*/lib/python*/site-packages/gns3server/compute/docker/docker_vm.py"
    )

    for c in candidates:
        if os.path.isfile(c):
            return Path(c)

    # Fallback: use `find` (slow)
    print("Falling back to filesystem search...", file=sys.stderr)
    try:
        out = subprocess.check_output(
            ["find", "/", "-type", "f", "-name", "docker_vm.py",
             "-path", "*/gns3server/compute/docker/*"],
            stderr=subprocess.DEVNULL,
            timeout=60,
        ).decode().splitlines()
        for line in out:
            if line.strip() and os.path.isfile(line.strip()):
                return Path(line.strip())
    except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
        pass
    return None


class HostConfigPatcher(ast.NodeTransformer):
    """Finds dict literals that look like a Docker HostConfig and adds keys."""

    def __init__(self) -> None:
        self.patched_count = 0
        self.already_present_count = 0

    @staticmethod
    def _is_host_config_dict(node: ast.Dict) -> bool:
        """
        Heuristic: does this dict have enough HostConfig-ish keys to be 'it'?
        We require CapAdd and Privileged — the two keys that have been in
        every GNS3 version from 2.x to 3.x.
        """
        literal_keys = {
            k.value for k in node.keys
            if isinstance(k, ast.Constant) and isinstance(k.value, str)
        }
        required = {"CapAdd", "Privileged"}
        return required.issubset(literal_keys)

    def visit_Dict(self, node: ast.Dict) -> ast.AST:
        # Recurse first so nested dicts are handled
        self.generic_visit(node)

        if not self._is_host_config_dict(node):
            return node

        existing = {
            k.value for k in node.keys
            if isinstance(k, ast.Constant) and isinstance(k.value, str)
        }

        added_any = False
        for key_name, value_node in KEYS_TO_ADD.items():
            if key_name in existing:
                continue
            node.keys.append(ast.Constant(value=key_name))
            node.values.append(value_node)
            added_any = True

        if added_any:
            self.patched_count += 1
        else:
            self.already_present_count += 1
        return node


def find_hostconfig_containers(tree: ast.AST) -> list[str]:
    """Return a list of enclosing function names where HostConfig dicts live,
       for user-visible reporting."""
    locations = []

    class Finder(ast.NodeVisitor):
        def __init__(self) -> None:
            self.stack: list[str] = []

        def _enter(self, name: str, node: ast.AST) -> None:
            self.stack.append(name)
            self.generic_visit(node)
            self.stack.pop()

        def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
            self._enter(f"def {node.name}()", node)

        def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
            self._enter(f"async def {node.name}()", node)

        def visit_ClassDef(self, node: ast.ClassDef) -> None:
            self._enter(f"class {node.name}", node)

        def visit_Dict(self, node: ast.Dict) -> None:
            if HostConfigPatcher._is_host_config_dict(node):
                locations.append(" > ".join(self.stack) + f"  (line {node.lineno})")
            self.generic_visit(node)

    Finder().visit(tree)
    return locations


def apply_patch(target: Path, dry_run: bool) -> int:
    src = target.read_text(encoding="utf-8")

    # Parse — if this fails the file is already broken
    try:
        tree = ast.parse(src, filename=str(target))
    except SyntaxError as e:
        print(f"ERROR: {target} does not parse as valid Python:\n  {e}", file=sys.stderr)
        print("       The file may already be corrupted. Restore from a backup or reinstall.", file=sys.stderr)
        return 3

    # Find HostConfig locations for reporting
    hc_locations = find_hostconfig_containers(tree)
    if not hc_locations:
        print("ERROR: No HostConfig dict found in the file.", file=sys.stderr)
        print("       The GNS3 source layout may have changed; patch aborted.", file=sys.stderr)
        return 4

    print(f"Found {len(hc_locations)} HostConfig dict(s):")
    for loc in hc_locations:
        print(f"  - {loc}")

    # Apply the transform
    patcher = HostConfigPatcher()
    new_tree = patcher.visit(tree)
    ast.fix_missing_locations(new_tree)

    if patcher.patched_count == 0 and patcher.already_present_count > 0:
        print("OK: patch already applied. Nothing to do.")
        return 0

    # Re-emit source
    try:
        new_src = ast.unparse(new_tree)
    except Exception as e:
        print(f"ERROR: ast.unparse failed: {e}", file=sys.stderr)
        return 5

    # CRITICAL: validate the new source parses before we write it
    try:
        ast.parse(new_src, filename=str(target))
    except SyntaxError as e:
        print(f"ERROR: patched output would not parse:\n  {e}", file=sys.stderr)
        print("       Aborting — original file not touched.", file=sys.stderr)
        return 6

    # Add marker comment at top so --status can detect it
    header = f"# {MARKER_COMMENT}: ShmSize + /dev/fuse added by XRd patch\n"
    if MARKER_COMMENT not in new_src:
        new_src = header + new_src

    if dry_run:
        print(f"\n--- DRY RUN: would patch {patcher.patched_count} HostConfig dict(s) ---")
        # Show a diff-ish summary
        print(f"Keys added per dict: {list(KEYS_TO_ADD)}")
        print(f"Would write {len(new_src)} bytes to {target}")
        return 0

    # Backup
    ts = time.strftime("%Y%m%d-%H%M%S")
    backup = target.with_name(target.name + f".bak.{ts}")
    shutil.copy2(target, backup)
    print(f"Backup: {backup}")

    # Write atomically (write to tmp, then rename)
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_text(new_src, encoding="utf-8")
    shutil.copymode(target, tmp)
    # Preserve ownership
    st = target.stat()
    os.chown(tmp, st.st_uid, st.st_gid)
    os.rename(tmp, target)
    print(f"OK: patched {patcher.patched_count} HostConfig dict(s) in {target}")

    return 0


def revert(target: Path) -> int:
    backups = sorted(
        glob.glob(str(target) + ".bak.*"),
        key=os.path.getmtime,
        reverse=True,
    )
    if not backups:
        print(f"ERROR: no backups found next to {target}", file=sys.stderr)
        return 1
    latest = backups[0]
    # Validate the backup parses before restoring
    try:
        ast.parse(Path(latest).read_text(encoding="utf-8"))
    except SyntaxError as e:
        print(f"ERROR: backup {latest} does not parse:\n  {e}", file=sys.stderr)
        print("       Refusing to restore from a broken backup.", file=sys.stderr)
        return 2
    shutil.copy2(latest, target)
    print(f"OK: restored {target} from {latest}")
    return 0


def status(target: Path) -> int:
    print(f"Target: {target}")
    src = target.read_text(encoding="utf-8")
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        print(f"Status: BROKEN (file does not parse)\n  {e}")
        return 1

    marker_present = MARKER_COMMENT in src
    locations = find_hostconfig_containers(tree)

    # Check if any HostConfig dict has the new keys
    found_keys_per_dict: list[set[str]] = []

    class Checker(ast.NodeVisitor):
        def visit_Dict(self, node: ast.Dict) -> None:
            if HostConfigPatcher._is_host_config_dict(node):
                keys = {
                    k.value for k in node.keys
                    if isinstance(k, ast.Constant) and isinstance(k.value, str)
                }
                found_keys_per_dict.append(keys)
            self.generic_visit(node)

    Checker().visit(tree)

    print(f"HostConfig dicts found: {len(locations)}")
    for loc, keys in zip(locations, found_keys_per_dict):
        has_shm = "ShmSize" in keys
        has_dev = "Devices" in keys
        print(f"  - {loc}")
        print(f"    ShmSize: {'yes' if has_shm else 'no':<3}  Devices: {'yes' if has_dev else 'no'}")

    all_patched = all(
        "ShmSize" in k and "Devices" in k for k in found_keys_per_dict
    ) and found_keys_per_dict
    print()
    if all_patched:
        print("Status: PATCHED")
    elif marker_present:
        print("Status: MARKER present but keys missing (partial / old patch?)")
    else:
        print("Status: NOT patched")
    return 0


def restart_gns3() -> None:
    """Best-effort restart of the GNS3 service."""
    for unit in ("gns3-server.service", "gns3.service"):
        try:
            subprocess.check_call(
                ["systemctl", "is-enabled", unit],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            print(f"Restarting {unit} ...")
            subprocess.check_call(["systemctl", "restart", unit])
            print(f"OK: {unit} restarted.")
            return
        except subprocess.CalledProcessError:
            continue
    print("WARN: no gns3 systemd unit found. Restart the server manually.", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser(description="Safely patch GNS3 docker_vm.py for XRd.")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--revert", action="store_true", help="restore most recent backup")
    g.add_argument("--status", action="store_true", help="show patch state")
    g.add_argument("--dry-run", action="store_true", help="preview only, don't write")
    ap.add_argument("--target", type=Path, default=None, help="path to docker_vm.py (auto-detect if omitted)")
    ap.add_argument("--no-restart", action="store_true", help="skip GNS3 restart after patching")
    args = ap.parse_args()

    target = args.target or find_docker_vm()
    if target is None:
        print("ERROR: could not locate docker_vm.py. Pass --target explicitly.", file=sys.stderr)
        return 1
    print(f"Target: {target}")

    if args.status:
        return status(target)

    # Write operations require root
    if os.geteuid() != 0 and not args.dry_run:
        print("ERROR: this script must be run as root (use sudo) unless --dry-run.", file=sys.stderr)
        return 1

    if args.revert:
        rc = revert(target)
        if rc == 0:
            restart_gns3()
        return rc

    rc = apply_patch(target, dry_run=args.dry_run)
    if rc == 0 and not args.dry_run and not args.no_restart:
        restart_gns3()
    return rc


if __name__ == "__main__":
    sys.exit(main())
