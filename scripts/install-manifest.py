#!/usr/bin/env python3
"""install-manifest: SHA-256 fingerprints of Vigil-installed files.

Records the post-install state of every file install.sh writes into
~/.claude/ and ~/.config/vigil/, so update.sh can detect which Vigil-
managed files the user has edited and preserve those edits across the
reinstall-fueled update flow instead of clobbering them.

Subcommands:

    write
        Walk the live install roots, hash every Vigil-managed file,
        write the manifest at ~/.config/vigil/.install-manifest.
        Invoked at the end of install.sh after the three
        filter-sandbox-denies.py calls so settings.json hashes reflect
        post-mutation content.

    diverged <backup-dir>
        Read <backup-dir>/config/.install-manifest, rehash the
        corresponding backup file under <backup-dir>/{claude,config}/...,
        and print absolute *live* paths whose backup hash differs from
        the recorded hash. One path per line on stdout. Used by
        update.sh between move_contents and install.sh to snapshot
        user-edited Vigil files before the reinstall wipes them.

    reconcile <backup-dir>
        For each diverged path: rename the freshly-installed file to
        <name>.new.<ext> (split on the LAST '.'; trailing '.new' if no
        extension), copy the user-edited backup file into the original
        location. Emits TSV '<preserved>\\t<staged>' per pair for
        update.sh's end-of-run summary; the <staged> column is empty
        if the live file did not exist post-install (user's edit is
        the only copy). On any OSError, prints the failure to stderr
        and exits non-zero so update.sh's existing rollback() trap
        fires.

    verify [--quiet]
        Exit 0 if every manifest entry matches the on-disk file; exit
        1 if any hash differs. Intended for doctor.sh to surface
        post-install tampering or user edits at health-check time.

If the user has run filter-sandbox-denies.py since the last install,
the settings.json hashes will no longer match. Re-run
`install-manifest.py write` after such an out-of-band refresh to
rebaseline.

Hash format mirrors `vigil-install-review`'s .manifest idiom: one line
per file as '<sha256-hex>  <abs-path>', compatible with `sha256sum -c`.
"""
import hashlib
import os
import shutil
import sys
from pathlib import Path

MANIFEST_PATH = Path.home() / ".config" / "vigil" / ".install-manifest"
CLAUDE_DIR = Path.home() / ".claude"
DEST_DIR = Path.home() / ".config" / "vigil"

# Files install.sh writes into ~/.claude/ — explicit allowlist because
# ~/.claude/ is shared with Claude Code's runtime state (projects/,
# history.jsonl, sessions/, .credentials.json, etc.). Adding a file to
# install.sh's writes requires adding it here too; tests/install.sh
# guards this by asserting manifest membership for known entries.
#
# A prior draft proposed deriving this list dynamically from
# $REPO_DIR/profiles/default/ (gated by a VIGIL_MANIFEST_SOURCE env
# var) so the bundle and the allowlist stayed in sync without manual
# maintenance. Rejected: the manifest writer runs from the installed
# tree, which has no reliable handle on the source repo path at
# arbitrary times (only install.sh knows it). Hardcoding here keeps
# the script free of install-time coupling; the install-time test gate
# (tests/install.sh) catches drift if a new file is added to the
# default profile bundle without updating this tuple.
CLAUDE_FILES = (
    "CLAUDE.md",
    "settings.json",
    "settings.local.json",
    "settings.local.template.json",
    "agents/architect.md",
    "agents/code-reviewer.md",
)

# Top-level entries under ~/.config/vigil/ to skip when walking the
# tree. The rest of the directory is Vigil-owned and fair game.
# Matching is by exact basename:
#   - directory matches are pruned from dirs[] only at the top level
#     (a nested `sessions/` deeper in the tree would still be walked,
#     by design — none currently exist),
#   - file matches are skipped at any depth, so the manifest file and
#     its crash-recovery tmp sibling never sneak into the manifest
#     even if a future restructure moves them.
DEST_DIR_EXCLUDED = frozenset({
    "active-profile",          # write-once profile-choice state
    "sessions",                # per-session handoff dir (runtime)
    "signing.env",             # optional user-created ssh-agent socket env
    ".install-manifest",       # self
    ".install-manifest.tmp",   # crash-recovery tmp from cmd_write
})


def is_staged_new(path: Path) -> bool:
    """True if the basename matches the staged-update convention.

    `reconcile` writes diverged paths as '<name>.new.<ext>' (or
    trailing '.new' for extensionless files). Such files must not be
    hashed into a subsequent `write`, or the user's pending review
    state becomes part of the baseline and a later edit to the .new
    file would be flagged as divergence on the next update.

    To avoid false positives on filenames that happen to contain
    '.new.' as part of their natural name (a hypothetical 'what.new.md'
    is not produced by reconcile), the path only counts as staged when
    the corresponding original file (with the '.new' segment removed)
    also exists in the same directory — staged files always coexist
    with their preserved-edit sibling until the operator merges
    them."""
    name = path.name
    if name.endswith(".new"):
        sibling = path.with_name(name[: -len(".new")])
        return sibling.exists()
    last_dot = name.rfind(".")
    if last_dot <= 0:
        return False
    stem, ext = name[:last_dot], name[last_dot:]
    if not stem.endswith(".new"):
        return False
    sibling_name = stem[: -len(".new")] + ext
    sibling = path.with_name(sibling_name)
    return sibling.exists()


def iter_dest_dir(dest_dir: Path):
    """Yield every file under ~/.config/vigil/ that is Vigil-managed."""
    if not dest_dir.is_dir():
        return
    for root, dirs, files in os.walk(dest_dir):
        root_path = Path(root)
        if root_path == dest_dir:
            dirs[:] = [d for d in dirs if d not in DEST_DIR_EXCLUDED]
        for fname in files:
            if fname in DEST_DIR_EXCLUDED:
                continue
            fpath = root_path / fname
            if is_staged_new(fpath):
                continue
            yield fpath


def iter_claude_dir(claude_dir: Path):
    """Yield the files install.sh writes into ~/.claude/."""
    for rel in CLAUDE_FILES:
        path = claude_dir / rel
        if path.is_file() and not is_staged_new(path):
            yield path


def iter_managed_files():
    """Yield every Vigil-managed file across both install roots."""
    yield from iter_claude_dir(CLAUDE_DIR)
    yield from iter_dest_dir(DEST_DIR)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def die(msg: str) -> int:
    sys.stderr.write(f"install-manifest: {msg}\n")
    return 1


# ---- write ----------------------------------------------------------------

def cmd_write(_argv) -> int:
    """Hash every managed file and write the manifest atomically."""
    lines = []
    for path in sorted(iter_managed_files()):
        lines.append(f"{sha256_file(path)}  {path}")
    body = ("\n".join(lines) + "\n") if lines else ""
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    # Append-`.tmp` (not Path.with_suffix, which *replaces* the final
    # suffix) so the tmp name is unambiguous for any manifest name
    # shape. The basename `.install-manifest.tmp` is excluded from
    # iter_dest_dir so a crash mid-write does not leak an orphan into
    # the next manifest.
    tmp = MANIFEST_PATH.parent / (MANIFEST_PATH.name + ".tmp")
    tmp.write_text(body, encoding="utf-8")
    os.chmod(tmp, 0o644)
    tmp.replace(MANIFEST_PATH)
    return 0


# ---- parse / lookup helpers ----------------------------------------------

def read_manifest(path: Path):
    """Yield (hash, abs_path) pairs from a manifest file."""
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw:
            continue
        # Two-space delimiter, like sha256sum -c output. maxsplit=1
        # keeps any embedded double spaces in the path intact.
        parts = raw.split("  ", 1)
        if len(parts) != 2:
            sys.stderr.write(
                f"install-manifest: ignoring malformed line {lineno} in {path}\n"
            )
            continue
        yield parts[0], Path(parts[1])


def backup_path_for(live_path: Path, backup_dir: Path):
    """Map a live path to its corresponding backup-side path.

    update.sh splits the move-aside between $backup_dir/claude and
    $backup_dir/config. Returns None for paths outside either root —
    those are skipped silently (an entry the script itself didn't
    write)."""
    try:
        rel = live_path.relative_to(CLAUDE_DIR)
        return backup_dir / "claude" / rel
    except ValueError:
        pass
    try:
        rel = live_path.relative_to(DEST_DIR)
        return backup_dir / "config" / rel
    except ValueError:
        return None


# ---- diverged ------------------------------------------------------------

def cmd_diverged(argv) -> int:
    if not argv:
        return die("usage: diverged <backup-dir>")
    backup_dir = Path(argv[0])
    manifest = backup_dir / "config" / ".install-manifest"
    if not manifest.is_file():
        return die(f"no manifest at {manifest}")
    for recorded_hash, live_path in read_manifest(manifest):
        backup_path = backup_path_for(live_path, backup_dir)
        if backup_path is None or not backup_path.is_file():
            continue
        if sha256_file(backup_path) != recorded_hash:
            sys.stdout.write(f"{live_path}\n")
    return 0


# ---- reconcile -----------------------------------------------------------

def staged_name_for(path: Path) -> Path:
    """Return the '<name>.new.<ext>' adjacent path.

    Split on the LAST '.'. Files with no extension or only a leading
    dot (e.g. '.dotfile') get a trailing '.new' instead of an infix."""
    name = path.name
    last_dot = name.rfind(".")
    if last_dot <= 0:
        return path.with_name(name + ".new")
    stem, ext = name[:last_dot], name[last_dot:]
    return path.with_name(f"{stem}.new{ext}")


def cmd_reconcile(argv) -> int:
    if not argv:
        return die("usage: reconcile <backup-dir>")
    backup_dir = Path(argv[0])
    manifest = backup_dir / "config" / ".install-manifest"
    if not manifest.is_file():
        return die(f"no manifest at {manifest}")
    pairs = []
    for recorded_hash, live_path in read_manifest(manifest):
        backup_path = backup_path_for(live_path, backup_dir)
        if backup_path is None or not backup_path.is_file():
            continue
        if sha256_file(backup_path) == recorded_hash:
            continue
        staged = staged_name_for(live_path)
        try:
            if live_path.exists():
                if staged.exists():
                    staged.unlink()
                shutil.move(str(live_path), str(staged))
            shutil.copy2(str(backup_path), str(live_path))
        except OSError as e:
            sys.stderr.write(
                f"install-manifest: reconcile failed at {live_path}: {e}\n"
            )
            return 1
        staged_repr = str(staged) if staged.exists() else ""
        pairs.append((str(live_path), staged_repr))
    for preserved, staged in pairs:
        sys.stdout.write(f"{preserved}\t{staged}\n")
    return 0


# ---- verify --------------------------------------------------------------

def cmd_verify(argv) -> int:
    quiet = "--quiet" in argv
    if not MANIFEST_PATH.is_file():
        if not quiet:
            sys.stderr.write(
                f"install-manifest: no manifest at {MANIFEST_PATH}\n"
            )
        return 1
    rc = 0
    for recorded_hash, path in read_manifest(MANIFEST_PATH):
        if not path.is_file():
            if not quiet:
                sys.stdout.write(f"missing: {path}\n")
            rc = 1
            continue
        if sha256_file(path) != recorded_hash:
            if not quiet:
                sys.stdout.write(f"diverged: {path}\n")
            rc = 1
    return rc


# ---- main ----------------------------------------------------------------

USAGE = """\
usage: install-manifest.py <subcommand> [args]
subcommands:
  write                    record SHA-256 of every Vigil-installed file
  diverged <backup-dir>    print live paths whose backup-side hash differs
  reconcile <backup-dir>   swap diverged paths to .new.<ext>; restore backups
  verify [--quiet]         exit 0 if all manifest entries match on disk
"""


def main(argv) -> int:
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        sys.stdout.write(__doc__)
        sys.stdout.write("\n")
        sys.stdout.write(USAGE)
        return 0
    cmd = argv[1]
    rest = argv[2:]
    if cmd == "write":
        return cmd_write(rest)
    if cmd == "diverged":
        return cmd_diverged(rest)
    if cmd == "reconcile":
        return cmd_reconcile(rest)
    if cmd == "verify":
        return cmd_verify(rest)
    return die(f"unknown subcommand: {cmd}\n{USAGE}")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
