#!/usr/bin/env python3
"""Check the translation catalogs against the QML that uses them.

Fifteen catalogs drift silently: a string added to the UI reaches only the
language whose file someone remembered, a `%1` gets lost in one translation
and the sentence loses its number, a key survives the code that called it.
None of that shows up until someone reads that language.

Run from anywhere:  python3 scripts/check_translations.py
Exit code 1 when something is wrong, 0 when only notes remain.
"""

import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Keys the app asks for by value rather than by literal: sort options, section
# headings, source labels, the settings dropdown, AppStream category names and
# the plugin's own manifest description.
DYNAMIC_PATTERNS = (
    r"sortOptions: \[(?P<body>.*?)\]",
)
DYNAMIC_LITERALS = {"Off", "Notify only", "Auto-install Flatpaks",
                    # the Copr group heading, translated where rows are drawn
                    "Copr · built by individuals"}
# Storefront categories come from AppStream data, not from the source
CATEGORY_KEYS = {
    "Most popular", "Browsers", "Communication", "Development", "Games",
    "Graphics & Photo", "Media", "Office", "Utilities",
}


def qml_sources():
    return {os.path.basename(p): open(p, encoding="utf-8").read()
            for p in glob.glob(os.path.join(ROOT, "*.qml"))}


def literal_keys(sources):
    keys = set()
    for text in sources.values():
        for raw in re.findall(r'Tr\.t\("((?:[^"\\]|\\.)*)"\)', text):
            keys.add(raw.replace('\\"', '"'))
    return keys


def dynamic_keys(sources):
    keys = set(DYNAMIC_LITERALS) | set(CATEGORY_KEYS)
    joined = "".join(sources.values())
    for pattern in DYNAMIC_PATTERNS:
        for match in re.finditer(pattern, joined, re.S):
            keys |= set(re.findall(r'"([^"]+)"', match.group("body")))
    # "3 · Completed" is sorted by its prefix and shown without it
    keys |= {c[4:] for c in re.findall(r'"(\d · [^"]+)"', joined)}
    keys |= set(re.findall(r'source: "([^"]+)"', joined))
    # plugin.json's description is translated the same way
    manifest = os.path.join(ROOT, "plugin.json")
    if os.path.exists(manifest):
        keys.add(json.load(open(manifest, encoding="utf-8")).get("description", ""))
    return keys


def placeholders(text):
    return sorted(re.findall(r"%\d", text))


def main():
    catalogs = {os.path.basename(p)[:-5]: json.load(open(p, encoding="utf-8"))
                for p in sorted(glob.glob(os.path.join(ROOT, "translations", "*.json")))}
    if not catalogs:
        print("no catalogs found")
        return 1

    sources = qml_sources()
    used = literal_keys(sources)
    dynamic = dynamic_keys(sources)
    reference = catalogs["nl"] if "nl" in catalogs else next(iter(catalogs.values()))

    errors, notes = [], []

    # 1. every catalog carries the same keys
    for lang, catalog in catalogs.items():
        missing = set(reference) - set(catalog)
        extra = set(catalog) - set(reference)
        for key in sorted(missing):
            errors.append(f"[{lang}] missing key: {key!r}")
        for key in sorted(extra):
            errors.append(f"[{lang}] key not in the reference catalog: {key!r}")

    # 2. every string the UI asks for exists
    for key in sorted(used - set(reference)):
        errors.append(f"no catalog has {key!r}, asked for in the QML")

    # 3. a translation keeps the numbers the sentence is built from
    for lang, catalog in catalogs.items():
        for key, value in catalog.items():
            if placeholders(key) != placeholders(value):
                errors.append(f"[{lang}] placeholder mismatch in {key!r} -> {value!r}")
            if value.strip() != value:
                errors.append(f"[{lang}] leading or trailing space in {value!r}"
                              if key.strip() == key else "")
            if key.endswith("…") != value.endswith("…"):
                notes.append(f"[{lang}] ellipsis differs: {key!r} -> {value!r}")

    # 4. keys nothing calls any more
    for key in sorted(set(reference) - used - dynamic):
        notes.append(f"no call site: {key!r}")

    errors = [e for e in errors if e]
    for line in errors:
        print("error: " + line)
    for line in notes:
        print("note:  " + line)
    print(f"\n{len(catalogs)} catalogs, {len(reference)} keys, "
          f"{len(errors)} errors, {len(notes)} notes")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
