#!/usr/bin/env bash
# End-to-end tests for scripts/vigil-install-review (Phase D installer)
# and scripts/hooks/pre-push (the gate template it deploys).
#
# Strategy: install Vigil into a single ephemeral $HOME shared across
# cases; spin up a fresh git repo per case; cover the happy path,
# every collision class, sandbox-coverage refusal, idempotency,
# manifest-tamper detection, Vigil-absent simulation (rsync to a
# Vigil-less HOME), and --no-verify bypass.
set -uo pipefail
shopt -s nullglob

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

failed=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; failed=1; }
section() { printf '\n-- %s --\n' "$1"; }

TMPDIRS=()
cleanup() {
    local d
    for d in "${TMPDIRS[@]}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT
mktmp() {
    local d
    d=$(mktemp -d)
    TMPDIRS+=("$d")
    printf '%s' "$d"
}

# Identity passed per-invocation; sandbox blocks persistent git-config.
GIT_ID=(-c user.email=test@example.invalid -c user.name=vigil-install-test)

# Install Vigil into a shared $HOME for all cases — the installer
# refuses to clobber an existing layout, so each case can't get its
# own install. Per-case isolation is at the repo level instead.
SHARED_HOME=$(mktmp)
HOME="$SHARED_HOME" bash "$REPO_DIR/install.sh" >/dev/null 2>&1 || {
    echo "FATAL: install.sh failed against shared HOME" >&2
    exit 2
}
INSTALLER="$SHARED_HOME/.config/vigil/scripts/vigil-install-review"

# Synthesize a settings.json whose denyWrite covers <repo>/.git/config
# and <repo>/.git/hooks/. The real install at this HOME points at
# ~/.git/* (settings.json was written from $SHARED_HOME's CWD), so
# every test repo needs a per-case settings.json overlay.
write_coverage_settings() {
    local repo="$1"
    cat > "$SHARED_HOME/.claude/settings.json" <<EOF
{
  "sandbox": {
    "filesystem": {
      "denyWrite": [
        "$repo/.git/config",
        "$repo/.git/hooks/"
      ]
    }
  }
}
EOF
}

seed_repo() {
    local repo="$1"
    git init -q "$repo"
    (cd "$repo" && env -u VIGIL_SESSION_ID \
        git "${GIT_ID[@]}" commit --allow-empty -qm 'initial')
    write_coverage_settings "$repo"
}

run_installer() {
    local repo="$1"
    HOME="$SHARED_HOME" "$INSTALLER" "$repo" 2>&1
}

# ---------------------------------------------------------------------------
section "Happy path"
repo=$(mktmp)
seed_repo "$repo"
out=$(run_installer "$repo")
rc=$?
if [[ $rc -eq 0 ]]; then
    pass "installer exits 0 on clean repo"
else
    fail "installer rc=$rc, output: $out"
fi
for f in prepare-commit-msg pre-push .manifest; do
    if [[ -f "$repo/.git/review-gate/$f" ]]; then
        pass "gate file present: $f"
    else
        fail "missing gate file: $f"
    fi
done
for f in prepare-commit-msg pre-push; do
    if [[ -x "$repo/.git/review-gate/$f" ]]; then
        pass "gate hook executable: $f"
    else
        fail "gate hook not executable: $f"
    fi
done
if [[ -r "$repo/.git/review-gate/.manifest" && \
      ! -x "$repo/.git/review-gate/.manifest" ]]; then
    pass "manifest is 0644 (readable, not executable)"
else
    fail "manifest mode unexpected"
fi
hp=$(cd "$repo" && git config --local --get core.hooksPath)
if [[ "$hp" == ".git/review-gate" ]]; then
    pass "core.hooksPath set to .git/review-gate"
else
    fail "core.hooksPath = '$hp', expected '.git/review-gate'"
fi
# Manifest hashes verifiable by sha256sum -c.
if (cd / && sha256sum -c "$repo/.git/review-gate/.manifest" >/dev/null 2>&1); then
    pass "manifest hashes verify with sha256sum -c"
else
    fail "manifest verification failed"
fi
# Manifest covers vigil-review.py (architect-required: gate value
# depends on renderer integrity).
if grep -q "vigil-review.py" "$repo/.git/review-gate/.manifest"; then
    pass "manifest includes vigil-review.py"
else
    fail "manifest missing vigil-review.py entry"
fi

# ---------------------------------------------------------------------------
section "Collision: pre-existing core.hooksPath (third-party)"
repo=$(mktmp)
seed_repo "$repo"
(cd "$repo" && git config --local core.hooksPath ".husky")
out=$(run_installer "$repo"); rc=$?
if [[ $rc -ne 0 && "$out" == *core.hooksPath* && "$out" == *.husky* ]]; then
    pass "abort names core.hooksPath and the third-party value"
else
    fail "expected abort naming third-party hooksPath, got rc=$rc out=$out"
fi
[[ ! -d "$repo/.git/review-gate" ]] && pass "no gate dir created on collision" \
    || fail "gate dir created despite collision"

# ---------------------------------------------------------------------------
section "Collision: core.hooksPath pinned to default (.git/hooks)"
repo=$(mktmp)
seed_repo "$repo"
(cd "$repo" && git config --local core.hooksPath ".git/hooks")
out=$(run_installer "$repo"); rc=$?
if [[ $rc -ne 0 && "$out" == *"explicitly pinned"* ]]; then
    pass "abort distinguishes default-pin from third-party"
else
    fail "expected differentiated message for default pin, got: $out"
fi

# ---------------------------------------------------------------------------
section "Collision: existing .git/hooks/pre-push"
repo=$(mktmp)
seed_repo "$repo"
mkdir -p "$repo/.git/hooks"
printf '#!/bin/sh\nexit 0\n' > "$repo/.git/hooks/pre-push"
chmod +x "$repo/.git/hooks/pre-push"
out=$(run_installer "$repo"); rc=$?
[[ $rc -ne 0 && "$out" == *pre-push* ]] && pass "abort names existing hook" \
    || fail "expected abort naming pre-push, got: $out"

# ---------------------------------------------------------------------------
section "Collision: .husky/ directory"
repo=$(mktmp); seed_repo "$repo"
mkdir -p "$repo/.husky"
out=$(run_installer "$repo"); rc=$?
[[ $rc -ne 0 && "$out" == *husky* ]] && pass "abort names husky" \
    || fail "expected abort naming husky, got: $out"

# ---------------------------------------------------------------------------
section "Collision: .pre-commit-config.yaml"
repo=$(mktmp); seed_repo "$repo"
touch "$repo/.pre-commit-config.yaml"
out=$(run_installer "$repo"); rc=$?
[[ $rc -ne 0 && "$out" == *pre-commit* ]] && pass "abort names pre-commit" \
    || fail "expected abort naming pre-commit, got: $out"

# ---------------------------------------------------------------------------
section "Collision: lefthook.yml"
repo=$(mktmp); seed_repo "$repo"
touch "$repo/lefthook.yml"
out=$(run_installer "$repo"); rc=$?
[[ $rc -ne 0 && "$out" == *lefthook* ]] && pass "abort names lefthook" \
    || fail "expected abort naming lefthook, got: $out"

# ---------------------------------------------------------------------------
section "Collision: .overcommit.yml"
repo=$(mktmp); seed_repo "$repo"
touch "$repo/.overcommit.yml"
out=$(run_installer "$repo"); rc=$?
[[ $rc -ne 0 && "$out" == *overcommit* ]] && pass "abort names overcommit" \
    || fail "expected abort naming overcommit, got: $out"

# ---------------------------------------------------------------------------
section "Sandbox-coverage abort (settings.json points elsewhere)"
repo=$(mktmp); seed_repo "$repo"
# Overwrite settings.json with denies pinned to a different repo path.
cat > "$SHARED_HOME/.claude/settings.json" <<EOF
{
  "sandbox": {
    "filesystem": {
      "denyWrite": [
        "/some/other/repo/.git/config",
        "/some/other/repo/.git/hooks/"
      ]
    }
  }
}
EOF
out=$(run_installer "$repo"); rc=$?
if [[ $rc -ne 0 && "$out" == *"sandbox denyWrite"* && "$out" == *"Re-launch"* ]]; then
    pass "abort names sandbox coverage gap with re-launch guidance"
else
    fail "expected sandbox-coverage abort, got rc=$rc out=$out"
fi

# ---------------------------------------------------------------------------
section "Idempotency: re-run on installed repo refreshes manifest"
repo=$(mktmp); seed_repo "$repo"
run_installer "$repo" >/dev/null
orig_manifest=$(cat "$repo/.git/review-gate/.manifest")
out=$(run_installer "$repo"); rc=$?
if [[ $rc -eq 0 ]]; then
    pass "re-run exits 0"
else
    fail "re-run rc=$rc out=$out"
fi
if [[ -f "$repo/.git/review-gate/.manifest.prev" ]]; then
    pass ".manifest.prev rotated"
else
    fail ".manifest.prev not created on re-run"
fi
new_manifest=$(cat "$repo/.git/review-gate/.manifest")
[[ "$orig_manifest" == "$new_manifest" ]] && pass "manifest content stable on re-run" \
    || fail "manifest changed on re-run with no source change"

# ---------------------------------------------------------------------------
# For the push-time tests we need a real bare remote and an isolated
# git environment so the operator's ~/.gitconfig (templateDir, hooks)
# cannot leak into the test fixtures.
fresh_repo_with_remote() {
    local repo="$1"
    seed_repo "$repo"
    bare=$(mktmp)
    rm -rf "$bare"
    git init --bare -q "$bare"
    (cd "$repo" && git "${GIT_ID[@]}" remote add origin "$bare")
    printf '%s\n' "$bare"
}

run_push() {
    local repo="$1"; shift
    (cd "$repo" && \
        HOME="$SHARED_HOME" \
        GIT_CONFIG_GLOBAL=/dev/null \
        git "${GIT_ID[@]}" push "$@" origin HEAD:refs/heads/main 2>&1)
}

# ---------------------------------------------------------------------------
section "Tamper detection: modified pre-push fails hash check"
repo=$(mktmp)
fresh_repo_with_remote "$repo" >/dev/null
run_installer "$repo" >/dev/null
# Tamper: swap a working line for a no-op so on-disk content differs.
sed -i 's|set -eu|set -eu # tampered|' "$repo/.git/review-gate/pre-push"
out=$(run_push "$repo"); rc=$?
if [[ $rc -ne 0 && "$out" == *"hash mismatch"* ]]; then
    pass "tampered pre-push triggers hash mismatch abort"
else
    fail "expected hash-mismatch abort, got rc=$rc out=$out"
fi

# ---------------------------------------------------------------------------
section "Vigil-absent simulation"
repo=$(mktmp)
fresh_repo_with_remote "$repo" >/dev/null
run_installer "$repo" >/dev/null
# Run the same push against a HOME that lacks ~/.config/vigil.
absent_home=$(mktmp)
out=$(cd "$repo" && \
    HOME="$absent_home" \
    GIT_CONFIG_GLOBAL=/dev/null \
    git "${GIT_ID[@]}" push origin HEAD:refs/heads/main 2>&1)
rc=$?
if [[ $rc -ne 0 \
   && "$out" == *"Vigil absent"* \
   && "$out" == *"--no-verify"* \
   && "$out" == *"core.hooksPath"* ]]; then
    pass "Vigil-absent: classified, all three escapes named"
else
    fail "expected Vigil-absent classification with all three escapes, got: $out"
fi

# ---------------------------------------------------------------------------
section "--no-verify bypass"
repo=$(mktmp)
fresh_repo_with_remote "$repo" >/dev/null
run_installer "$repo" >/dev/null
sed -i 's|set -eu|set -eu # tampered|' "$repo/.git/review-gate/pre-push"
out=$(run_push "$repo" --no-verify); rc=$?
if [[ $rc -eq 0 ]]; then
    pass "--no-verify bypasses tampered hook"
else
    fail "expected --no-verify to succeed even with tamper, got rc=$rc out=$out"
fi

# ---------------------------------------------------------------------------
echo
if [[ $failed -eq 0 ]]; then
    echo "All vigil-install-review tests passed."
    exit 0
else
    echo "Some vigil-install-review tests FAILED." >&2
    exit 1
fi
