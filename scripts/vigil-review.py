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
import os
import re
import stat
import subprocess
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
# Trojan-source attack primitives.
BIDI_MARKS = re.compile(r'[\u202a-\u202e\u2066-\u2069\u061c\u180e]')
ZERO_WIDTH = re.compile(r'[\u200b-\u200d\ufeff\u2060]')
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
    return env


def _git(args, cwd=None, input_text=None):
    return subprocess.run(
        ['git', *args],
        cwd=cwd,
        input=input_text,
        capture_output=True,
        text=True,
        env=_git_env(),
    )


def rev_list(range_expr: str, cwd: str):
    r = _git(['rev-list', '--reverse', range_expr], cwd=cwd)
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
    log_dir = os.environ.get('VIGIL_LOG_DIR') or os.path.expanduser('~/vigil-logs')
    path = Path(log_dir) / f'session-{session_id}.txt'
    if path.is_file():
        return f'Transcript: {path}'
    return f'Transcript: transcript not on this host (session {session_id})'


def self_check():
    problems = []
    git_probe = subprocess.run(
        ['git', '--version'], capture_output=True, text=True
    )
    if git_probe.returncode != 0:
        problems.append('git not on PATH')
    if sys.version_info < (3, 8):
        problems.append(f'python3 too old: {sys.version_info[0]}.{sys.version_info[1]}')
    try:
        st = Path(__file__).resolve().stat()
    except OSError as e:
        problems.append(f'cannot stat script: {e}')
    else:
        if st.st_uid != os.getuid():
            problems.append('script not owned by current user')
        if st.st_mode & stat.S_IWOTH:
            problems.append('script is world-writable')
    return problems


def _prompt_line(prompt: str) -> str:
    sys.stderr.write(prompt)
    sys.stderr.flush()
    # Prefer /dev/tty so the prompt works when stdin is occupied (e.g., the
    # pre-push hook feeds ref data on stdin). Fall back to stdin for
    # detached/test sessions where /dev/tty is unavailable.
    try:
        with open('/dev/tty', 'r') as tty:
            return tty.readline()
    except OSError:
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
        'rev_range',
        nargs='?',
        default='@{u}..HEAD',
        help='git rev-range to review (default: @{u}..HEAD)',
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

    shas, err = rev_list(args.rev_range, cwd)
    if shas is None:
        sys.stderr.write(
            f'vigil-review: could not resolve range {args.rev_range!r}: {err}\n'
        )
        return 1
    if not shas:
        sys.stdout.write(f'No commits in range {args.rev_range}.\n')
        return 0

    interactive = not (args.prompt or args.from_hook)
    for sha in shas:
        if _render_commit(sha, cwd, interactive) == 'quit':
            break

    if args.prompt:
        answer = _prompt_line('Proceed? [y/N] ').strip().lower()
        return 0 if answer in ('y', 'yes') else 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
