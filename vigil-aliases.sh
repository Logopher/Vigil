# shellcheck shell=bash
# Curated env-var allowlist for the vigil wrappers. Vars not on this
# list (and not matching LC_* or GIT_*) are unset before launching
# Claude — the default sandbox covers filesystem reads but env vars
# are inherited by every child process unless explicitly cleared.
#
# Add to this list (in your own ~/.bashrc, after sourcing this file)
# to pass through additional non-secret vars, e.g.:
#   _vigil_env_allowlist+=(AWS_PROFILE AWS_REGION)
_vigil_env_allowlist=(
    HOME PATH USER LOGNAME SHELL PWD TMPDIR
    TERM COLORTERM NO_COLOR CLICOLOR
    LANG LC_ALL TZ
    SSH_AUTH_SOCK SSH_AGENT_PID
    GPG_TTY GNUPGHOME
    XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR
    EDITOR VISUAL PAGER
    DISPLAY WAYLAND_DISPLAY XAUTHORITY
    CLAUDE_CONFIG_DIR
)

_vigil_run_with_logging() (
    # Subshell so env scrubbing and exports don't leak back to the
    # interactive shell that invoked us.

    # Refresh sandbox.filesystem.deny{Read,Write} before each session.
    # Paths that have become symlinks, disappeared, or changed type
    # would otherwise cause bubblewrap to fail closed for every
    # subprocess. Cheap; silently skipped if the filter is missing.
    local filter="$HOME/.config/vigil/scripts/filter-sandbox-denies.py"
    if [[ -f "$filter" ]] && command -v python3 >/dev/null 2>&1; then
        python3 "$filter" >/dev/null || true
    fi

    # Strip env vars not on the allowlist. compgen -v lists every set
    # variable; unset on read-only or special vars fails harmlessly.
    # Membership check uses string match (not associative array) for
    # bash 3.2 compatibility — macOS ships /bin/bash 3.2.
    # Loop-locals use the _vigil_ prefix so the loop doesn't clobber
    # itself when it iterates over them via compgen -v.
    local _vigil_allow_str=" ${_vigil_env_allowlist[*]} "
    local _vigil_v
    while IFS= read -r _vigil_v; do
        [[ "$_vigil_allow_str" == *" $_vigil_v "* ]] && continue
        [[ "$_vigil_v" == LC_* ]] && continue
        [[ "$_vigil_v" == GIT_* ]] && continue
        [[ "$_vigil_v" == BASH* || "$_vigil_v" == _ || "$_vigil_v" == _vigil_* ]] && continue
        unset "$_vigil_v" 2>/dev/null || true
    done < <(compgen -v)

    # Optional post-scrub env injection. Lets users wire up opt-in
    # vars — notably an ssh-agent socket for signed commits — without
    # leaking them into every interactive shell via ~/.bashrc. The
    # file is sourced, so keep it to `export VAR=value` lines.
    if [[ -f "$HOME/.config/vigil/signing.env" ]]; then
        # shellcheck disable=SC1091
        . "$HOME/.config/vigil/signing.env"
    fi

    VIGIL_SESSION_ID=$(date +%Y%m%d-%H%M%S)
    export VIGIL_SESSION_ID
    export VIGIL_LOG_DIR="$HOME/vigil-logs"
    mkdir -p "$VIGIL_LOG_DIR"
    local logfile="$VIGIL_LOG_DIR/session-$VIGIL_SESSION_ID.log"
    case "$(uname)" in
        Darwin|*BSD)
            # BSD script(1): `script [-q] file command...`
            script -q "$logfile" command claude "$@"
            ;;
        *)
            # util-linux script(1): `script -B file -c cmd`
            script -B "$logfile" -c "command claude $*"
            ;;
    esac

    # Post-process the raw script(1) capture into a readable .txt
    # transcript alongside it. The .log keeps full TTY fidelity for
    # replay; the .txt is for actual reading and grep-ability.
    local stripper="$HOME/.config/vigil/scripts/strip-ansi.py"
    if [[ -f "$stripper" && -f "$logfile" ]] && command -v python3 >/dev/null 2>&1; then
        python3 "$stripper" "$logfile" "${logfile%.log}.txt" 2>/dev/null || true
    fi
)

vigil() {
    if [[ "${1-}" == "set-default" ]]; then
        shift
        vigil_set_default "$@"
        return
    fi
    _vigil_run_with_logging --settings "$HOME/.config/vigil/policies/strict.json" "$@"
}

vigil-dev() {
    local project_root
    project_root="$(git rev-parse --show-toplevel 2>/dev/null)" || project_root="$PWD"
    (
        cd "$project_root" || return 1
        _vigil_run_with_logging --settings "$HOME/.config/vigil/policies/dev.json" "$@"
    )
}

vigil-strict() {
    _vigil_run_with_logging --settings "$HOME/.config/vigil/policies/strict.json" "$@"
}

vigil-yolo() {
    _vigil_run_with_logging --settings "$HOME/.config/vigil/policies/yolo.json" "$@"
}

vigil_set_default() {
    local force=0 target="" current_profile="default" raw_profile=""
    local vigil_dir="$HOME/.config/vigil"
    local target_bundle="" current_bundle="" staging="" tmp_profile=""
    local dirty=() f="" dir="" arg=""

    for arg in "$@"; do
        case "$arg" in
            --force) force=1 ;;
            -*)
                printf 'vigil set-default: unknown option: %s\n' "$arg" >&2
                return 1
                ;;
            *)
                if [[ -n "$target" ]]; then
                    printf 'vigil set-default: unexpected argument: %s\n' "$arg" >&2
                    return 1
                fi
                target="$arg"
                ;;
        esac
    done

    if [[ -z "$target" ]]; then
        printf 'Usage: vigil set-default [--force] <profile>\n' >&2
        printf 'Per-session override: CLAUDE_CONFIG_DIR=~/.config/vigil/profiles/<profile> vigil ...\n' >&2
        return 1
    fi

    # Reject path-traversal and shell-metacharacter content in profile name.
    if [[ ! "$target" =~ ^[a-zA-Z0-9-]+$ ]]; then
        printf 'vigil set-default: invalid profile name: %s\n' "$target" >&2
        return 1
    fi

    target_bundle="$vigil_dir/profiles/$target"

    if [[ ! -f "$target_bundle/settings.json" ]]; then
        printf 'vigil set-default: profile "%s" not found (expected %s/settings.json)\n' \
            "$target" "$target_bundle" >&2
        return 1
    fi

    if pgrep -x claude >/dev/null 2>&1; then
        printf 'vigil set-default: Claude Code is running — close all sessions before switching profiles\n' >&2
        return 1
    fi
    # Belt-and-suspenders open-files check; skipped silently if lsof is absent.
    if command -v lsof >/dev/null 2>&1 && lsof +D "$HOME/.claude/" 2>/dev/null | grep -q .; then
        printf 'vigil set-default: files under ~/.claude/ are open — close all sessions before switching profiles\n' >&2
        return 1
    fi

    if [[ -f "$vigil_dir/active-profile" ]]; then
        raw_profile="$(cat "$vigil_dir/active-profile")"
        if [[ "$raw_profile" =~ ^[a-zA-Z0-9-]+$ ]]; then
            current_profile="$raw_profile"
        else
            printf 'vigil set-default: active-profile contains invalid value "%s", treating as "default"\n' \
                "$raw_profile" >&2
        fi
    fi

    if [[ "$current_profile" == "$target" ]]; then
        printf 'Already on profile: %s\n' "$target"
        return 0
    fi

    # Diff check against current bundle.
    # Skipped when current profile is "default": ~/.config/vigil/profiles/default
    # is a symlink to ~/.claude/ so comparing live files against the bundle is
    # comparing a file against itself — always identical regardless of edits.
    if [[ "$current_profile" != "default" && $force -eq 0 ]]; then
        current_bundle="$vigil_dir/profiles/$current_profile"
        dirty=()
        for f in settings.json CLAUDE.md; do
            if [[ -f "$HOME/.claude/$f" ]] && \
               ! diff -q "$HOME/.claude/$f" "$current_bundle/$f" >/dev/null 2>&1; then
                dirty+=("$HOME/.claude/$f")
            fi
        done
        for dir in hooks agents; do
            if [[ -d "$HOME/.claude/$dir" ]] && \
               ! diff -rq "$HOME/.claude/$dir" "$current_bundle/$dir" >/dev/null 2>&1; then
                dirty+=("$HOME/.claude/$dir/")
            fi
        done
        if [[ ${#dirty[@]} -gt 0 ]]; then
            printf 'vigil set-default: local edits detected — copy them to the bundle or pass --force to overwrite:\n' >&2
            printf '  %s\n' "${dirty[@]}" >&2
            return 1
        fi
    fi

    staging="$vigil_dir/staging"
    [[ -n "$staging" ]] || { printf 'vigil set-default: internal error: empty staging path\n' >&2; return 1; }
    rm -rf "$staging"
    mkdir -p "$staging"
    cp -r -- "$target_bundle/." "$staging/"

    for f in settings.json CLAUDE.md; do
        if [[ -f "$staging/$f" ]]; then
            [[ -f "$HOME/.claude/$f" ]] && mv -- "$HOME/.claude/$f" "$HOME/.claude/$f.bak"
            mv -- "$staging/$f" "$HOME/.claude/$f"
            rm -f "$HOME/.claude/$f.bak"
        fi
    done
    for dir in hooks agents; do
        if [[ -d "$staging/$dir" ]]; then
            [[ -d "$HOME/.claude/$dir" ]] && mv -- "$HOME/.claude/$dir" "$HOME/.claude/$dir.bak"
            mv -- "$staging/$dir" "$HOME/.claude/$dir"
            rm -rf "$HOME/.claude/$dir.bak"
            chmod +x "$HOME/.claude/$dir/"*.sh 2>/dev/null || true
        fi
    done
    rm -rf "$staging"

    # Write active-profile atomically via temp-file rename.
    tmp_profile="$(mktemp "$vigil_dir/.active-profile.XXXXXX")"
    printf '%s\n' "$target" > "$tmp_profile"
    mv -- "$tmp_profile" "$vigil_dir/active-profile"

    printf 'Switched to profile: %s\n' "$target"
}

# Operator-only: install the per-repo pre-push review gate. Sandboxed
# Vigil sessions deny `Bash(vigil-install-review:*)` in every policy.
# Run from inside the target repo so the CWD-pinned sandbox denies
# (filter-sandbox-denies.py expands the placeholder at vigil launch)
# already cover its .git/config and .git/hooks/.
vigil-install-review() {
    "$HOME/.config/vigil/scripts/vigil-install-review" "$@"
}

# Open a session transcript in $PAGER. With no args, opens the most
# recent. With -N (e.g., -1), opens the transcript that many positions
# back from newest: -1 is the previous session, -2 the one before that.
# With a date-prefix string (e.g., 20260413 or 2026-04-13), opens the
# first transcript whose timestamp starts with that prefix; dashes are
# stripped before matching since session filenames use compact
# YYYYMMDD-HHMMSS form.
#
# Sorting relies on session filenames being fixed-width and lex-sortable
# the same as chronologically — keep in sync with the session-filename
# format used by _vigil_run_with_logging above.
vigil-log() {
    local logdir="$HOME/vigil-logs"
    local pager="${PAGER:-less}"
    local arg="${1:-}"

    shopt -s nullglob
    local all=("$logdir"/session-*.txt)
    shopt -u nullglob

    if [[ ${#all[@]} -eq 0 ]]; then
        echo "vigil-log: no transcripts in $logdir" >&2
        return 1
    fi

    # Reverse to newest-first; filenames (session-YYYYMMDD-HHMMSS.txt)
    # sort lexicographically the same as chronologically.
    local files=()
    local i
    for ((i=${#all[@]}-1; i>=0; i--)); do
        files+=("${all[$i]}")
    done

    local target=""
    if [[ -z "$arg" ]]; then
        target="${files[0]}"
    elif [[ "$arg" =~ ^-[0-9]+$ ]]; then
        local idx="${arg#-}"
        if (( idx >= ${#files[@]} )); then
            echo "vigil-log: only ${#files[@]} transcript(s) available" >&2
            return 1
        fi
        target="${files[$idx]}"
    else
        local query="${arg//-/}"
        local f base stamp
        for f in "${files[@]}"; do
            base="$(basename "$f")"
            stamp="${base#session-}"
            stamp="${stamp%.txt}"
            if [[ "$stamp" == "$query"* ]]; then
                target="$f"
                break
            fi
        done
        if [[ -z "$target" ]]; then
            echo "vigil-log: no transcript matching '$arg'" >&2
            return 1
        fi
    fi

    # eval lets multi-word PAGER values work (e.g., PAGER="less -R").
    # Target is shell-quoted to survive paths with spaces.
    eval "$pager $(printf '%q' "$target")"
}

# Prune ~/vigil-logs. Forwards args to scripts/prune-logs.py; run
# `vigil-log-prune --help` for flags. The same script runs
# automatically at SessionStart (90d age, 2G cap) via the profile
# hook; this wrapper is for manual on-demand pruning with custom
# thresholds or --dry-run.
vigil-log-prune() {
    local script="$HOME/.config/vigil/scripts/prune-logs.py"
    if [[ ! -f "$script" ]]; then
        echo "vigil-log-prune: $script not found" >&2
        return 1
    fi
    python3 "$script" "$@"
}
