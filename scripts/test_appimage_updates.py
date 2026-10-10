#!/usr/bin/env python3
"""Checks that an AppImage swapped out behind the depot's back is noticed.

A registered AppImage remembers the release tag it was installed from. When
the app's own updater, Gearlever or a manual copy replaces the file, that tag
describes a build that is gone, and comparing it with the latest release
offers an update for a file that already is the latest. These cases decide
what the check believes instead: the file, when it no longer matches what
was recorded.

Run from anywhere:  python3 scripts/test_appimage_updates.py
"""
import os
import sys
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import appimage  # noqa: E402  (reads Gearlever's folder from dconf on import)

failures = []


def check(label, got, want):
    ok = got == want
    print(("ok   " if ok else "FOUT ") + label + ("" if ok else f": {got!r} != {want!r}"))
    if not ok:
        failures.append(label)


T = 1_790_000_000
HOUR = 3600
OLD_SIZE, NEW_SIZE = 13_580_792, 13_658_616


def record(**over):
    r = {"id": "vito", "name": "Vito", "file": "/x", "repo": "o/vito",
         "tag": "v1", "installedAt": T, "sizeBytes": OLD_SIZE}
    r.update(over)
    return r


def release(tag="v2", size=NEW_SIZE, published=T + HOUR):
    return {"tag": tag, "size": size, "published": published, "url": ""}


def stat(size=OLD_SIZE, mtime=T - 5):
    return SimpleNamespace(st_size=size, st_mtime=mtime)


print("Bestand nog zoals geregistreerd")
r = record()
check("oudere tag biedt de nieuwe release aan", appimage.judge_update(r, release(), stat()), (True, False))
r = record(tag="v2")
check("zelfde tag biedt niets aan", appimage.judge_update(r, release(), stat()), (False, False))

print("Bestand van buitenaf vervangen door de nieuwste release")
r = record()
got = appimage.judge_update(r, release(), stat(size=NEW_SIZE, mtime=T + 2 * HOUR))
check("geen update meer aangeboden", got, (False, True))
check("tag volgt de release", r["tag"], "v2")
check("grootte bijgewerkt", r["sizeBytes"], NEW_SIZE)
check("tijdstip is dat van het bestand", r["installedAt"], T + 2 * HOUR)
check("daarna stabiel", appimage.judge_update(r, release(), stat(size=NEW_SIZE, mtime=T + 2 * HOUR)), (False, False))

print("Bestand vervangen door een onbekende build")
r = record()
got = appimage.judge_update(r, release(published=T + 3 * HOUR), stat(size=12_000_000, mtime=T + HOUR))
check("release nieuwer dan het bestand wordt aangeboden", got, (True, True))
check("tag vergeten: die build is weg", r["tag"], "")
r = record()
got = appimage.judge_update(r, release(published=T + HOUR), stat(size=12_000_000, mtime=T + 2 * HOUR))
check("bestand nieuwer dan de release biedt niets aan", got, (False, True))

print("Zelfde grootte, later herschreven")
r = record()
got = appimage.judge_update(r, release(size=99), stat(mtime=T + HOUR))
check("mtime ver na onze eigen schrijfactie telt als vervangen", got[1], True)

print("Niet beheerd")
r = record(managed=False, tag="")
check("datum tegen mtime, record onaangeroerd",
      appimage.judge_update(r, release(published=T + HOUR), stat(mtime=T)), (True, False))

if failures:
    print(f"\n{len(failures)} mislukt")
    sys.exit(1)
print("\nalles ok")
