#!/usr/bin/env python3
"""Filter sandbox.filesystem.denyRead entries in a settings.json to paths
bubblewrap can actually mount over.

Bubblewrap requires each tmpfs/bind target to be a real directory or file
on the host filesystem. The following entries cause sandbox init to fail
closed — every subprocess in the session fails, regardless of what it
does:

  - Symlinks (regardless of where they point). Confirmed failure: a
    symlink under $HOME pointing at a Windows-mounted path under /mnt/c/
    on WSL2 makes bwrap fail to mount tmpfs across the filesystem
    boundary.
  - Directory-typed entries (trailing "/") whose path is absent or is a
    file/symlink rather than a real directory.
  - File-typed entries (no trailing "/") whose path is absent or is a
    directory/symlink.

This filter is one-way: entries that don't pass the type check at run
time are dropped. Paths that appear later (e.g., a real ~/.aws/ created
by installing AWS CLI) require re-running the installer to be
reintroduced.

Usage: filter-sandbox-denies.py [settings.json]

Default target is ~/.claude/settings.json. Exits non-zero if the target
does not exist.
"""
import json
import os
import sys
from pathlib import Path


def evaluate(entry: str) -> tuple[bool, str]:
    """Return (keep, reason). reason is empty when keep is True."""
    p = Path(entry)
    if p.is_symlink():
        return False, "is a symlink"
    if entry.endswith("/"):
        if p.is_dir():
            return True, ""
        return False, "expected directory; missing or wrong type"
    else:
        if p.is_file():
            return True, ""
        return False, "expected file; missing or wrong type"


def main(argv):
    if len(argv) > 2:
        print(f"usage: {argv[0]} [settings.json]", file=sys.stderr)
        return 2

    target = argv[1] if len(argv) > 1 else os.path.expanduser("~/.claude/settings.json")

    if not os.path.isfile(target):
        print(f"filter-sandbox-denies: {target} does not exist.", file=sys.stderr)
        return 1

    with open(target) as f:
        settings = json.load(f)

    entries = (
        settings
        .get("sandbox", {})
        .get("filesystem", {})
        .get("denyRead", None)
    )
    if entries is None:
        print(
            "filter-sandbox-denies: no sandbox.filesystem.denyRead in "
            f"{target}; nothing to filter.",
            file=sys.stderr,
        )
        return 0

    kept = []
    dropped = []  # list of (entry, reason)
    for entry in entries:
        keep, reason = evaluate(entry)
        if keep:
            kept.append(entry)
        else:
            dropped.append((entry, reason))

    settings["sandbox"]["filesystem"]["denyRead"] = kept

    tmp = target + ".tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp, target)

    print(
        f"filter-sandbox-denies: {len(entries)} entries total; "
        f"{len(kept)} kept, {len(dropped)} dropped."
    )
    for entry, reason in dropped:
        print(f"  dropped: {entry}  ({reason})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
