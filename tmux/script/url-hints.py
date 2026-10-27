#!/usr/bin/env python3
# License: MIT
"""
url-hints.py - alacritty/kitty style URL hinting for tmux.

Renders the visible content of a tmux pane inside a display-popup, replacing the
first character(s) of every URL with a highlighted hint label (lowercase letters
first). Pressing a label opens that URL with xdg-open.

Usage:
    url-hints.py [--pane PANE_ID] [--program CMD] [--gutter N] [--indent N]
                 [--print-only] [--list-only]

    --pane        target pane (default: $TMUX_PANE)
    --program     opener command (default: xdg-open)
    --print-only  render the hinted screen to stdout and exit (tests/debugging)
    --list-only   print "label<TAB>url" for what would be hinted, then exit
    --gutter      how many columns short of the pane edge a line may stop and
                  still count as wrapped by the program itself (default: 8)
    --indent      how many leading spaces a continued row may have (the left
                  gutter of a TUI that indents wrapped text, default: 8)

Bind it in tmux.conf:
    bind u run-shell "tmux display-popup -E -b none \
        -w '#{pane_width}' -h '#{pane_height}' \
        -x '#{pane_left}' -y '#{pane_top}' \
        '~/.tmux/script/url-hints.py --pane #{pane_id}'"

Why a popup: tmux has no way to draw over an existing pane, so the popup shows a
snapshot of the pane with the labels burnt into it. Labels overwrite the leading
characters of each URL instead of being inserted, so the layout stays identical
to what is on screen.

Wrapped URLs come in two flavours and both are opened whole:

* the terminal wrapped the line, so the line is exactly `pane_width` cells wide
  (`capture-pane` strips trailing spaces) and the next row is its continuation;
  those rows are fused into one logical line before matching;
* the program wrapped it itself (a TUI with a gutter, `fold`, a pager), so the
  line stops short of the pane edge. That one is recognised per match: the URL
  runs right up to the end of a nearly full line and the next row continues
  with URL characters, possibly after the program's own left gutter of at most
  --indent spaces (default 8) - that is how a TUI indents wrapped text. How much
  short of the pane edge still counts as full is --gutter (default 8 columns).

Either way the fusion happens on cell positions, so labels keep landing on the
right screen cell - even a two letter label that has to straddle a wrap point.

Two more subtleties, both of which used to truncate URLs and are now handled:

* a coloured line keeps its trailing spaces in the capture (the escape that
  recolours what follows sits behind them), so "the URL ends at the row end"
  must tolerate trailing blank cells, not just the literal last cell;
* a program that emits OSC 8 hyperlinks re-emits the link on every wrapped row
  and its escape carries the complete URL, so when a visible URL fragment sits
  inside a hyperlink, that URI wins over any heuristic continuation.

Known limits: only the visible area is searched, not the scrollback, so a URL
whose beginning has scrolled off the top cannot be recognised; a URL that runs
into the bottom edge of the screen is skipped (it is truncated, so opening it
would open a broken link); a URL broken by a blank padded cell (wide character
at the pane edge) is not fused.
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
# Characters that can legally continue a URL across a line break. Anything else
# (a space, a quote, ...) means the next line starts something new.
URL_TAIL_CHARS = frozenset(
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    '-._~:/?#[]@!$&()*+,;=%')
LABEL_CHARS = 'abcdefghijklmnopqrstuvwxyz'
SGR_RE = re.compile(r'\x1b\[[0-9;:]*m')
OSC_RE = re.compile(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)')
# OSC 8 hyperlinks: \x1b]8;params;URI ST  (empty URI closes the link). A program
# that wraps its own output re-emits the link on every wrapped row, and the URI
# in the escape sequence is always the complete URL - even when the visible
# text is only a wrapped fragment of it.
OSC8_RE = re.compile(r'\x1b\]8;([^;\x07\x1b]*);([^\x07\x1b]*)(?:\x07|\x1b\\)')
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


def tmux(*args: str) -> str:
    out = subprocess.run(['tmux', *args], capture_output=True, text=True, check=False)
    if out.returncode != 0:
        sys.stderr.write(out.stderr or 'tmux command failed: ' + ' '.join(args) + '\n')
        raise SystemExit(1)
    return out.stdout


def pane_width(pane: str) -> int:
    try:
        return int(tmux('display-message', '-p', '-t', pane, '#{pane_width}').strip())
    except ValueError:
        sys.stderr.write('could not read the pane width\n')
        raise SystemExit(1)


def capture(pane: str) -> list[str]:
    lines = tmux('capture-pane', '-p', '-e', '-t', pane).split('\n')
    # Each captured line is newline terminated, so the split leaves one extra
    # empty element; printing it would add a row and scroll the snapshot up by
    # one line, shifting every label.
    if lines and lines[-1] == '':
        lines.pop()
    return lines


class Text:
    """One screen line split into escape tokens and printable characters."""

    __slots__ = ('tokens', 'plain', 'hyperlinks')

    def __init__(self, line: str):
        # tokens: list of (kind, payload) where kind is 'esc' or 'txt'
        self.tokens: list[tuple[str, str]] = []
        plain: list[str] = []
        # hyperlink label spans as (start, end) indices into plain
        self.hyperlinks: list[tuple[int, int, str]] = []
        hl_start, hl_url = -1, ''
        i = 0
        while i < len(line):
            ch = line[i]
            if ch == ESC:
                m = OSC8_RE.match(line, i)
                if m:
                    _params, uri = m.group(1), m.group(2)
                    if uri:
                        hl_start, hl_url = len(plain), uri
                    else:
                        if hl_start >= 0 and hl_url:
                            self.hyperlinks.append((hl_start, len(plain), hl_url))
                        hl_start, hl_url = -1, ''
                    self.tokens.append(('esc', m.group()))
                    i = m.end()
                    continue
                m = SGR_RE.match(line, i) or OSC_RE.match(line, i)
                if m:
                    self.tokens.append(('esc', m.group()))
                    i = m.end()
                    continue
                # Any other escape sequence: drop it, it does not affect color.
                m = re.match(r'\x1b\[[0-9;:?]*[A-Za-z]', line, i)
                i = m.end() if m else i + 1
                continue
            plain.append(ch)
            self.tokens.append(('txt', ch))
            i += 1
        if hl_start >= 0 and hl_url:  # link never closed on this line
            self.hyperlinks.append((hl_start, len(plain), hl_url))
        self.plain = ''.join(plain)


def build_logical(lines: list[str], width: int):
    """Fuse screen lines that tmux itself soft wrapped.

    Returns a list of lines, each a list of (screen_line, column, char) in
    reading order, so every match can be mapped back to a screen cell.

    This only covers wrapping done by the terminal (a full width line). Text
    wrapped by the program itself - a TUI with a gutter, `fold`, a pager - stops
    short of the pane edge and is handled per match in continue_url().
    """
    logical: list[list[tuple[int, int, str]]] = []
    current: list[tuple[int, int, str]] = []
    for idx, raw in enumerate(lines):
        col = 0
        for ch in Text(raw).plain:
            current.append((idx, col, ch))
            col += cell_width(ch)
        if col < width:
            # The line stops before the pane edge, so it ended with a real
            # newline rather than a wrap.
            logical.append(current)
            current = []
    if current:
        logical.append(tuple(current))  # type: ignore[arg-type]
    return logical


def is_urlish(ch: str) -> bool:
    """Can this character continue a URL fragment on a wrapped row?

    ASCII: only the legal URL characters. Non-ASCII: allowed (IRIs such as
    https://例子.com/测试) unless it is punctuation or a symbol - that keeps
    a TUI's box drawing gutter (│ is category So) from being swallowed.
    """
    if ch in URL_TAIL_CHARS:
        return True
    return ord(ch) >= 0x80 and unicodedata.category(ch)[0] not in ('P', 'S', 'Z')


def continue_url(url: str, lines: list[str], widths: list[int], width: int,
                 gutter: int, indent: int, line_idx: int) -> str:
    """Extend a URL that the running program wrapped onto the next row.

    A program wrapping text itself (a TUI with a gutter, `fold`, a pager) stops
    short of the pane edge, so the width test used for terminal wrapping cannot
    see it. What does give it away: the URL runs right up to the end of a line
    that leaves no room to spare, and the next row continues flush with
    characters that can be part of a URL (after the program's own left gutter of
    at most `indent` spaces, which is how e.g. a TUI indents wrapped text).
    """
    while line_idx + 1 < len(lines):
        # Only keep going while the row we are leaving was itself filled up:
        # otherwise the URL simply ended there and the next row is new text.
        if widths[line_idx] <= width - gutter:
            break
        nxt = Text(lines[line_idx + 1]).plain
        body = nxt.lstrip(' ')
        if not body or len(nxt) - len(body) > indent:
            break
        tail = []
        for ch in body:
            if ch.isspace() or not is_urlish(ch):
                break
            tail.append(ch)
        if not tail:
            break
        url += ''.join(tail)
        line_idx += 1
    while url and url[-1] in TRAILING:
        url = url[:-1]
    return url


def find_urls(logical, lines: list[str], width: int, last_line: int,
              gutter: int, indent: int):
    """[(cells, start_index, url)] for the whole visible screen."""
    texts = [Text(line) for line in lines]
    widths = [sum(cell_width(ch) for ch in t.plain) for t in texts]
    found = []
    for cells in logical:
        # offset of each screen line's plain text inside the logical line,
        # to map a match back into the per line hyperlink spans
        offsets: dict[int, int] = {}
        seg_start, prev_line = 0, cells[0][0] if cells else -1
        for pos, (ln, _c, _ch) in enumerate(cells):
            if ln != prev_line:
                offsets[prev_line] = seg_start
                seg_start, prev_line = pos, ln
        if cells:
            offsets[cells[-1][0]] = seg_start

        text = ''.join(ch for _l, _c, ch in cells)
        for m in URL_RE.finditer(text):
            url = m.group()
            while url and url[-1] in TRAILING:
                url = url[:-1]
            if len(url) < 10:
                continue
            start = m.start()
            end = start + len(url) - 1
            end_line, end_col, end_ch = cells[end]

            # If the visible URL fragment sits inside an OSC 8 hyperlink, the
            # link's URI is the complete URL by construction (a program that
            # wraps its own output re-emits the link on each wrapped row), so
            # prefer it over any heuristic continuation below.
            start_line = cells[start][0]
            idx_in_line = start - offsets[start_line]
            for hs, he, hu in texts[start_line].hyperlinks:
                if hs <= idx_in_line < he and hu.lower().startswith((
                        'http://', 'https://', 'ftp://', 'ftps://',
                        'file://', 'git://', 'ssh://', 'sftp://')):
                    found.append((cells, start, hu))
                    break
            else:
                # "At the end of the row" tolerates trailing padding: a
                # coloured line keeps its trailing spaces in the capture
                # (the escape that recolours what follows sits behind them),
                # so the URL is followed by blank cells, not by the line end.
                at_line_end = all(ch.isspace() for ch in text[end + 1:])
                near_full = widths[end_line] > width - gutter
                if at_line_end and near_full:
                    if end_line == last_line:
                        # The rest of the URL is below the visible area: it
                        # would open truncated, so do not offer it at all.
                        continue
                    url = continue_url(url, lines, widths, width, gutter, indent, end_line)
                elif end_line == last_line and end_col + cell_width(end_ch) >= width:
                    # Cut off by the bottom right corner of the screen.
                    continue
                found.append((cells, start, url))
    return found


def layout(found, label_of) -> dict[tuple[int, int], str]:
    """Map screen cells to label glyphs; a label may straddle a wrap point."""
    replacement: dict[tuple[int, int], str] = {}
    for cells, start, url in found:
        for offset, glyph in enumerate(label_of[url]):
            pos = start + offset
            if pos >= len(cells):
                break
            line, col, _ch = cells[pos]
            replacement[(line, col)] = glyph
    return replacement


def render(lines: list[str], replacement: dict[tuple[int, int], str]) -> list[str]:
    out: list[str] = []
    for idx, raw in enumerate(lines):
        buf: list[str] = []
        col = 0
        sgr = ''  # SGR state to restore after a label
        for kind, payload in Text(raw).tokens:
            if kind == 'esc':
                buf.append(payload)
                if SGR_RE.fullmatch(payload):
                    sgr = '' if payload in ('\x1b[0m', '\x1b[m') else sgr + payload
                continue
            ch = payload
            step = cell_width(ch)
            glyph = replacement.get((idx, col))
            if glyph is not None:
                # A label glyph covers one cell; fill the rest of a wide cell so
                # the remainder of the line does not shift left.
                buf.append(LABEL_STYLE + glyph + '\x1b[0m' + sgr + ' ' * (step - 1))
            else:
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
    gutter = 8
    indent = 8
    print_only = list_only = False
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == '--pane' and args:
            pane = args.pop(0)
        elif a == '--program' and args:
            program = args.pop(0)
        elif a == '--gutter' and args:
            gutter = max(0, int(args.pop(0)))
        elif a == '--indent' and args:
            indent = max(0, int(args.pop(0)))
        elif a == '--print-only':
            print_only = True
        elif a == '--list-only':
            list_only = True
        elif a in ('-h', '--help'):
            sys.stdout.write(__doc__ or '')
            return 0
        else:
            sys.stderr.write(f'unknown argument: {a}\n')
            return 2
    if not pane:
        sys.stderr.write('no pane given and $TMUX_PANE is not set\n')
        return 1

    width = pane_width(pane)
    lines = capture(pane)
    found = find_urls(build_logical(lines, width), lines, width, len(lines) - 1,
                      gutter, indent)

    # Assign labels in screen order; identical URLs share one label.
    label_of: dict[str, str] = {}
    gen = labels(len({url for _c, _s, url in found}))
    for _cells, _start, url in found:
        if url not in label_of:
            label_of[url] = next(gen)

    if list_only:
        for _cells, _start, url in found:
            sys.stdout.write(f'{label_of[url]}\t{url}\n')
        return 0

    if not found:
        if print_only:
            sys.stdout.write(f'url-hints: no URLs in pane {pane}\n')
            return 0
        sys.stdout.write('\x1b[0m\x1b[2J\x1b[H'
                     '\x1b[1m url hints \x1b[0m no URL found in this pane\n'
                     '\x1b[2m press any key to close \x1b[0m')
        sys.stdout.flush()
        read_label(lambda b: True, lambda b: False)
        return 0

    rendered = render(lines, layout(found, label_of))
    # Use the last line for a help hint when the pane leaves it empty (usual at a
    # shell prompt) - that keeps the snapshot at exactly the pane height.
    if rendered and not Text(rendered[-1]).plain.strip():
        help_text = ' url hints: press the label at each URL \u00b7 q / Esc cancels '
        rendered[-1] = '\x1b[0m\x1b[2m' + help_text[:width] + '\x1b[0m'
    sys.stdout.write('\x1b[0m\x1b[2J\x1b[H' + '\n'.join(rendered))
    sys.stdout.flush()

    if print_only:
        return 0

    if not shutil.which(program.split()[0]):
        sys.stderr.write(f'opener not found: {program}\n')
        return 1

    valid_labels = set(label_of.values())
    ordered = sorted(valid_labels)
    url_for = {label_of[url]: url for _c, _s, url in found}

    chosen = read_label(
        lambda b: any(l.startswith(b) for l in ordered),
        lambda b: b in valid_labels,
    )
    if not chosen:
        return 0

    subprocess.Popen(
        program.split() + [url_for[chosen]],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, start_new_session=True, cwd=os.path.expanduser('~'),
    )
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        raise SystemExit(0)
