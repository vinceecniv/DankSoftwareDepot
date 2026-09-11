#!/usr/bin/env python3
r"""Checks the shell snippets embedded in the QML for bash-only syntax.

Every `["sh", "-c", …]` in this plugin runs under whatever `/bin/sh` is. On
Fedora and Arch that is bash, which accepts everything; on Debian and Ubuntu
it is dash, which does not — and the way it does not is the problem. A
bashism there is rarely a syntax error dash will refuse. `IFS=$'\t'` parses
perfectly well: dash simply has no ANSI-C quoting, so `$'\t'` is the three
characters `$`, `\` and `t`, and the field separator silently becomes "any of
those". Every Flatpak app id then split at its first `t` — `io.github.…`
listed as `io.gi` with `hub.kolunmi.Bazaar` for a version (#16), on Ubuntu
only, with nothing in any log.

So `dash -n` is no use here: it would have passed. This looks for the
constructs themselves.
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (pattern, what to write instead)
BASHISMS = (
    (r"\$'", "ANSI-C quoting ($'\\t'): use \"$(printf '\\t')\""),
    (r"\[\[", "[[ … ]]: use [ … ]"),
    (r"(?<![<>=!])==", "== inside a test: use ="),
    (r"(?:^|[;|&(]\s*)declare\b", "declare: bash only"),
    (r"(?:^|[;|&(]\s*)function\s+\w+\s*\(", "function keyword: use name() { … }"),
    (r"(?:^|[;|&(]\s*)source\s", "source: use ."),
    (r"&>", "&>: use > … 2>&1"),
    (r"<<<", "here-strings: use printf … | …"),
    (r"\$\{\w+\[", "array subscript: bash only"),
    (r"\becho\s+-e\b", "echo -e: use printf"),
)

DECODER = json.JSONDecoder()
LITERAL = re.compile(r'"(?:[^"\\]|\\.)*"')


def shell_snippets():
    """Every sh -c script in the QML, with where it came from.

    The command is a JSON-shaped array in the QML source, so it is read as
    one rather than pattern-matched: raw_decode stops where the array stops,
    whatever follows it on the line.
    """
    for path in sorted(glob.glob(os.path.join(ROOT, "*.qml"))):
        for number, line in enumerate(open(path, encoding="utf-8"), 1):
            if '"sh"' not in line or '"-c"' not in line:
                continue
            found = False
            for start in (i for i, ch in enumerate(line) if ch == "["):
                try:
                    words, _ = DECODER.raw_decode(line[start:])
                except ValueError:
                    continue
                if (isinstance(words, list) and len(words) >= 3
                        and words[0] == "sh" and words[1] == "-c"):
                    found = True
                    yield os.path.basename(path), number, words[2]
            if found:
                continue
            # Most of these commands are built by concatenation — a URL, a
            # package name — which is not JSON any more. The literal pieces
            # still are, and a bashism would be written in one of those, so
            # the pieces are read instead of giving up on the line.
            for piece in LITERAL.findall(line):
                try:
                    yield os.path.basename(path), number, json.loads(piece)
                except ValueError:
                    continue


def main():
    problems = []
    checked = 0
    for name, number, script in shell_snippets():
        checked += 1
        for pattern, advice in BASHISMS:
            if re.search(pattern, script):
                problems.append("%s:%d: %s" % (name, number, advice))

    for line in problems:
        print("error: " + line)
    print("\n%d shell fragments checked, %d problems" % (checked, len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
