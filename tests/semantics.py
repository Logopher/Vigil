#!/usr/bin/env python3
"""Tier 3 policy semantics: JSON-structural invariants across the default
profile and the three shipped policies. Verifies deny-list consistency,
allow/deny non-contradiction, and that the shipped policies compose
cleanly with the profile.
"""
import difflib
import json
import sys
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent.parent
PROFILE = REPO_DIR / "profiles" / "default" / "settings.template.json"
DEV = REPO_DIR / "policies" / "dev.template.json"
STRICT = REPO_DIR / "policies" / "strict.template.json"
YOLO = REPO_DIR / "policies" / "yolo.json"

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


def deny_of(doc: dict) -> list[str]:
    return doc.get("permissions", {}).get("deny", [])


def allow_of(doc: dict) -> list[str]:
    return doc.get("permissions", {}).get("allow", [])


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
    # Exact-string only. Glob-aware subsumption (e.g., allow "Bash(git:*)"
    # vs profile-deny "Bash(git push:*)") is tracked in BACKLOG.md.
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


def main() -> int:
    profile = load(PROFILE)
    dev = load(DEV)
    strict = load(STRICT)
    yolo = load(YOLO)
    policies = [(DEV.name, dev), (STRICT.name, strict), (YOLO.name, yolo)]

    check_profile_keys(profile)
    check_baseline_consistency(profile, strict)
    check_dev_superset(profile, dev)
    check_yolo_guards(yolo)
    check_allow_deny_noncontradiction(profile, policies)
    check_deep_merge(profile, policies)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
