#!/usr/bin/env python3
"""Exercise the release notes for packages built from git, offline.

Three things decide what a git build gets to show, and all three go wrong
quietly: which versions count as a snapshot at all (a wrong yes costs a
network round trip on every ordinary package, a wrong no shows nothing),
which hash is the commit rather than the commit count or the date beside it,
and what survives of a release body written in GitHub-flavoured markdown.
The forge is stubbed here — these are the parts that have to be right before
the network is worth asking.

Run from anywhere:  python3 scripts/test_gitnotes.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import enrich

failures = []


def check(label, got, want):
    ok = got == want
    print(("  ok   " if ok else "  FOUT ") + label)
    if not ok:
        print(f"         verwacht: {want!r}")
        print(f"         gekregen: {got!r}")
        failures.append(label)


print("Versies uit elkaar halen")
check("epoch en release eraf", enrich.evr_version("2:0.0.git.4350.3f6cd0b5-1.fc44"),
      "0.0.git.4350.3f6cd0b5")
check("een versie zonder release blijft heel", enrich.evr_version("26.04"), "26.04")
check("copr git-build", enrich.snapshot_hash("0.0.git.2819.59a10015"), "59a10015")
check("commit-aantal is de hash niet", enrich.snapshot_hash("0.0.git.4350.3f6cd0b5"), "3f6cd0b5")
check("fedora-snapshot met datumstempel", enrich.snapshot_hash("1.2.3^git20260808.abc1234"),
      "abc1234")
check("AUR -git", enrich.snapshot_hash("2.0.0.r1234.abc1234"), "abc1234")
check("een echte uitgave is geen snapshot", enrich.snapshot_hash("26.04"), "")
check("een lang versienummer ook niet", enrich.snapshot_hash("1.20260808.3"), "")
check("git zonder hash geeft niets", enrich.snapshot_hash("1.2.3^git20260808"), "")

print("\nRepository uit de URL")
check("github", enrich.github_repo("https://github.com/niri-wm/niri"), "niri-wm/niri")
check(".git en slash eraf", enrich.github_repo("https://github.com/a/b.git/"), "a/b")
check("gitlab wordt niet gevraagd", enrich.github_repo("https://gitlab.com/a/b"), "")
check("geen URL", enrich.github_repo(""), "")

print("\nRelease-body teruggebracht tot de veilige subset")
BODY = """\
## Highlights

Blur is **here**, at last.

<img width="1920" src="https://example.invalid/shot.png" />

> [!NOTE]
> Packagers: the minimum Rust version is now `1.85`.

| a | b |
| --- | --- |
| 1 | 2 |

- First item, which is
  wrapped over two lines
- Second item with a [link](https://example.invalid/docs)

```
window-rule {
    blur true
}
```
"""
html, dropped = enrich.markdown_notes_html(BODY)
check("kop wordt vet, geen <h2>", "<p><b>Highlights</b></p>" in html, True)
check("inline vet blijft", "<b>here</b>" in html, True)
check("ingebedde HTML verdwijnt, ook als tekst", "img" in html, False)
check("citaatteken weg, alert benoemd", "<p>Note: Packagers: the minimum Rust version is now <code>1.85</code>.</p>" in html, True)
check("tabel valt weg", "|" in html, False)
check("afgebroken opsommingsregel weer aan elkaar",
      "<li>First item, which is wrapped over two lines</li>" in html, True)
check("link houdt zijn woorden, verliest zijn doel", "<li>Second item with a link</li>" in html, True)
check("codeblok blijft, met regeleinden", "<code>window-rule {<br>    blur true<br>}</code>" in html, True)
check("niets afgekapt bij een korte body", dropped, 0)

html, dropped = enrich.markdown_notes_html("\n\n".join("Paragraph %d." % i for i in range(60)),
                                           limit=200)
check("lange body stopt op een blokgrens", html.endswith("</p>"), True)
check("en zegt hoeveel er niet staat", dropped > 0, True)
check("aanhalingsteken wordt geen markup",
      enrich.markdown_inline('<script>alert("x")</script>'), "alert(&quot;x&quot;)")

print("\nCommits tussen twee snapshots")
COMPARE = {
    "total_commits": 3,
    "html_url": "https://github.com/o/r/compare/aaaaaaa...bbbbbbb",
    "commits": [
        {"commit": {"message": "oldest change\n\nbody", "author": {"date": "2026-08-01T10:00:00Z"}}},
        {"commit": {"message": "Merge pull request #12 from x", "author": {"date": "2026-08-02T10:00:00Z"}}},
        {"commit": {"message": "fix(dock): skip empty layers", "author": {"date": "2026-08-03T10:00:00Z"}}},
    ],
}
RELEASES = [
    {"tag_name": "v26.04", "published_at": "2026-04-25T13:50:41Z", "body": "Blur is here.", "draft": False},
    {"tag_name": "v26.02", "published_at": "2026-02-01T00:00:00Z", "body": "Older news.", "draft": False},
    {"tag_name": "v25.11", "published_at": "2025-11-01T00:00:00Z", "body": "Older still.", "draft": False},
    {"tag_name": "v26.06", "published_at": "2026-06-01T00:00:00Z", "body": "Later than the update.", "draft": False},
]

real_http = enrich._http_json
asked = []


def fake_http(url, payload=None, timeout=15):
    asked.append(url)
    return COMPARE if "/compare/" in url else RELEASES


enrich._http_json = fake_http
try:
    out = enrich.github_commits("o/r", "aaaaaaa", "bbbbbbb")
    check("soort", out["kind"], "commits")
    check("nieuwste bovenaan", out["releases"][0]["notesHtml"].index("skip empty layers")
          < out["releases"][0]["notesHtml"].index("oldest change"), True)
    check("merge-commit weggelaten", "Merge pull request" in out["releases"][0]["notesHtml"], False)
    check("aantal is dat van de vergelijking, niet van wat getoond wordt",
          out["commitCount"], 3)
    check("datum van de nieuwste commit", out["releases"][0]["date"],
          enrich.normalize_date("2026-08-03T10:00:00Z"))
    check("hash als versie", out["releases"][0]["version"], "bbbbbbb")

    print("\nUitgaven tussen twee versies")
    out = enrich.github_releases("o/r", "0.0.git.2819.59a10015", "26.04")
    check("vanaf een snapshot alleen de uitgave die je krijgt",
          [r["version"] for r in out["releases"]], ["26.04"])
    out = enrich.github_releases("o/r", "25.11", "26.04")
    check("vanaf een echte versie ook wat je oversloeg",
          [r["version"] for r in out["releases"]], ["26.04", "26.02"])
    check("en niets van na de update", "26.06" in json.dumps(out), False)
    check("de v van de tag hoort niet in de chip", out["releases"][0]["version"], "26.04")
    # The packager is ahead of the tags: nothing describes 27.00 yet, but the
    # releases on the way there are being installed too and each says which
    # version it is, so none of them claims to be the one you asked for
    out = enrich.github_releases("o/r", "25.11", "27.00")
    check("zonder uitgave voor de doelversie blijft alles ertussen staan",
          [r["version"] for r in out["releases"]], ["26.06", "26.04", "26.02"])
    out = enrich.github_releases("o/r", "0.0.git.1.abc1234", "27.00")
    check("vanaf een snapshot valt er dan niets te tonen", out["kind"], "")
finally:
    enrich._http_json = real_http

print("\nWanneer er niet gevraagd wordt")
asked.clear()
enrich._http_json = fake_http
try:
    real_cache = enrich.GITNOTES_CACHE
    enrich.GITNOTES_CACHE = os.path.join(os.path.dirname(real_cache), "gitnotes-test-none.json")
    import io
    held, sys.stdout = sys.stdout, io.StringIO()
    try:
        enrich.run_gitnotes("firefox", "140.0-1.fc44", "141.0-1.fc44")
        printed = json.loads(sys.stdout.getvalue())
    finally:
        sys.stdout = held
    check("een gewoon pakket gaat het netwerk niet op", asked, [])
    check("en zegt waarom", printed["error"], "not a git build")
finally:
    enrich._http_json = real_http
    enrich.GITNOTES_CACHE = real_cache

print()
if failures:
    print(f"{len(failures)} controle(s) mislukt")
    sys.exit(1)
print("alles goed")
