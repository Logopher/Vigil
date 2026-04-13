#!/usr/bin/env python3
"""Rebuild sandbox.filesystem.denyRead and denyWrite in a settings.json
from a master list defined in this script, intersected with the paths
the host filesystem currently accepts as bubblewrap mount targets.

Bubblewrap requires each tmpfs/bind target to be a real directory or
file on the host. The following entries cause sandbox init to fail
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

The master lists below are the source of truth. On every run this
script overwrites the JSON's denyRead and denyWrite arrays with the
master entries that currently pass the type check — so newly created
paths (e.g., ~/.aws/ after installing AWS CLI) appear automatically the
next time it runs, and paths that have since disappeared drop out.

To change the desired deny set, edit MASTER_DENY_READ / MASTER_DENY_WRITE
in this file. Whatever is present in the target JSON is ignored as
input; this script is authoritative.

Usage: filter-sandbox-denies.py [settings.json]

Default target is ~/.claude/settings.json. Exits non-zero if the target
does not exist.
"""
import json
import os
import sys
from pathlib import Path

# Master lists. "~" is expanded at run time. Entries ending in "/" must
# resolve to a real directory; entries without a trailing slash must
# resolve to a real file. Symlinks are always rejected.
MASTER_DENY_READ = (
    "~/.ssh/",
    "~/.aws/",
    "~/.kube/",
    "~/.netrc",
    "~/.docker/config.json",
    "~/.config/gh/",
    "~/.config/doctl/",
)

MASTER_DENY_WRITE = (
    "/etc/",
    "/usr/",
    "/var/",
    "/opt/",
    "~/.local/bin/",
    "~/.local/lib/",
    "~/bin/",
)


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


def build(master: tuple[str, ...]) -> tuple[list[str], list[tuple[str, str]]]:
    """Expand each master entry and partition into (kept, dropped).

    Kept entries preserve the original master-list spelling (with "~")
    so the JSON stays portable across users. Dropped entries are
    returned with their expanded path for the diagnostic output.
    """
    kept: list[str] = []
    dropped: list[tuple[str, str]] = []
    for entry in master:
        expanded = os.path.expanduser(entry)
        keep, reason = evaluate(expanded)
        if keep:
            kept.append(expanded)
        else:
            dropped.append((expanded, reason))
    return kept, dropped


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

    sandbox = settings.setdefault("sandbox", {})
    filesystem = sandbox.setdefault("filesystem", {})

    keys = (("denyRead", MASTER_DENY_READ), ("denyWrite", MASTER_DENY_WRITE))
    all_dropped: list[tuple[str, str, str]] = []
    summary_parts: list[str] = []
    for key, master in keys:
        kept, dropped = build(master)
        filesystem[key] = kept
        summary_parts.append(f"{key}: {len(kept)}/{len(master)} kept")
        for entry, reason in dropped:
            all_dropped.append((key, entry, reason))

    tmp = target + ".tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp, target)

    print("filter-sandbox-denies: " + "; ".join(summary_parts) + ".")
    for key, entry, reason in all_dropped:
        print(f"  dropped {key}: {entry}  ({reason})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
