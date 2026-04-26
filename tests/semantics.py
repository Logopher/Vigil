#!/usr/bin/env python3
"""Tier 3 policy semantics: JSON-structural invariants across the default
profile and the three shipped policies. Verifies deny-list consistency,
allow/deny non-contradiction, and that the shipped policies compose
cleanly with the profile.
"""
import difflib
import json
import re
import sys
from pathlib import Path

PATH_TOOLS = ("Read", "Edit", "Write", "MultiEdit", "NotebookEdit")
MATCHER_RE = re.compile(r"^([A-Za-z]+)\((.*)\)$")

REPO_DIR = Path(__file__).resolve().parent.parent
PROFILE_DIR = REPO_DIR / "profiles" / "default"
PERMISSIVE_DIR = REPO_DIR / "profiles" / "permissive"
DEV = REPO_DIR / "policies" / "dev.template.json"
STRICT = REPO_DIR / "policies" / "strict.template.json"
YOLO = REPO_DIR / "policies" / "yolo.json"
DEFAULT_HOOKS = REPO_DIR / "profiles" / "default" / "hooks"
DEFAULT_AGENTS = REPO_DIR / "profiles" / "default" / "agents"
PERMISSIVE_HOOKS = REPO_DIR / "profiles" / "permissive" / "hooks"
PERMISSIVE_AGENTS = REPO_DIR / "profiles" / "permissive" / "agents"

failed = False


def pass_(msg: str) -> None:
    print(f"  PASS  {msg}")


def fail(msg: str) -> None:
    global failed
    print(f"  FAIL  {msg}", file=sys.stderr)
    failed = True


def section(title: str) -> None:
    print(f"\n-- {title} --")


def load(path: Path) -> dict:
    with open(path) as f:
        return json.load(f)


def load_profile(profile_dir: Path) -> dict:
    base = load(profile_dir / "settings.json")
    local = load(profile_dir / "settings.local.template.json")
    merged = deep_merge(base, local)
    # Claude Code unions permission arrays from both files; deep_merge's
    # list-replacement semantics are wrong for deny/allow/ask.
    for key in ("deny", "allow", "ask"):
        base_vals = base.get("permissions", {}).get(key, [])
        local_vals = local.get("permissions", {}).get(key, [])
        combined = list(dict.fromkeys(base_vals + local_vals))
        if base_vals or local_vals:
            merged.setdefault("permissions", {})[key] = combined
    return merged


def deny_of(doc: dict) -> list[str]:
    return doc.get("permissions", {}).get("deny", [])


def allow_of(doc: dict) -> list[str]:
    return doc.get("permissions", {}).get("allow", [])


def ask_of(doc: dict) -> list[str]:
    return doc.get("permissions", {}).get("ask", [])


def deep_merge(left, right):
    """Mirror jq's `*` recursive merge for the cases this test exercises:
    dicts merge key-by-key (recursing on dict values); for non-dict values
    the right-hand side wins. A key that is a dict on one side and a
    non-dict on the other raises TypeError — that is the type conflict
    this section exists to detect.
    """
    if isinstance(left, dict) and isinstance(right, dict):
        out = dict(left)
        for k, rv in right.items():
            if k in out:
                lv = out[k]
                if type(lv) is not type(rv):
                    raise TypeError(
                        f"type conflict at key {k!r}: {type(lv).__name__} vs {type(rv).__name__}"
                    )
                out[k] = deep_merge(lv, rv) if isinstance(lv, dict) else rv
            else:
                out[k] = rv
        return out
    return right


def check_profile_keys(profile: dict) -> None:
    section("Profile has expected top-level keys")
    for key in ("sandbox", "permissions", "hooks"):
        if key in profile:
            pass_(f"profile has key: {key}")
        else:
            fail(f"profile missing key: {key}")


def check_baseline_consistency(profile: dict, strict: dict) -> None:
    section("Deny baseline consistency (profile vs. strict)")
    p = sorted(deny_of(profile))
    s = sorted(deny_of(strict))
    if p == s:
        pass_("profile baseline deny matches strict policy deny")
    else:
        fail("profile and strict deny lists differ")
        diff = difflib.unified_diff(p, s, fromfile="profile", tofile="strict", lineterm="")
        for line in diff:
            print(line, file=sys.stderr)


def check_dev_superset(profile: dict, dev: dict) -> None:
    section("Dev deny is a superset of profile deny")
    missing = sorted(set(deny_of(profile)) - set(deny_of(dev)))
    if not missing:
        pass_("dev contains every baseline deny")
    else:
        for entry in missing:
            fail(f"dev missing baseline deny: {entry}")


def check_yolo_guards(yolo: dict) -> None:
    section("Yolo retains minimum catastrophe guards")
    yd = set(deny_of(yolo))
    for guard in ("Bash(rm:*)", "Bash(sudo:*)"):
        if guard in yd:
            pass_(f"yolo denies {guard}")
        else:
            fail(f"yolo missing guard: {guard}")


def check_allow_deny_noncontradiction(profile: dict, policies: list[tuple[str, dict]]) -> None:
    section("No policy allow conflicts with profile deny (exact-string)")
    # Exact-string only. Glob-aware subsumption (dead-rule detection) is
    # handled separately in check_allow_deny_dead_rules.
    pdeny = set(deny_of(profile))
    for name, policy in policies:
        conflicts = [a for a in allow_of(policy) if a in pdeny]
        if not conflicts:
            pass_(f"{name}: no allow entries match profile deny (exact-string)")
        else:
            for entry in conflicts:
                fail(f"{name}: allow entry '{entry}' matches profile deny")


def check_deep_merge(profile: dict, policies: list[tuple[str, dict]]) -> None:
    section("Deep merge produces valid JSON with expected top-level shape")
    # Does not claim to match Claude Code's actual merge semantics —
    # verifies the two files can coexist without type conflicts.
    for name, policy in policies:
        try:
            merged = deep_merge(profile, policy)
        except TypeError as e:
            fail(f"{name}: merge failed ({e})")
            continue
        missing = [k for k in ("sandbox", "permissions", "hooks") if k not in merged]
        if not missing:
            pass_(f"{name}: merges with profile retaining all top-level keys")
        else:
            fail(f"{name}: merged result missing keys: {' '.join(missing)}")


def _path_pattern_to_regex(pat: str) -> re.Pattern:
    # `**` → any subtree (including slashes); `*` → single path segment.
    # All other characters are treated as literals.
    out: list[str] = []
    i = 0
    while i < len(pat):
        if pat[i:i + 2] == "**":
            out.append(".*")
            i += 2
        elif pat[i] == "*":
            out.append("[^/]*")
            i += 1
        else:
            out.append(re.escape(pat[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def _normalize_matcher(entry: str):
    """Return a structured form of a matcher, or None if unrecognized.

    Shapes returned:
      ("bash", tokens: tuple[str, ...], is_prefix: bool)
      ("path", tool: str, glob: str)

    Only the `:*` suffix produces is_prefix=True. Space-form Bash matchers
    (e.g., the profile's "Bash(git checkout -- *)") fall through to
    is_prefix=False and are compared by exact token-tuple equality; any `*`
    inside a space-form is treated as a literal token, not a wildcard.
    Accepted because CLAUDE.md forbids the space form and Tier 1 static.sh
    flags single-word occurrences; the one surviving multi-word entry does
    not shape subsumption for any shipped policy.
    """
    m = MATCHER_RE.match(entry)
    if not m:
        return None
    tool, arg = m.group(1), m.group(2)
    if tool == "Bash":
        if arg.endswith(":*"):
            return ("bash", tuple(arg[:-2].split()), True)
        return ("bash", tuple(arg.split()), False)
    if tool in PATH_TOOLS:
        return ("path", tool, arg)
    return None


def _strictly_subsumes(a, b) -> bool:
    """True iff every invocation matching b also matches a, and a is strictly broader.

    Approximation, not a full glob-intersection solver. For paths, treats
    each pattern as a literal string when testing against the other's
    regex; if both regexes match, classifies as equivalent (not strict) so
    neither side is flagged. Sufficient for the subsumption class the
    shipped policies can plausibly ship.
    """
    if a[0] != b[0]:
        return False
    if a[0] == "bash":
        _, a_toks, a_prefix = a
        _, b_toks, _ = b
        if not a_prefix:
            return False
        if len(a_toks) >= len(b_toks):
            return False
        return b_toks[:len(a_toks)] == a_toks
    # path
    if a[1] != b[1]:
        return False
    ra = _path_pattern_to_regex(a[2])
    rb = _path_pattern_to_regex(b[2])
    a_covers_b = bool(ra.match(b[2]))
    b_covers_a = bool(rb.match(a[2]))
    return a_covers_b and not b_covers_a


def check_allow_deny_dead_rules(profile: dict, policies: list[tuple[str, dict]]) -> None:
    section("No policy allow/ask pattern is subsumed by a profile deny (dead rule)")
    # Runtime precedence is deny > ask > allow, so an allow or ask whose
    # match set is contained in a profile deny's match set can never fire.
    # Allow/ask strictly *broader* than a deny is legitimate layering (the
    # overlap is denied, the rest is allowed/asked) and is not flagged.
    # Scope: checks policy allow/ask against profile deny only; intra-policy
    # self-shadowing (allow vs. same policy's deny) is out of scope here.
    pdeny_normalized: list[tuple[tuple, str]] = []
    for entry in deny_of(profile):
        n = _normalize_matcher(entry)
        if n is not None:
            pdeny_normalized.append((n, entry))
    for name, policy in policies:
        conflicts: list[tuple[str, str, str]] = []
        for bucket, entries in (("allow", allow_of(policy)), ("ask", ask_of(policy))):
            for entry in entries:
                na = _normalize_matcher(entry)
                if na is None:
                    continue
                for nd, d_entry in pdeny_normalized:
                    if _strictly_subsumes(nd, na):
                        conflicts.append((bucket, entry, d_entry))
        if not conflicts:
            pass_(f"{name}: no allow/ask entries shadowed by a profile deny")
        else:
            for bucket, a_entry, d_entry in conflicts:
                fail(f"{name}: {bucket} '{a_entry}' is dead — shadowed by profile deny '{d_entry}'")


def check_path_representation(profile: dict, policies: list[tuple[str, dict]]) -> None:
    section("Path-bearing matchers avoid non-canonical tokens")
    # Every home-relative path in a Read/Edit/Write/MultiEdit/NotebookEdit
    # matcher must flow through the `{{HOME}}` token so the installer owns
    # the substitution. Forbid literal `~` (the installer does not expand
    # tildes), bare `$HOME`/`${HOME}` (bypasses the canonical token), and
    # `..` segments (non-canonical). Whether the runtime matcher tolerates
    # variant representations is unknowable from outside the harness; this
    # check sidesteps that by mandating one authoring form for our inputs.
    sources = [("profile", profile)] + [(n, p) for n, p in policies]
    for name, doc in sources:
        offenders: list[tuple[str, str, str]] = []
        for bucket, entries in (
            ("allow", allow_of(doc)),
            ("deny", deny_of(doc)),
            ("ask", ask_of(doc)),
        ):
            for entry in entries:
                m = MATCHER_RE.match(entry)
                if not m or m.group(1) not in PATH_TOOLS:
                    continue
                arg = m.group(2)
                if "~" in arg:
                    offenders.append((bucket, entry, "literal '~'"))
                if "$HOME" in arg or "${HOME}" in arg:
                    offenders.append((bucket, entry, "shell-style $HOME"))
                # match `..` as a path segment, not `...` or `foo..bar`
                if re.search(r"(^|/)\.\.(/|$)", arg):
                    offenders.append((bucket, entry, "non-canonical '..' segment"))
        if not offenders:
            pass_(f"{name}: path-bearing matchers are canonical")
        else:
            for bucket, entry, reason in offenders:
                fail(f"{name}: {bucket} entry '{entry}' contains {reason}")


def check_permissive_structure(permissive: dict) -> None:
    section("Permissive profile has expected top-level keys")
    for key in ("sandbox", "permissions", "hooks"):
        if key in permissive:
            pass_(f"permissive has key: {key}")
        else:
            fail(f"permissive missing key: {key}")


def check_permissive_subset(profile: dict, permissive: dict) -> None:
    section("Permissive deny is a subset of default deny")
    p_deny = set(deny_of(profile))
    perm_deny = set(deny_of(permissive))
    extras = sorted(perm_deny - p_deny)
    if not extras:
        pass_("permissive deny ⊆ default deny")
    else:
        for entry in extras:
            fail(f"permissive has deny entry not in default: {entry}")


def check_permissive_minimum_guards(permissive: dict) -> None:
    section("Permissive profile retains minimum guards")
    perm_deny = set(deny_of(permissive))
    for guard in ("Bash(rm:*)", "Bash(sudo:*)", "Bash(vigil-install-review:*)"):
        if guard in perm_deny:
            pass_(f"permissive denies {guard}")
        else:
            fail(f"permissive missing minimum guard: {guard}")
    spot = "Write({{HOME}}/.claude/settings.json)"
    if spot in perm_deny:
        pass_("permissive retains persistence-path Write deny (spot check)")
    else:
        fail(f"permissive missing persistence-path deny: {spot}")


def check_hook_agent_drift() -> None:
    section("Profile hook/agent parity (default vs. permissive)")
    for label, default_dir, perm_dir in (
        ("hooks", DEFAULT_HOOKS, PERMISSIVE_HOOKS),
        ("agents", DEFAULT_AGENTS, PERMISSIVE_AGENTS),
    ):
        default_files = {p.name for p in default_dir.glob("*") if p.is_file()}
        perm_files = {p.name for p in perm_dir.glob("*") if p.is_file()}
        for name in sorted(default_files):
            target = perm_dir / name
            if name not in perm_files:
                fail(f"permissive/{label}/{name} missing")
                continue
            if (default_dir / name).read_bytes() != target.read_bytes():
                fail(f"permissive/{label}/{name} differs from default")
            else:
                pass_(f"{label}/{name} identical")
        for name in sorted(perm_files - default_files):
            fail(f"permissive/{label}/{name} has no counterpart in default")


def main() -> int:
    profile = load_profile(PROFILE_DIR)
    permissive = load_profile(PERMISSIVE_DIR)
    dev = load(DEV)
    strict = load(STRICT)
    yolo = load(YOLO)
    policies = [(DEV.name, dev), (STRICT.name, strict), (YOLO.name, yolo)]

    check_profile_keys(profile)
    check_baseline_consistency(profile, strict)
    check_dev_superset(profile, dev)
    check_yolo_guards(yolo)
    check_allow_deny_noncontradiction(profile, policies)
    check_allow_deny_dead_rules(profile, policies)
    check_path_representation(profile, policies + [("permissive", permissive)])
    check_deep_merge(profile, policies + [("permissive", permissive)])

    check_permissive_structure(permissive)
    check_permissive_subset(profile, permissive)
    check_permissive_minimum_guards(permissive)
    check_hook_agent_drift()

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
