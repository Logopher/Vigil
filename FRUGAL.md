# Token-frugal Claude Code

Operator-side levers for reducing Claude Code token spend. Pairs with the profile-baseline self-policing rules in [`profiles/default/CLAUDE.md`](profiles/default/CLAUDE.md) (§ Token discipline) — those tell Claude how to behave; this tells *you* what to pull.

Most items here are things Claude can't do for itself: model selection, command invocation, session lifecycle, repo-level ignores. For the rules Claude enforces on itself mid-session, see the profile.

Feature set and command names drift across Claude Code releases. Verify against `/help` on your installed version if something here doesn't resolve.

## Track spend before optimizing

Intuition about where tokens go is usually wrong. Measure first.

- `/cost` — mid-session token-spend breakdown.
- `/stats` — aggregate usage across sessions (recent Claude Code versions surface both under `/usage`).
- `ccusage` — third-party npm package for finer-grained analysis of local session logs. Not affiliated with Anthropic.

## Pick the right model

`/model` switches the active model for the session. Defaults skew expensive.

- **Sonnet** handles ~80% of real work fine — reach for it first.
- **Opus** for genuinely hard architecture or debugging where the reasoning quality actually matters. Reserve, don't default.
- **Haiku** for renames, lookups, formatting, and other mechanical edits.
- **`opusplan`** — Opus for plan mode, Sonnet for execution. Opus-quality reasoning without the execution-phase cost.

## Cap thinking tokens

Extended thinking bills as output, and the default budget can be tens of thousands of tokens per request.

- `/effort` — lower the reasoning depth inline (several levels from low to max, plus auto; run `/help` for the current list).
- `/config` — view/toggle extended thinking for the session (Alt+T / Option+T is the keyboard equivalent).
- `MAX_THINKING_TOKENS=8000` in `settings.json` under the `env` key caps the budget. Known quirk: currently forces thinking on every request, including simple ones — verify it suits your workload before setting globally.

## Keep context lean

CLAUDE.md is re-read on every turn and unused files in the working tree leak into exploration. Each saved token pays back every turn.

- **Exclude paths from Claude's view.** Use `permissions.deny` entries (`Read(path/**)`) in `settings.json` — this is the shipped mechanism. A `.claudeignore` file at repo root is a community convention with an open upstream feature request; Vigil ships one, but don't rely on it as enforcement.
- `/clear` — drop prior conversation from context between unrelated tasks.
- `/compact` — mid-session summarization when the transcript grows long; accepts optional instructions on what to preserve.
- One session per logical task. A fresh session with a good CLAUDE.md often beats a long session with compaction.

## Prompt specifically

"Fix the auth bug" triggers codebase-wide exploration. "In `src/auth.js`, token refresh around line 80 fails when expired — fix it" goes straight to the work. Point to files, line ranges, or symbols whenever you know them.

## Plan-mode first for expensive paths

`Shift+Tab` twice enters plan mode. For codebase-wide searches, multi-file refactors, or new-feature scoping, approve the approach before tokens are spent executing a wrong path. Rejecting a wrong plan costs only text; aborting a wrong execution costs text *plus* tool tokens.

Windows caveat: in recent Claude Code versions on Windows the `Shift+Tab` chord can skip plan mode and toggle Edit ↔ Auto-Accept instead. Use the `/plan` command or `Alt+M` as a fallback.

## Settings caps (not set by default)

`max_turns` and `timeout_minutes` are `settings.json` keys that cap runaway loops during automated or hands-off runs. Vigil does not ship defaults; set them in your own `settings.local.json` or a policy overlay if you're running long unattended sessions.
