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

Usage: filter-sandbox-denies.py [--check] [settings.json]

Default target is ~/.claude/settings.json. Exits non-zero if the target
does not exist.

With --check the script does not modify the JSON. It computes what the
denyRead/denyWrite arrays *would* be after a normal run and compares
against what is currently in the file. Exit 0 if they already match,
1 if they differ (i.e. a real run would change something). Intended
for use by health-check tooling like doctor.sh.
"""
import json
import os
import sys
from pathlib import Path

# Master lists. "~" and "{{CWD}}" are expanded at run time. "~" resolves
# to $HOME via os.path.expanduser; "{{CWD}}" resolves to os.getcwd() at
# filter invocation, which — because the filter runs inside the vigil
# subshell before exec'ing claude — is the directory the operator
# launched vigil from. Entries ending in "/" must resolve to a real
# directory; entries without a trailing slash must resolve to a real
# file. Symlinks are always rejected.
#
# {{CWD}} entries protect the active repo's git metadata against
# subprocess tampering. If the operator launches vigil from a non-repo
# directory those entries fail the type check and drop out with a
# visible diagnostic; a subsequent mid-session `cd` into a repo will
# not retroactively protect it — launch vigil from inside the repo.
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
    "~/.gitconfig",
    "{{CWD}}/.git/config",
    "{{CWD}}/.git/hooks/",
    # Vigil-installed config — belt-and-suspenders subprocess coverage.
    # Entries that do not exist on the host drop out with a diagnostic (type check).
    "~/.claude/CLAUDE.md",
    "~/.claude/settings.json",
    "~/.claude/hooks/",
    "~/.claude/agents/",
    "~/.claude/skills/",
    "~/.claude/commands/",
    "~/.config/vigil/",
    # Shell RC files that source vigil-aliases.sh.
    "~/.bashrc",
    "~/.zshrc",
    "~/.bash_profile",
    "~/.zprofile",
    "~/.profile",
    "~/.zshenv",
    "~/.bash_aliases",
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

    Kept entries are written back as absolute paths; "~" is expanded
    to $HOME and "{{CWD}}" is expanded to os.getcwd(). Dropped entries
    are returned with their expanded path for the diagnostic output.
    """
    cwd = os.getcwd()
    kept: list[str] = []
    dropped: list[tuple[str, str]] = []
    for entry in master:
        expanded = os.path.expanduser(entry).replace("{{CWD}}", cwd)
        keep, reason = evaluate(expanded)
        if keep:
            kept.append(expanded)
        else:
            dropped.append((expanded, reason))
    return kept, dropped


def main(argv):
    args = argv[1:]
    check_only = False
    positional: list[str] = []
    for a in args:
        if a == "--check":
            check_only = True
        elif a.startswith("-"):
            print(f"usage: {argv[0]} [--check] [settings.json]", file=sys.stderr)
            return 2
        else:
            positional.append(a)

    if len(positional) > 1:
        print(f"usage: {argv[0]} [--check] [settings.json]", file=sys.stderr)
        return 2

    target = positional[0] if positional else os.path.expanduser("~/.claude/settings.json")

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
    drift = False
    new_arrays: list[tuple[str, list[str]]] = []
    for key, master in keys:
        kept, dropped = build(master)
        current = list(filesystem.get(key, []))
        if current != kept:
            drift = True
        new_arrays.append((key, kept))
        summary_parts.append(f"{key}: {len(kept)}/{len(master)} kept")
        for entry, reason in dropped:
            all_dropped.append((key, entry, reason))

    if check_only:
        prefix = "filter-sandbox-denies --check: "
        if drift:
            print(prefix + "drift detected; a real run would change settings.json.")
        else:
            print(prefix + "in sync; " + "; ".join(summary_parts) + ".")
        for key, entry, reason in all_dropped:
            print(f"  would drop {key}: {entry}  ({reason})")
        return 1 if drift else 0

    for key, kept in new_arrays:
        filesystem[key] = kept

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
