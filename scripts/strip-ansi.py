#!/usr/bin/env python3
"""Strip ANSI escape sequences and terminal control codes from a script(1)
log, producing a readable plain-text transcript.

Usage: strip-ansi.py <input-log> <output-txt>

Designed for logs produced by `script(1)` capturing a Claude Code TUI
session. The output preserves conversation content while removing the
cursor-positioning, color, and OSC sequences that make raw script logs
unreadable in `less` or `cat`.
"""
import re
import sys


# CSI sequences: ESC [ params final-byte
ANSI_CSI = re.compile(r'\x1b\[[0-9;:?<>!= ]*[@A-Za-z`~^_\\|]')
# OSC sequences: ESC ] ... ST   (ST = BEL or ESC \)
ANSI_OSC = re.compile(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)')
# DCS / APC / PM / SOS sequences: ESC P|_|^|X ... ST
ANSI_DCS = re.compile(r'\x1b[P_^X][^\x1b]*\x1b\\')
# Single ESC + intro byte (charset selection, etc.)
ANSI_2BYTE = re.compile(r'\x1b[\(\)*+#@=>][a-zA-Z0-9]?')
# Bare ESC + final-byte short sequences
ANSI_SHORT = re.compile(r'\x1b[78cDEHMNOZ\\]')
# Bell, vertical tab, form feed
NOISE_CHARS = re.compile(r'[\x07\x0b\x0c]')
# Collapse runs of >2 newlines (terminal redraws produce many blank lines)
EXCESS_BLANK_LINES = re.compile(r'\n{3,}')


def strip(text: str) -> str:
    text = ANSI_OSC.sub('', text)
    text = ANSI_DCS.sub('', text)
    text = ANSI_CSI.sub('', text)
    text = ANSI_2BYTE.sub('', text)
    text = ANSI_SHORT.sub('', text)
    text = NOISE_CHARS.sub('', text)
    # Carriage returns from terminal line redraws — drop entirely
    text = text.replace('\r', '')
    text = EXCESS_BLANK_LINES.sub('\n\n', text)
    return text


def main(argv):
    if len(argv) != 3:
        print(f"usage: {argv[0]} <input-log> <output-txt>", file=sys.stderr)
        return 2

    src, dst = argv[1], argv[2]

    with open(src, 'rb') as f:
        raw = f.read()

    text = raw.decode('utf-8', errors='replace')
    cleaned = strip(text)

    with open(dst, 'w') as f:
        f.write(cleaned)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
