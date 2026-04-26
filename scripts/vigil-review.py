#!/usr/bin/env python3
"""vigil-review: paranoid-rendering commit inspection CLI.

Default behavior: show each commit in @{u}..HEAD with a sanitized header,
--stat summary, and any Vigil-Session: trailer resolved to a transcript path.

Security posture: the script is a viewer, not a gate. Its load-bearing job is
stripping terminal escape sequences, Unicode BIDI overrides, zero-width
characters, and other glyph-level attacks from untrusted git content before
it reaches the operator's terminal. Output is written directly to stdout
with no pager invocation; any residual escape that slipped the sanitizer
cannot be re-interpreted by a pager we never spawn.

Exit codes:
  0  success (or --prompt answered y/Y)
  1  --prompt answered anything else, empty range handled, or runtime error
  2  --from-hook self-check failed, or usage error
"""
import argparse
import glob as _glob
import os
import re
import stat
import subprocess  # nosec B404 -- subprocess is intentional; all calls use list args and shell=False
import sys
from pathlib import Path


# CSI sequences: ESC [ params final-byte.
ANSI_CSI = re.compile(r'\x1b\[[0-9;:?<>!= ]*[@A-Za-z`~^_\\|]')
# OSC sequences: ESC ] ... ST (ST = BEL or ESC \).
ANSI_OSC = re.compile(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)')
# DCS / APC / PM / SOS sequences: ESC P|_|^|X ... ST.
ANSI_DCS = re.compile(r'\x1b[P_^X][^\x1b]*\x1b\\')
# Charset selection and similar two-byte sequences.
ANSI_2BYTE = re.compile(r'\x1b[\(\)*+#@=>][a-zA-Z0-9]?')
# Bare ESC + final-byte short sequences.
ANSI_SHORT = re.compile(r'\x1b[78cDEHMNOZ\\]')
# C1 controls: some terminals interpret these as 7-bit ESC-equivalents.
C1_CONTROLS = re.compile(r'[\u0080-\u009f]')
# Trojan-source attack primitives. Includes the LRM/RLM weak directional
# marks alongside the stronger override/embed/isolate codepoints — both are
# documented bidi-confusion vectors against diff review.
BIDI_MARKS = re.compile(r'[\u200e\u200f\u202a-\u202e\u2066-\u2069\u061c\u180e]')
# Zero-width and otherwise-invisible Unicode that hides content in plain
# sight: width zero, soft hyphen, combining grapheme joiner, invisible
# math operators, variation selectors, Hangul fillers.
ZERO_WIDTH = re.compile(
    r'[\u200b-\u200d\u00ad\u034f\u2060-\u2064\ufeff'
    r'\ufe00-\ufe0f\u3164\uffa0]'
)
# Residual C0 controls (excludes tab and newline, which are preserved).
C0_CONTROLS = re.compile(r'[\x00-\x08\x0b-\x1f]')

MAX_LINE = 500
WRAP_MARK = '\u21b5'  # ↵, single BMP char
# Use U+23A1 / U+23A4 (bracket pieces) — unambiguous, no terminal meaning.
C0_ESCAPE_L = '\u23a1'
C0_ESCAPE_R = '\u23a4'


def _visible_c0(match: "re.Match[str]") -> str:
    return f'{C0_ESCAPE_L}{ord(match.group(0)):02x}{C0_ESCAPE_R}'


def sanitize(text: str) -> str:
    """Remove/escape hostile content from untrusted commit or diff text.

    Idempotent by construction: the MAX_LINE wrapper leaves already-wrapped
    lines untouched, and every escape replacement targets only source bytes
    not present in the replacement output.
    """
    text = ANSI_OSC.sub('', text)
    text = ANSI_DCS.sub('', text)
    text = ANSI_CSI.sub('', text)
    text = ANSI_2BYTE.sub('', text)
    text = ANSI_SHORT.sub('', text)
    text = BIDI_MARKS.sub('', text)
    text = ZERO_WIDTH.sub('', text)
    text = C1_CONTROLS.sub('', text)
    text = text.replace('\r', '')
    text = C0_CONTROLS.sub(_visible_c0, text)

    out_lines = []
    for line in text.split('\n'):
        if len(line) <= MAX_LINE:
            out_lines.append(line)
            continue
        remaining = line
        while len(remaining) > MAX_LINE:
            out_lines.append(remaining[:MAX_LINE - 1] + WRAP_MARK)
            remaining = remaining[MAX_LINE - 1:]
        out_lines.append(remaining)
    return '\n'.join(out_lines)


def _git_env() -> "dict[str, str]":
    env = dict(os.environ)
    # Neutralize user/system git config — color.ui, aliases, trailer
    # auto-insertion, etc. could all inject content we don't want.
    env['GIT_CONFIG_GLOBAL'] = '/dev/null'
    env['GIT_CONFIG_SYSTEM'] = '/dev/null'
    env['GIT_PAGER'] = 'cat'
    env['PAGER'] = 'cat'
    # Defang per-repo external commands: textconv/diff drivers and
    # external-diff hooks can execute arbitrary binaries from a malicious
    # .git/config. Drop them; the show output stays raw.
    env.pop('GIT_EXTERNAL_DIFF', None)
    env.pop('GIT_TEXTCONV', None)
    return env


# Override knobs the per-repo .git/config could otherwise turn into code
# execution against this process.
_GIT_HARDEN = (
    '-c', 'core.attributesFile=/dev/null',
    '-c', 'core.hooksPath=/dev/null',
    '-c', 'diff.external=',
    '-c', 'diff.textconv=',
)


def _git(args, cwd=None, input_text=None):
    # Subprocess output is decoded with errors='replace' so a commit
    # containing non-UTF-8 bytes (raw filename bytes, mojibake author
    # names) cannot crash the viewer before sanitization runs — the whole
    # paranoid-rendering posture depends on always reaching sanitize().
    return subprocess.run(  # nosec B603 B607 -- B603: list args, no shell=True; B607: git is a system binary, not user-controlled input
        ['git', *_GIT_HARDEN, *args],
        cwd=cwd,
        input=input_text,
        capture_output=True,
        text=True,
        encoding='utf-8',
        errors='replace',
        env=_git_env(),
    )


def rev_list(range_expr: str, cwd: str):
    # `--` ensures the range is parsed as a revision selector and never as
    # a flag, even if the user passes something starting with `-`.
    r = _git(['rev-list', '--reverse', range_expr, '--'], cwd=cwd)
    if r.returncode != 0:
        return None, r.stderr.strip()
    return [s for s in r.stdout.splitlines() if s], None


def commit_header(sha: str, cwd: str) -> str:
    fmt = (
        'commit %H%n'
        'Author: %an <%ae>%n'
        'Date:   %ad%n%n'
        '    %s%n%n'
        '%b'
    )
    r = _git(['show', '--stat', '--no-color', f'--format={fmt}', sha], cwd=cwd)
    return r.stdout


def commit_diff(sha: str, cwd: str) -> str:
    r = _git(['show', '--no-color', '--format=', sha], cwd=cwd)
    return r.stdout


# Session IDs are minted by vigil-aliases.sh as `date +%Y%m%d-%H%M%S`.
# Validating the trailer value against this shape stops a hostile commit
# from spoofing a path, embedding traversal, or planting misleading text
# in the rendered output via an attacker-controlled trailer. Do not loosen
# to include glob metacharacters (*, ?, [) — transcript_note relies on this
# being glob-safe when constructing the search pattern.
_SESSION_ID_RE = re.compile(r'^[0-9]{8}-[0-9]{6}$')


def vigil_session_id(sha: str, cwd: str):
    body = _git(['log', '-1', '--format=%B', sha], cwd=cwd)
    if body.returncode != 0:
        return None
    parsed = _git(['interpret-trailers', '--parse'], cwd=cwd, input_text=body.stdout)
    if parsed.returncode != 0:
        return None
    for line in parsed.stdout.splitlines():
        if line.startswith('Vigil-Session:'):
            return line.split(':', 1)[1].strip()
    return None


def transcript_note(session_id: str) -> str:
    if not _SESSION_ID_RE.match(session_id):
        return 'Transcript: invalid Vigil-Session id (rejected)'
    log_dir = os.environ.get('VIGIL_LOG_DIR') or os.path.expanduser('~/vigil-logs')
    # Glob for the optional repo+branch suffix; escape session_id defensively
    # even though _SESSION_ID_RE already excludes glob metacharacters.
    matches = sorted(Path(log_dir).glob(f'session-{_glob.escape(session_id)}*.txt'))
    if matches:
        return f'Transcript: {matches[0]}'
    return f'Transcript: transcript not on this host (session {session_id})'


def self_check():
    problems = []
    git_probe = subprocess.run(  # nosec B603 B607 -- B603: list args, no shell=True; B607: git is a system binary, not user-controlled input
        ['git', '--version'], capture_output=True, text=True
    )
    if git_probe.returncode != 0:
        problems.append('git not on PATH')
    if sys.version_info < (3, 8):
        problems.append(f'python3 too old: {sys.version_info[0]}.{sys.version_info[1]}')
    try:
        script_path = Path(__file__).resolve()
        st = script_path.stat()
        parent_st = script_path.parent.stat()
    except OSError as e:
        problems.append(f'cannot stat script: {e}')
    else:
        # Script integrity: anything that lets a non-owner mutate the file
        # or swap it atomically (parent-dir writability) breaks the gate.
        if st.st_uid != os.getuid():
            problems.append('script not owned by current user')
        if st.st_mode & stat.S_IWOTH:
            problems.append('script is world-writable')
        if st.st_mode & stat.S_IWGRP:
            problems.append('script is group-writable')
        if parent_st.st_uid != os.getuid():
            problems.append('script parent dir not owned by current user')
        if parent_st.st_mode & stat.S_IWOTH:
            problems.append('script parent dir is world-writable')
        if parent_st.st_mode & stat.S_IWGRP:
            problems.append('script parent dir is group-writable')
    return problems


def _prompt_line(prompt: str) -> str:
    sys.stderr.write(prompt)
    sys.stderr.flush()
    # Prefer /dev/tty so the prompt works when stdin is occupied (e.g., the
    # pre-push hook feeds ref data on stdin). Fall back to stdin only when
    # stdin is itself a terminal — a non-TTY stdin in this branch almost
    # always means we'd silently consume hook protocol data as the user's
    # answer, which is worse than failing loudly.
    try:
        with open('/dev/tty', 'r') as tty:
            return tty.readline()
    except OSError:
        if not sys.stdin.isatty():
            sys.stderr.write(
                '\nvigil-review: no /dev/tty and stdin is not a terminal; '
                'cannot prompt safely.\n'
            )
            return ''
        return sys.stdin.readline()


def _render_commit(sha: str, cwd: str, interactive: bool) -> str:
    header = commit_header(sha, cwd)
    session_id = vigil_session_id(sha, cwd)
    block = header
    if session_id:
        block = block + '\n' + transcript_note(session_id) + '\n'
    sys.stdout.write(sanitize(block))
    sys.stdout.write('\n')
    sys.stdout.flush()
    if not interactive:
        return 'next'
    while True:
        choice = _prompt_line('[d]iff, [n]ext, [q]uit: ').strip().lower()
        if choice == 'd':
            sys.stdout.write(sanitize(commit_diff(sha, cwd)))
            sys.stdout.write('\n')
            sys.stdout.flush()
        elif choice == 'q':
            return 'quit'
        else:
            return 'next'


def main(argv):
    parser = argparse.ArgumentParser(
        prog='vigil-review',
        description='Paranoid-rendering commit inspection CLI.',
    )
    parser.add_argument(
        'rev_ranges',
        nargs='*',
        metavar='REV_RANGE',
        help='git rev-ranges to review (default: @{u}..HEAD). With '
             '--from-hook, zero ranges runs only the self-check and exits.',
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        '--prompt',
        action='store_true',
        help='after rendering, ask y/N; exit 0 on y, 1 otherwise',
    )
    mode.add_argument(
        '--from-hook',
        action='store_true',
        help='run capability self-check; use from a pre-push hook',
    )
    parser.add_argument(
        '-C',
        dest='cwd',
        default=None,
        help='run as if invoked from this directory',
    )
    args = parser.parse_args(argv[1:])

    cwd = args.cwd or os.getcwd()

    if args.from_hook:
        problems = self_check()
        if problems:
            sys.stderr.write('vigil-review: self-check failed\n')
            for p in problems:
                sys.stderr.write(f'  - {p}\n')
            return 2

    ranges = list(args.rev_ranges)
    if not ranges:
        if args.from_hook:
            # Zero ranges in --from-hook is the self-check-only contract:
            # the pre-push hook calls this at the top of its self-check
            # phase to verify Python + capability surface in one shot.
            return 0
        ranges = ['@{u}..HEAD']

    interactive = not (args.prompt or args.from_hook)
    quit_loop = False
    for rev_range in ranges:
        shas, err = rev_list(rev_range, cwd)
        if shas is None:
            sys.stderr.write(
                f'vigil-review: could not resolve range {rev_range!r}: {err}\n'
            )
            return 1
        if not shas:
            sys.stdout.write(f'No commits in range {rev_range}.\n')
            continue
        for sha in shas:
            if _render_commit(sha, cwd, interactive) == 'quit':
                quit_loop = True
                break
        if quit_loop:
            break

    if args.prompt:
        answer = _prompt_line('Proceed? [y/N] ').strip().lower()
        return 0 if answer in ('y', 'yes') else 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
