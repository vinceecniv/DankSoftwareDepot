#!/usr/bin/env python3
"""System package-manager backend for the metadata layer.

On Fedora the battle-tested dnf code paths in enrich.py stay in use; on
apt systems (Debian/Ubuntu, python3-apt) enrich.py dispatches to this
module instead. The functions mirror the shapes of their dnf
counterparts so the callers need no per-backend logic.

Also usable as a CLI (JSON on stdout), which is how the QML layer and
the container tests call it:

    pkg_backend.py search <query>     [{name, homepage, summary}]
    pkg_backend.py info <name>        {descriptionHtml, download, installed, homepage}
    pkg_backend.py sizes <name>...    {"totalBytes": N, "sizes": {name: bytes}}
    pkg_backend.py dashboard          {"total": N, "recent": [{name, ts}]}
    pkg_backend.py holds              {name: reason}
    pkg_backend.py versions <name>    [{version, repo, installed}]
"""
import glob
import html
import json
import os
import re
import subprocess
import sys

_backend = None


def detect():
    """"apt" on the Debian family, "dnf" otherwise (the default)."""
    global _backend
    if _backend is None:
        _backend = "dnf"
        try:
            with open("/etc/os-release") as f:
                osr = f.read()
            if re.search(r"^(ID|ID_LIKE)=.*?(debian|ubuntu)", osr, re.M | re.I):
                _backend = "apt"
        except OSError:
            pass
    return _backend


def _human(size):
    if size >= 1e9:
        return f"{size / 1e9:.1f} GB"
    if size >= 1e6:
        return f"{size / 1e6:.1f} MB"
    return f"{max(1, round(size / 1e3))} kB"


def _cache():
    import apt
    return apt.Cache()


def name_search(query):
    """Match packages by name — the apt mirror of dnf_name_search."""
    if not re.match(r"^[\w.+-]+$", query):
        return []
    needle = query.lower()
    out = []
    try:
        for pkg in _cache():
            if needle not in pkg.name or re.search(r"-(dbg|dbgsym)$", pkg.name):
                continue
            cand = pkg.candidate
            if cand is None:
                continue
            out.append({"name": pkg.name, "homepage": cand.homepage or "",
                        "summary": cand.summary or ""})
            if len(out) >= 400:
                break
    except Exception:
        return []
    return out


def package_info(name):
    """Description and sizes — the apt mirror of rpm_repoquery_info."""
    out = {}
    try:
        cache = _cache()
        if name not in cache:
            return out
        cand = cache[name].candidate or cache[name].installed
        if cand is None:
            return out
        if cand.description:
            paragraphs = [html.escape(p.strip()) for p in cand.description.split("\n\n") if p.strip()]
            out["descriptionHtml"] = "".join(f"<p>{p}</p>" for p in paragraphs)
        if cand.size:
            out["download"] = _human(cand.size)
        if cand.installed_size:
            out["installed"] = _human(cand.installed_size)
        if cand.homepage:
            out["homepage"] = cand.homepage
    except Exception:
        pass
    return out


def update_sizes(names):
    """Exact candidate download sizes — the apt mirror of the repoquery
    branch in run_update_sizes."""
    total = 0
    sizes = {}
    try:
        cache = _cache()
        for name in names:
            if name not in cache:
                continue
            cand = cache[name].candidate
            if cand and cand.size:
                sizes[name] = int(cand.size)
                total += int(cand.size)
    except Exception:
        pass
    return total, sizes


def dashboard():
    """Installed count and recently-changed packages. dpkg records no
    install time; the package's .list file mtime is the standard stand-in."""
    total = 0
    recent = []
    try:
        res = subprocess.run(["dpkg-query", "-W", "-f", "${Package}\n"],
                             capture_output=True, text=True, timeout=20)
        names = [l for l in res.stdout.splitlines() if l]
        total = len(names)
        entries = []
        for path in glob.glob("/var/lib/dpkg/info/*.list"):
            base = os.path.basename(path)[:-5].split(":")[0]
            try:
                entries.append((int(os.stat(path).st_mtime), base))
            except OSError:
                continue
        entries.sort(reverse=True)
        recent = [{"name": name, "ts": ts} for ts, name in entries[:50]]
    except (OSError, subprocess.SubprocessError):
        pass
    return {"total": total, "recent": recent}


def installed_table():
    """TSV matching the rpm inventory the Installed view parses:
    name<TAB>version<TAB>size-bytes<TAB>installtime, sorted by name.
    dpkg reports Installed-Size in KiB and records no install time; the
    .list file mtime is the stand-in."""
    rows = []
    try:
        res = subprocess.run(["dpkg-query", "-W", "-f", "${Package}\t${Version}\t${Installed-Size}\n"],
                             capture_output=True, text=True, timeout=25)
        mtimes = {}
        for path in glob.glob("/var/lib/dpkg/info/*.list"):
            base = os.path.basename(path)[:-5].split(":")[0]
            try:
                mtimes[base] = int(os.stat(path).st_mtime)
            except OSError:
                continue
        for line in res.stdout.splitlines():
            fields = line.split("\t")
            if len(fields) < 3 or not fields[0]:
                continue
            name = fields[0].split(":")[0]
            size_kib = int(fields[2]) if fields[2].isdigit() else 0
            rows.append((name, fields[1], size_kib * 1024, mtimes.get(name, 0)))
    except (OSError, subprocess.SubprocessError):
        pass
    rows.sort()
    return "\n".join(f"{n}\t{v}\t{s}\t{t}" for n, v, s, t in rows)


def holds():
    """{name: reason} — the apt mirror of compute_holds (apt-mark showhold)."""
    out = {}
    try:
        res = subprocess.run(["apt-mark", "showhold"],
                             capture_output=True, text=True, timeout=15)
        for line in res.stdout.splitlines():
            name = line.strip()
            if name:
                out[name] = "hold"
    except (OSError, subprocess.SubprocessError):
        pass
    return out


def available_versions(name):
    """All available versions, newest first — feeds "Previous versions"."""
    out = []
    try:
        import functools

        import apt_pkg
        cache = _cache()
        if name not in cache:
            return out
        pkg = cache[name]
        installed = pkg.installed.version if pkg.installed else ""
        versions = sorted(pkg.versions,
                          key=functools.cmp_to_key(lambda a, b: apt_pkg.version_compare(a.version, b.version)),
                          reverse=True)
        for v in versions:
            repo = ""
            for origin in v.origins or []:
                if origin.archive:
                    repo = origin.archive
                    break
            out.append({"version": v.version, "repo": repo,
                        "installed": v.version == installed})
    except Exception:
        pass
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    args = sys.argv[2:]
    if cmd == "search" and args:
        json.dump(name_search(args[0]), sys.stdout)
    elif cmd == "info" and args:
        json.dump(package_info(args[0]), sys.stdout)
    elif cmd == "sizes":
        total, sizes = update_sizes(args)
        json.dump({"totalBytes": total, "sizes": sizes}, sys.stdout)
    elif cmd == "dashboard":
        json.dump(dashboard(), sys.stdout)
    elif cmd == "installed-table":
        sys.stdout.write(installed_table() + "\n")
    elif cmd == "holds":
        json.dump(holds(), sys.stdout)
    elif cmd == "versions" and args:
        json.dump(available_versions(args[0]), sys.stdout)
    elif cmd == "detect":
        json.dump({"backend": detect()}, sys.stdout)
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
