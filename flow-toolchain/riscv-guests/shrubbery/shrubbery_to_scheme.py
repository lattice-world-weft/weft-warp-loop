#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 K. S. Ernest (iFire) Lee
#
# A minimal shrubbery-notation-to-s-expression reader: closes ADR 0006's
# "Not started: the shrubbery-style reader" item, scoped to exactly the
# subset needed to write real content (loot/combat/progression-shaped
# reducers) without visible parentheses, per ADR 0006's own decision
# ("script authors write shrubbery notation... no visible parentheses
# even though s7 itself still evaluates a Lisp-1 underneath").
#
# This is NOT full Racket shrubbery (https://docs.racket-lang.org/shrubbery/) -
# that spec is its own substantial grammar (operators, precedence,
# multi-line continuation rules well beyond this). This is an explicit,
# documented SUBSET, matching this project's "restricted IR, explicit
# rejection over silent guessing" discipline already established for
# the RISC-V compiler (ADR 0016): anything outside the subset is a hard
# parse error naming what's unsupported, never a guess.
#
# Grammar (the whole of it):
#   - Indentation is significant (Python's off-side rule): a line ending
#     in ':' opens a block; every following line indented strictly more
#     belongs to it, until a line at the same-or-lesser indent appears.
#   - Comments: '#' to end of line (outside a string literal).
#   - Call syntax: name(a, b, c) -> (name a b c), recursive, comma-split
#     at paren-depth 0 only (so nested calls' commas aren't mistaken for
#     argument separators).
#   - Three block-opening keywords, and only these three:
#       define name(params):  BODY        -> (define (name params...) BODY...)
#       let name(p: v, ...):  BODY        -> (let name ((p v) ...) BODY...)   [named let]
#       let(p: v, ...):       BODY        -> (let ((p v) ...) BODY...)        [plain let]
#       cond:                             -> (cond CLAUSE...)
#         | test: result                  ->   (test result)
#   - Any other line ending in ':' is a hard error - not guessed at.
#   - A term that isn't call syntax (starts with a quote/paren/digit/
#     other) passes through as opaque raw Scheme text, unexamined - this
#     is the escape hatch that keeps this reader small: it only ever
#     needs to understand its own three block forms and call syntax,
#     never quote/list-literal/number syntax, which s7 already parses
#     correctly once handed through unchanged.

import sys


class ShrubberyError(Exception):
    pass


def strip_comment(line):
    # '#' is NOT the comment marker - Scheme literals (#t, #f, #\char,
    # #xFFFFFFFF, #(vector ...)) start with it, and this reader passes
    # non-call terms through as opaque raw Scheme text (see term_to_sexpr),
    # so a '#'-comment would truncate every such literal. '//' avoids the
    # collision entirely.
    out = []
    in_str = False
    i = 0
    while i < len(line):
        c = line[i]
        if c == '"':
            in_str = not in_str
            out.append(c)
        elif c == '/' and i + 1 < len(line) and line[i + 1] == '/' and not in_str:
            break
        else:
            out.append(c)
        i += 1
    return ''.join(out)


def indent_of(line):
    return len(line) - len(line.lstrip(' '))


def parse_lines(text):
    """Turn raw text into a list of (indent, content) for non-blank lines."""
    result = []
    for raw in text.split('\n'):
        line = strip_comment(raw).rstrip()
        if line.strip() == '':
            continue
        if '\t' in line[:indent_of(line)]:
            raise ShrubberyError(f"tabs not allowed in indentation: {raw!r}")
        result.append((indent_of(line), line.strip()))
    return result


def build_block_tree(lines, start, min_indent):
    """Consume sibling lines at exactly the first indent seen (>= min_indent),
    each optionally followed by a nested block of more-indented lines.
    Returns (list of (header_text, child_block_or_None), next_index)."""
    if start >= len(lines):
        return [], start
    indent = lines[start][0]
    if indent < min_indent:
        return [], start
    siblings = []
    i = start
    while i < len(lines) and lines[i][0] == indent:
        header = lines[i][1]
        i += 1
        child = None
        if i < len(lines) and lines[i][0] > indent:
            child, i = build_block_tree(lines, i, indent + 1)
        siblings.append((header, child))
    return siblings, i


def split_args(s):
    """Split a comma-separated argument list at paren-depth 0, honoring
    string literals so commas inside strings aren't split points."""
    args, depth, cur, in_str = [], 0, '', False
    for c in s:
        if c == '"':
            in_str = not in_str
            cur += c
        elif in_str:
            cur += c
        elif c in '([':
            depth += 1
            cur += c
        elif c in ')]':
            depth -= 1
            cur += c
        elif c == ',' and depth == 0:
            args.append(cur.strip())
            cur = ''
        else:
            cur += c
    if cur.strip():
        args.append(cur.strip())
    return args


def split_first_colon_at_depth_0(s):
    """'else: let*(entry: car(table)): ...' must split at the FIRST ':'
    only when paren-depth is 0 - naive str.partition(':') would instead
    split inside let*'s own binding-list colons. Returns (before, after)
    or (s, None) if no depth-0 colon exists."""
    depth, in_str = 0, False
    for i, c in enumerate(s):
        if c == '"':
            in_str = not in_str
        elif in_str:
            continue
        elif c in '([':
            depth += 1
        elif c in ')]':
            depth -= 1
        elif c == ':' and depth == 0:
            return s[:i], s[i + 1:]
    return s, None


def parse_call(text):
    """name(a, b, c) -> ('name', ['a','b','c']) or None if not call syntax."""
    text = text.strip()
    if not text or text[0] == '"' or text[0] == "'":
        return None
    depth, name_end = 0, None
    for i, c in enumerate(text):
        if c == '(' and depth == 0:
            name_end = i
            break
        if c in '([':
            depth += 1
        elif c in ')]':
            depth -= 1
        elif c in ' \t':
            return None  # a bare identifier/atom with no '(' before whitespace
    if name_end is None or not text.endswith(')'):
        return None
    name = text[:name_end].strip()
    if not name or not (name[0].isalpha() or name[0] in '+-*/<>=!?_'):
        return None
    inner = text[name_end + 1:-1]
    return name, split_args(inner)


def term_to_sexpr(text):
    """A single expression term: call syntax expands recursively, anything
    else passes through as opaque raw Scheme text (numbers, quoted forms,
    literal lists, bare identifiers)."""
    text = text.strip()
    call = parse_call(text)
    if call is None:
        return text
    name, args = call
    parts = [term_to_sexpr(a) for a in args]
    return '(' + ' '.join([name] + parts) + ')'


def parse_binding_list(inner):
    """'p1: v1, p2: v2' -> [('p1', sexpr(v1)), ('p2', sexpr(v2))]"""
    bindings = []
    for part in split_args(inner):
        if ':' not in part:
            raise ShrubberyError(f"expected 'name: value' in binding list, got: {part!r}")
        name, _, val = part.partition(':')
        bindings.append((name.strip(), term_to_sexpr(val.strip())))
    return bindings


def block_to_body(block):
    """A block's children, each either a plain expression line (no colon
    header handling needed) or a nested special form - concatenated as a
    Scheme multi-expression body (define/let bodies are already
    implicitly sequenced by Scheme, no explicit begin needed)."""
    return [line_to_sexpr(header, child) for header, child in block]


_BLOCK_KEYWORDS = ('define ', 'let ', 'let(', 'let*(', 'cond')


def line_to_sexpr(header, child):
    if header.endswith(':'):
        header = header[:-1].strip()
        return block_header_to_sexpr(header, child)
    if child is not None:
        raise ShrubberyError(f"line has an indented block but no trailing ':': {header!r}")
    # A line starting with a block keyword but with no trailing ':' is
    # almost always a mistake (an inline single-line body, e.g.
    # 'define f(): body' on one line, is NOT supported - the body must
    # be on its own indented line) rather than a deliberate opaque term -
    # fail loudly here instead of silently passing it through as raw
    # text, which produced confusing downstream errors the first time
    # this happened.
    if header.startswith(_BLOCK_KEYWORDS) or header == 'cond':
        raise ShrubberyError(
            f"line looks like a block header (starts with a reserved keyword) but has no "
            f"trailing ':' - inline single-line bodies are not supported, the body must be "
            f"on its own indented line: {header!r}")
    return term_to_sexpr(header)


def block_header_to_sexpr(header, child):
    if child is None:
        raise ShrubberyError(f"block header with no indented body: {header!r}:")

    if header.startswith('define '):
        call = parse_call(header[len('define '):])
        if call is None:
            raise ShrubberyError(f"expected 'define name(params):', got: {header!r}")
        name, params = call
        body = block_to_body(child)
        return f"(define ({name} {' '.join(params)}) {' '.join(body)})"

    if header.startswith('let '):
        rest = header[len('let '):].strip()
        call = parse_call(rest)
        if call is None:
            raise ShrubberyError(f"expected 'let name(p: v, ...):' or 'let(p: v, ...):', got: {header!r}")
        name, args = call
        bindings = parse_binding_list(','.join(args)) if args else []
        binding_sexpr = '(' + ' '.join(f'({n} {v})' for n, v in bindings) + ')'
        body = block_to_body(child)
        return f"(let {name} {binding_sexpr} {' '.join(body)})"

    if header == 'let' or header == 'let*':
        raise ShrubberyError(f"'{header}:' with no parenthesized binding list is not supported")

    if header.startswith('let(') or header.startswith('let*('):
        keyword = 'let*' if header.startswith('let*(') else 'let'
        call = parse_call(header)
        _, args = call
        bindings = parse_binding_list(','.join(args)) if args else []
        binding_sexpr = '(' + ' '.join(f'({n} {v})' for n, v in bindings) + ')'
        body = block_to_body(child)
        return f"({keyword} {binding_sexpr} {' '.join(body)})"

    if header == 'cond':
        clauses = []
        for line, sub in child:
            if not line.startswith('|'):
                raise ShrubberyError(f"expected '| test: result' inside cond:, got: {line!r}")
            clause_line = line[1:].strip()
            test, result = split_first_colon_at_depth_0(clause_line)
            if result is None:
                raise ShrubberyError(f"expected '| test: result', got: {line!r}")
            test_sexpr = term_to_sexpr(test.strip())
            # The result itself may open its own nested block (e.g.
            # '| else: let*(...):' with the let*'s body as `sub`) -
            # recurse through the same header dispatch used everywhere
            # else, rather than treating `sub` as a generic body and
            # silently discarding what `result` said to do with it.
            result_body = line_to_sexpr(result.strip(), sub)
            clauses.append(f'({test_sexpr} {result_body})')
        return '(cond ' + ' '.join(clauses) + ')'

    raise ShrubberyError(
        f"unsupported block header (only 'define name(...):', 'let ...:', "
        f"and 'cond:' open a block): {header!r}:")


def shrubbery_to_scheme(text):
    lines = parse_lines(text)
    tree, end = build_block_tree(lines, 0, 0)
    if end != len(lines):
        raise ShrubberyError(f"unexpected indentation at line: {lines[end]!r}")
    forms = [line_to_sexpr(header, child) for header, child in tree]
    return '\n'.join(forms) + '\n'


def main():
    if len(sys.argv) != 2:
        print("usage: shrubbery_to_scheme.py <file.shrub>", file=sys.stderr)
        sys.exit(2)
    with open(sys.argv[1], 'r') as f:
        text = f.read()
    try:
        sys.stdout.write(shrubbery_to_scheme(text))
    except ShrubberyError as e:
        print(f"shrubbery parse error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
