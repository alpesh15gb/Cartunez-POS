#!/usr/bin/env python3
"""Fail when a tracked text file is not valid UTF-8 or shows mojibake.

Mojibake is UTF-8 text that was decoded as Windows-1252/Latin-1 and saved again,
for example the middle dot (U+00B7) turning into U+00C2 U+00B7, or the rupee sign
into U+00E2 U+201A U+00B9. The markers are built with chr() so this file stays
ASCII and does not trip its own check. Binary files (any NUL byte) and the built
web bundle are skipped.
Usage: python3 scripts/check-encoding.py   (from the repository root)
"""
import re
import subprocess
import sys

SKIP_PREFIXES = ('apps/flutter/release/web/',)
LATIN1_TAIL = '[' + chr(0x80) + '-' + chr(0xBF) + ']'
MOJIBAKE = re.compile('|'.join([
    chr(0xC2) + LATIN1_TAIL,  # A-circumflex + Latin-1 punctuation (middle dot, nbsp, ...)
    chr(0xC3) + LATIN1_TAIL,  # A-tilde + accented-letter tail
    chr(0xE2) + '[' + chr(0x20AC) + chr(0x201A) + chr(0x80) + '-' + chr(0xBF) + ']',  # a-circumflex + euro/low quote: dashes, quotes, rupee
    chr(0xFFFD),              # replacement character: the original bytes are already lost
]))

files = subprocess.run(['git', 'ls-files', '-z'], check=True, capture_output=True).stdout.split(b'\0')
problems = 0
for raw in files:
    if not raw:
        continue
    path = raw.decode('utf-8', 'replace')
    if path.startswith(SKIP_PREFIXES):
        continue
    try:
        with open(raw, 'rb') as handle:
            data = handle.read()
    except (FileNotFoundError, IsADirectoryError):
        continue
    if b'\0' in data:
        continue
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError as error:
        print(f'{path}: not valid UTF-8 (byte {error.start})')
        problems += 1
        continue
    for number, line in enumerate(text.splitlines(), 1):
        match = MOJIBAKE.search(line)
        if match:
            print(f'{path}:{number}: mojibake {match.group()!a}: {line.strip()[:120]!a}')
            problems += 1
if problems:
    sys.exit(f'{problems} encoding problem(s). Re-save the files as UTF-8 and restore the original characters.')
print('Encoding check passed: tracked text files are UTF-8 with no mojibake.')
