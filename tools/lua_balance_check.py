"""Word-level Lua 5.1 block balance check.

Not a parser. It strips comments and string literals, then verifies that
`do` / `if` / `function` / `repeat` are closed by `end` / `until`.
`for` and `while` are NOT counted as openers: their `do` already counts.
Run against a known-good file first as a control.
"""
import re
import sys


def strip_lua(src: str) -> str:
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        # long bracket comment  --[[ ... ]]  /  --[==[ ... ]==]
        if src.startswith('--', i):
            m = re.match(r'--\[(=*)\[', src[i:])
            if m:
                eq = m.group(1)
                close = ']' + eq + ']'
                j = src.find(close, i + len(m.group(0)))
                i = n if j < 0 else j + len(close)
                out.append(' ')
                continue
            j = src.find('\n', i)
            i = n if j < 0 else j
            continue
        # long bracket string [[ ... ]] / [==[ ... ]==]
        m = re.match(r'\[(=*)\[', src[i:])
        if m:
            eq = m.group(1)
            close = ']' + eq + ']'
            j = src.find(close, i + len(m.group(0)))
            i = n if j < 0 else j + len(close)
            out.append(' ')
            continue
        if c in '"\'':
            q = c
            i += 1
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                if src[i] == q:
                    i += 1
                    break
                if src[i] == '\n':
                    break
                i += 1
            out.append(' ')
            continue
        out.append(c)
        i += 1
    return ''.join(out)


OPEN = {'do', 'if', 'function', 'repeat'}
CLOSE = {'end', 'until'}

for path in sys.argv[1:]:
    src = open(path, encoding='utf-8').read()
    code = strip_lua(src)
    words = re.findall(r'[A-Za-z_]\w*', code)
    depth = 0
    min_depth = 0
    opens = closes = 0
    for w in words:
        if w in OPEN:
            depth += 1
            opens += 1
        elif w in CLOSE:
            depth -= 1
            closes += 1
            min_depth = min(min_depth, depth)
    print(f'{path}')
    print(f'  opens={opens}  closes={closes}  final_depth={depth}  min_depth={min_depth}')
    print('  ' + ('OK (balanced)' if depth == 0 and min_depth >= 0 else 'PROBLEM'))
