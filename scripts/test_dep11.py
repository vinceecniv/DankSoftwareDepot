#!/usr/bin/env python3
"""Exercise the DEP-11 and apt/pacman changelog paths without a Debian box.

The catalog is a real-shaped DEP-11 file (header document + components,
gzipped, in apt's own naming), fed through the same functions the plugin
calls on Debian.
"""
import gzip
import os
import shutil
import sys
import tempfile

sys.path.insert(0, "/home/vincent/Code/DankSoftwareDepot/scripts")
import pkg_backend

pkg_backend._backend = "apt"          # force the Debian branch
import enrich
enrich.BACKEND = "apt"

DEP11 = """\
File: DEP-11 0.12
Origin: debian-trixie-main
Priority: 30
MediaBaseUrl: https://appstream.debian.org/media/trixie
---
Type: desktop-application
ID: org.gnome.Nautilus.desktop
Package: nautilus
Name:
  C: Files
  nl: Bestanden
  de: Dateien
Summary:
  C: Access and organize files
  nl: Bestanden openen en ordenen
Developer:
  Name:
    C: The GNOME Project
Url:
  homepage: https://apps.gnome.org/Nautilus
Icon:
  cached:
    - name: org.gnome.Nautilus_org.gnome.Nautilus.png
      width: 64
      height: 64
    - name: org.gnome.Nautilus_org.gnome.Nautilus.png
      width: 128
      height: 128
  stock: system-file-manager
Releases:
  - version: '50.2'
    unix-timestamp: 1785283200
    description:
      C: "<p>Bug fixes:</p><ul><li>Fixed a crash in the sidebar</li></ul>"
  - version: '50.1'
    unix-timestamp: 1782604800
    description:
      C: "<p>Ordinary release</p>"
---
Type: desktop-application
ID: org.videolan.VLC.desktop
Package: vlc
Name:
  C: VLC media player
Summary:
  C: Read, capture, broadcast your multimedia streams
DeveloperName:
  C: VideoLAN
Url:
  homepage: https://www.videolan.org/vlc/
Icon:
  stock: vlc
---
Type: font
ID: org.example.SomeFont
Package: fonts-example
Name:
  C: Example Font
"""

DEBIAN_CHANGELOG = """\
nautilus (50.2-1) unstable; urgency=medium

  * New upstream release.
  * Drop patch applied upstream.

 -- A Maintainer <maint@debian.org>  Mon, 04 Aug 2026 10:00:00 +0200

nautilus (50.1-2) unstable; urgency=medium

  * Rebuild against new glib.

 -- A Maintainer <maint@debian.org>  Tue, 22 Jul 2026 09:00:00 +0200

nautilus (50.1-1) unstable; urgency=low

  * Initial upload of 50.1.

 -- A Maintainer <maint@debian.org>  Fri, 04 Jul 2026 12:00:00 +0200

nautilus (50.0-1) unstable; urgency=low

  * Older entry that must be cut off.

 -- A Maintainer <maint@debian.org>  Thu, 12 Jun 2026 12:00:00 +0200

nautilus (49.9-1) unstable; urgency=low

  * Even older.

 -- A Maintainer <maint@debian.org>  Thu, 01 May 2026 12:00:00 +0200
"""

failures = []


def check(label, got, want):
    ok = got == want
    print(("  ok   " if ok else "  FOUT ") + label)
    if not ok:
        print(f"         verwacht: {want!r}")
        print(f"         gekregen: {got!r}")
        failures.append(label)


tmp = tempfile.mkdtemp(prefix="dep11-")
catalog = os.path.join(tmp, "deb.debian.org_debian_dists_trixie_main_dep11_Components-amd64.yml.gz")
with gzip.open(catalog, "wt") as f:
    f.write(DEP11)

print("DEP-11 catalogus")
comps = enrich.scan_yaml_catalog(catalog, {"nautilus", "vlc"})
check("twee gevraagde componenten, het font overgeslagen", len(comps), 2)
by_pkg = {c["pkgname"]: c for c in comps}

nautilus = by_pkg.get("nautilus", {})
check("id", nautilus.get("id"), "org.gnome.Nautilus.desktop")
check("homepage", nautilus.get("homepage"), "https://apps.gnome.org/Nautilus")
check("developer via Developer.Name", nautilus.get("developer"), "The GNOME Project")
check("grootste cached icoon gekozen", nautilus.get("icon_cached"),
      "org.gnome.Nautilus_org.gnome.Nautilus.png")
check("stock icoon", nautilus.get("icon_stock"), "system-file-manager")
check("releases", len(nautilus.get("releases", [])), 2)
check("release-versie", nautilus["releases"][0]["version"], "50.2")
check("release-datum uit unix-timestamp", nautilus["releases"][0]["date"], 1785283200)
check("release-notes gereduceerd tot veilige subset",
      nautilus["releases"][0]["notesHtml"],
      "<p>Bug fixes:</p><ul><li>Fixed a crash in the sidebar</li></ul>")
check("developer via los DeveloperName", by_pkg["vlc"]["developer"], "VideoLAN")

print("\nVertalingen")
enrich._locale_langs_cache = ["nl", "en"]
comps = enrich.scan_yaml_catalog(catalog, {"nautilus"})
check("naam volgt de locale", comps[0]["name"], "Bestanden")
check("samenvatting volgt de locale", comps[0]["summary"], "Bestanden openen en ordenen")
enrich._locale_langs_cache = ["fi"]
comps = enrich.scan_yaml_catalog(catalog, {"nautilus"})
check("onbekende locale valt terug op C", comps[0]["name"], "Files")

print("\nMarkup uit de catalogus mag nooit heel doorkomen")
# Tekstknopen worden aaneengeplakt zoals het XML-pad dat al doet; wat telt is
# dat de tags weg zijn en de tekst geëscaped
check("script wordt ontdaan van tags",
      enrich.dep11_description_html('<p>Hi<script>alert(1)</script></p>'),
      "<p>Hialert(1)</p>")
check("markup in tekst wordt geëscaped",
      enrich.dep11_description_html('<p>a &lt;b&gt; c</p>'),
      "<p>a &lt;b&gt; c</p>")
check("link wordt tekst",
      enrich.dep11_description_html('<p>See <a href="http://x">here</a></p>'),
      "<p>See here</p>")
check("kapotte html valt terug op platte tekst",
      enrich.dep11_description_html('<p>Unclosed &nbsp; thing'),
      "<p>Unclosed &amp;nbsp; thing</p>")

print("\nCatalogus-paden")
enrich.BACKEND = "apt"
check("apt zoekt ook yaml", any(p.endswith(".yml.gz") for p in enrich.YAML_CATALOG_GLOBS), True)
check("apt-lists staat erbij",
      any("/var/lib/apt/lists/" in p for p in enrich.YAML_CATALOG_GLOBS), True)
check("arch legacy xml-pad staat erbij",
      any("/usr/share/app-info/xmls/" in p for p in enrich.XML_CATALOG_GLOBS), True)

print("\nDebian changelog")
docdir = os.path.join(tmp, "doc", "nautilus")
os.makedirs(docdir)
with gzip.open(os.path.join(docdir, "changelog.Debian.gz"), "wt") as f:
    f.write(DEBIAN_CHANGELOG)
real_join = os.path.join


def fake_join(*parts):
    if len(parts) >= 2 and parts[0] == "/usr/share/doc":
        return real_join(tmp, "doc", *parts[1:])
    return real_join(*parts)


pkg_backend.os.path.join = fake_join
try:
    text = pkg_backend.changelog("nautilus")
finally:
    pkg_backend.os.path.join = real_join

check("vier nieuwste entries", text.count("urgency="), 4)
check("nieuwste bovenaan", text.startswith("nautilus (50.2-1)"), True)
check("oudste afgekapt", "49.9-1" in text, False)
check("onbekend pakket geeft leeg", pkg_backend.changelog("does-not-exist"), "")

shutil.rmtree(tmp)
print()
if failures:
    print(f"{len(failures)} controle(s) mislukt")
    sys.exit(1)
print("alles goed")
