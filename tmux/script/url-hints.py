#!/usr/bin/env python3
# License: MIT
"""
url-hints.py - alacritty/kitty style URL hinting for tmux.

Renders the visible content of a tmux pane inside a display-popup, replacing the
first character(s) of every URL with a highlighted hint label (lowercase letters
first). Pressing a label opens that URL with xdg-open.

Usage:
    url-hints.py [--pane PANE_ID] [--program CMD] [--print-only]

    --pane        target pane (default: $TMUX_PANE)
    --program     opener command (default: xdg-open)
    --print-only  render and exit, do not wait for a key (debugging/tests)

Bind it in tmux.conf:
    bind u run-shell "tmux display-popup -E -T ' url hints ' \
        -w '#{pane_width}' -h '#{pane_height}' \
        -x '#{pane_left}' -y '#{pane_top}' \
        '~/.tmux/script/url-hints.py --pane #{pane_id}'"

Why a popup: tmux has no way to draw over an existing pane, so the popup shows a
snapshot of the pane with the labels burnt into it. Labels overwrite the leading
characters of each URL instead of being inserted, so the layout stays identical
to what is on screen.

Known limits: URLs wrapped over two lines are not detected (each screen line is
searched on its own), and only the visible area is considered, not scrollback.
"""

from __future__ import annotations

import itertools
import os
import re
import select
import shutil
import subprocess
import sys
import termios
import tty
import unicodedata

ESC = '\x1b'
# A URL is only what the opener can actually deal with, without the trailing
# punctuation that usually follows a link in prose or in a log line.
URL_RE = re.compile(r'(?i)(?:https?|ftps?|sftp|ssh|git|file)://[^\s<>"\'`\\\x00-\x1f\x7f]{3,}')
TRAILING = '.,;:!?)]}>\'"`*'
LABEL_CHARS = 'abcdefghijklmnopqrstuvwxyz'
SGR_RE = re.compile(r'\x1b\[[0-9;:]*m')
OSC_RE = re.compile(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)')
# Bold black on the terminal's own yellow (ANSI 3/0), so the labels follow the
# colour scheme instead of hard coding hex values. Reverse video looked washed
# out on a dark background.
LABEL_STYLE = '\x1b[0m\x1b[1m\x1b[30;43m'


def cell_width(ch: str) -> int:
    """Display width of one character, enough for label placement."""
    if unicodedata.combining(ch):
        return 0
    if unicodedata.east_asian_width(ch) in ('W', 'F'):
        return 2
    return 1


def labels(count: int):
    """Hint labels, lowercase English letters only.

    All labels have the same length on purpose: with mixed lengths a single
    letter would also be the prefix of a two letter label, so pressing it could
    not be told apart from the start of a longer one. Up to 26 URLs use one
    letter, above that every label is two letters (up to 676 URLs).
    """
    width = 1 if count <= len(LABEL_CHARS) else 2
    for combo in itertools.product(LABEL_CHARS, repeat=width):
        yield ''.join(combo)


def capture(pane: str) -> list[str]:
    out = subprocess.run(
        ['tmux', 'capture-pane', '-p', '-e', '-t', pane],
        capture_output=True, text=True, check=False,
    )
    if out.returncode != 0:
        sys.stderr.write(out.stderr or 'tmux capture-pane failed\n')
        raise SystemExit(1)
    lines = out.stdout.split('\n')
    # Each captured line is newline terminated, so the split leaves one extra
    # empty element; printing it would add a row and scroll the snapshot up by
    # one line, shifting every label.
    if lines and lines[-1] == '':
        lines.pop()
    return lines


class Text:
    """One screen line split into escape tokens and printable characters."""

    __slots__ = ('tokens', 'plain', 'col_of')

    def __init__(self, line: str):
        # tokens: list of (kind, payload) where kind is 'esc' or 'txt'
        self.tokens: list[tuple[str, str]] = []
        plain: list[str] = []
        col_of: list[int] = []  # display column of each plain char index
        col = 0
        i = 0
        while i < len(line):
            ch = line[i]
            if ch == ESC:
                m = SGR_RE.match(line, i) or OSC_RE.match(line, i)
                if m:
                    self.tokens.append(('esc', m.group()))
                    i = m.end()
                    continue
                # Any other escape sequence: drop it, it does not affect color.
                m = re.match(r'\x1b\[[0-9;:?]*[A-Za-z]', line, i)
                i = m.end() if m else i + 1
                continue
            col_of.append(col)
            plain.append(ch)
            col += cell_width(ch)
            self.tokens.append(('txt', ch))
            i += 1
        self.plain = ''.join(plain)
        self.col_of = col_of


def find_urls(lines: list[str]):
    """[(line_index, start_col, end_col, url)] in screen order."""
    found = []
    for idx, line in enumerate(lines):
        text = Text(line)
        for m in URL_RE.finditer(text.plain):
            url = m.group()
            while url and url[-1] in TRAILING:
                url = url[:-1]
            if len(url) < 10:
                continue
            start = m.start()
            end = start + len(url) - 1
            found.append((idx, text.col_of[start], text.col_of[end], url))
    return found


def render(lines: list[str], found, label_of) -> list[str]:
    """Rewrite each line, burning the label into the first cells of each URL."""
    # start_col -> (label, cells_to_consume)
    marks: dict[int, tuple[str, int]] = {}
    for line_idx, col, end_col, url in found:
        label, _cells = label_of[url]
        marks[(line_idx, col)] = label

    out: list[str] = []
    for idx, raw in enumerate(lines):
        text = Text(raw)
        buf: list[str] = []
        col = 0
        sgr = ''          # SGR state to restore after a label
        skipping = 0      # cells still owned by a label
        for kind, payload in text.tokens:
            if kind == 'esc':
                buf.append(payload)
                if SGR_RE.fullmatch(payload):
                    sgr = '' if payload in ('\x1b[0m', '\x1b[m') else sgr + payload
                continue
            ch = payload
            step = cell_width(ch)
            label = marks.get((idx, col))
            if label is not None:
                buf.append(LABEL_STYLE + label + '\x1b[0m' + sgr)
                skipping = len(label)
            if skipping > 0:
                skipping -= step
                col += step
                continue
            buf.append(ch)
            col += step
        out.append(''.join(buf))
    return out


def read_label(is_prefix, is_complete) -> str:
    """Read characters until they name exactly one label; '' on cancel."""
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    buf = ''
    try:
        tty.setraw(fd)
        while True:
            if buf:
                # a multi letter label: do not wait forever for the next key
                ready, _, _ = select.select([fd], [], [], 3.0)
                if not ready:
                    return ''
            ch = os.read(fd, 1).decode('utf-8', 'replace')
            if not ch or ch == ESC or ch in '\r\n' or ch in ('\x03', '\x04'):
                return ''
            if buf == '' and ch in ('q', 'Q'):
                return ''
            buf += ch
            if is_complete(buf):
                return buf
            if not is_prefix(buf):
                return ''
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def main(argv: list[str]) -> int:
    pane = os.environ.get('TMUX_PANE', '')
    program = 'xdg-open'
    print_only = False
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == '--pane' and args:
            pane = args.pop(0)
        elif a == '--program' and args:
            program = args.pop(0)
        elif a == '--print-only':
            print_only = True
        elif a in ('-h', '--help'):
            sys.stdout.write(__doc__ or '')
            return 0
        else:
            sys.stderr.write(f'unknown argument: {a}\n')
            return 2
    if not pane:
        sys.stderr.write('no pane given and $TMUX_PANE is not set\n')
        return 1
    if not shutil.which(program.split()[0]):
        sys.stderr.write(f'opener not found: {program}\n')
        return 1

    lines = capture(pane)
    found = find_urls(lines)

    if not found:
        if print_only:
            sys.stdout.write('url-hints: no URLs in pane ' + pane + '\n')
            return 0
        sys.stdout.write('\x1b[0m\x1b[2J\x1b[H'
                     '\x1b[1m url hints \x1b[0m no URL found in this pane\n'
                     '\x1b[2m press any key to close \x1b[0m')
        sys.stdout.flush()
        read_label(lambda b: True, lambda b: False)
        return 0

    # Assign labels in screen order; identical URLs share one label.
    label_of: dict[str, tuple[str, int]] = {}
    gen = labels(len({url for _i, _c, _e, url in found}))
    for _line_idx, _col, _end_col, url in found:
        if url not in label_of:
            label = next(gen)
            label_of[url] = (label, len(label))

    rendered = render(lines, found, label_of)
    # Use the last line for a help hint when the pane leaves it empty (usual at a
    # shell prompt) - that keeps the snapshot at exactly the pane height.
    if rendered:
        if not Text(rendered[-1]).plain.strip():
            pane_width = max(
                (sum(cell_width(c) for c in Text(l).plain) for l in lines), default=80)
            help_text = ' url hints: press the label at each URL \u00b7 q / Esc cancels '
            rendered[-1] = '\x1b[0m\x1b[2m' + help_text[:pane_width] + '\x1b[0m'
    sys.stdout.write('\x1b[0m\x1b[2J\x1b[H' + '\n'.join(rendered))
    sys.stdout.flush()

    if print_only:
        return 0

    valid = set(label_of.values())
    valid_labels = {label for label, _ in valid}
    ordered = sorted(valid_labels)
    url_for: dict[str, str] = {}
    for _line_idx, _col, _end_col, url in found:
        url_for.setdefault(label_of[url][0], url)

    chosen = read_label(
        lambda b: any(l.startswith(b) for l in ordered),
        lambda b: b in valid_labels,
    )
    if not chosen:
        return 0

    url = url_for[chosen]
    subprocess.Popen(
        program.split() + [url],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, start_new_session=True, cwd=os.path.expanduser('~'),
    )
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        raise SystemExit(0)
