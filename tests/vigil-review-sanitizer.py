#!/usr/bin/env python3
"""Unit tests for the vigil-review sanitizer.

The sanitizer is the load-bearing security primitive of vigil-review. These
tests exercise an adversarial corpus (ANSI clear-screen, OSC title injection,
DCS, BIDI overrides, zero-width chars, C1 controls, raw ESC, overlong lines,
stray C0 bytes) and assert the sanitizer's output contains no interpretable
escape sequences and is idempotent.
"""
import importlib.util
import sys
from pathlib import Path


REPO_DIR = Path(__file__).resolve().parent.parent
SCRIPT = REPO_DIR / 'scripts' / 'vigil-review.py'

_spec = importlib.util.spec_from_file_location('vigil_review', SCRIPT)
_mod = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(_mod)
sanitize = _mod.sanitize
MAX_LINE = _mod.MAX_LINE
WRAP_MARK = _mod.WRAP_MARK


failed = 0


def section(title: str) -> None:
    print(f'\n-- {title} --')


def check(name: str, cond: bool, detail: str = '') -> None:
    global failed
    if cond:
        print(f'  PASS  {name}')
    else:
        print(f'  FAIL  {name} {detail}', file=sys.stderr)
        failed += 1


# Adversarial corpus: each entry is a known terminal-attack primitive.
CORPUS = {
    'ansi-clear-screen':  '\x1b[2J\x1b[Hgotcha',
    'ansi-sgr-red':       '\x1b[31mred\x1b[0m',
    'ansi-cursor-move':   '\x1b[10;20Hhidden',
    'osc-set-title':      '\x1b]0;pwned\x07normal',
    'dcs-sequence':       '\x1bP1;2|data\x1b\\after',
    'c1-csi-introducer':  '\x9b31mred',
    'bidi-trojan':        'access != "user\u202e \u2066# admin\u2069 \u2066":\n',
    'zero-width':         'ad\u200bmin',
    'bell':               'alert\x07\x07',
    'form-feed':          'page\x0cbreak',
    'vertical-tab':       'va\x0bb',
    'overlong-line':      'x' * 1300,
    'null-byte':          'before\x00after',
    'raw-esc':            'pre\x1bpost',
    'carriage-return':    'overwrite\rline',
}


section('No ESC byte in sanitized output (any attack class)')
for name, raw in CORPUS.items():
    out = sanitize(raw)
    check(
        f'{name}: no ESC (0x1b) survives',
        '\x1b' not in out,
        f'(got {out!r})',
    )


section('No interpretable C0 control bytes in output')
for name, raw in CORPUS.items():
    out = sanitize(raw)
    bad = [b for b in ('\x07', '\x0b', '\x0c', '\r') if b in out]
    check(
        f'{name}: no BEL/VT/FF/CR remains',
        not bad,
        f'(found {bad!r} in {out!r})',
    )


section('BIDI overrides dropped')
bidi_cps = '\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069\u061c\u180e'
for cp in bidi_cps:
    out = sanitize(f'a{cp}b')
    check(
        f'U+{ord(cp):04X} dropped',
        cp not in out,
        f'(got {out!r})',
    )


section('Zero-width / invisible Unicode dropped')
for cp in '\u200b\u200c\u200d\ufeff\u2060':
    out = sanitize(f'a{cp}b')
    check(
        f'U+{ord(cp):04X} dropped',
        cp not in out,
        f'(got {out!r})',
    )


section('C1 controls (U+0080-U+009F) dropped')
for cp in '\u0080\u0090\u009b\u009f':
    out = sanitize(f'a{cp}b')
    check(
        f'U+{ord(cp):04X} dropped',
        cp not in out,
        f'(got {out!r})',
    )


section('C0 controls escaped visibly (not silently dropped)')
for byte, hexrep in [('\x00', '00'), ('\x1b', '1b'), ('\x01', '01'), ('\x07', '07')]:
    out = sanitize(f'before{byte}after')
    marker = f'\u23a1{hexrep}\u23a4'
    check(
        f'0x{hexrep}: visible escape marker present',
        marker in out,
        f'(got {out!r})',
    )


section('Tab and newline preserved')
check('tab preserved', '\t' in sanitize('a\tb'))
check('newline preserved', sanitize('a\nb').count('\n') == 1)


section('Overlong lines wrapped at MAX_LINE with marker')
out = sanitize('x' * 1300)
check('wrap marker present', WRAP_MARK in out)
for line in out.split('\n'):
    check(
        f'line ≤ {MAX_LINE} chars',
        len(line) <= MAX_LINE,
        f'(line len={len(line)})',
    )


section('Idempotence: sanitize(sanitize(x)) == sanitize(x)')
for name, raw in CORPUS.items():
    once = sanitize(raw)
    twice = sanitize(once)
    check(
        f'{name}: idempotent',
        once == twice,
        f'\n    once:  {once!r}\n    twice: {twice!r}',
    )


# A specific overlong-line idempotence stress: a wrapped line whose final
# character is the wrap marker must not be re-wrapped.
section('Wrapped lines are stable on re-sanitize')
edge = 'y' * (MAX_LINE - 1) + WRAP_MARK
check('exact MAX_LINE-length wrapped line unchanged', sanitize(edge) == edge)


sys.exit(1 if failed else 0)
