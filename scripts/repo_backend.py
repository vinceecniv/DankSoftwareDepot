#!/usr/bin/env python3
"""Software sources: what is configured, and the few changes worth offering.

Reading is unprivileged and prints one JSON object. Changing anything writes
to /etc/yum.repos.d and must therefore run under pkexec; those actions print
NDJSON progress lines so the caller can show what happened and keep the tool's
own words when it fails.

Only the dnf family can be changed from here. Debian and Arch are listed
read-only: an apt source is a file plus a signing key and a pacman repo lives
in a single hand-edited pacman.conf, and offering half of either is worse than
offering neither.
"""

import glob
import json
import os
import re
import subprocess
import sys

# Repositories that exist for building and debugging rather than for using the
# system. They are the majority of the list on Fedora and the reason a plain
# repo list is unreadable, so they are marked and hidden by default.
NOISE = re.compile(r"-(debuginfo|debug|source|source-?rpm)$")
TESTING = re.compile(r"-(testing|rawhide)$|^updates-testing")


def _run(argv, **kwargs):
    return subprocess.run(argv, capture_output=True, text=True, **kwargs)


def _emit(event, **fields):
    fields["event"] = event
    sys.stdout.write(json.dumps(fields) + "\n")
    sys.stdout.flush()


# ── Reading ────────────────────────────────────────────────────────────────


def _repo_files():
    """Which file defines which repo id, for removal and for grouping."""
    owner = {}
    for path in sorted(glob.glob("/etc/yum.repos.d/*.repo")):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    match = re.match(r"^\s*\[([^\]]+)\]", line)
                    if match:
                        owner[match.group(1)] = path
        except OSError:
            continue
    return owner


def _classify(repo_id, path):
    if repo_id.startswith("copr:") or repo_id.startswith("coprdep:"):
        return "copr"
    base = os.path.basename(path or "")
    if base.startswith("fedora") or base in ("fedora.repo", "fedora-updates.repo"):
        return "distro"
    if re.match(r"^(fedora|updates|rawhide)", repo_id):
        return "distro"
    return "third-party"


def _copr_project(repo_id):
    """copr:copr.fedorainfracloud.org:owner:project → owner/project."""
    parts = repo_id.split(":")
    if len(parts) >= 4 and parts[0] in ("copr", "coprdep"):
        return parts[2] + "/" + parts[3]
    return ""


def list_dnf_repos():
    repos = []
    owner = _repo_files()
    try:
        import interp
        interp.ensure("libdnf5")
        import libdnf5

        base = libdnf5.base.Base()
        base.load_config()
        base.setup()
        base.get_repo_sack().create_repos_from_system_configuration()
        for repo in libdnf5.repo.RepoQuery(base):
            repo_id = repo.get_id()
            path = owner.get(repo_id, "")
            repos.append({
                "id": repo_id,
                "name": repo.get_name(),
                "enabled": bool(repo.is_enabled()),
                "kind": _classify(repo_id, path),
                "project": _copr_project(repo_id),
                "file": path,
                "noise": bool(NOISE.search(repo_id)),
                "testing": bool(TESTING.search(repo_id)),
            })
    except Exception as error:  # noqa: BLE001 - the caller shows the reason
        return [], str(error)
    repos.sort(key=lambda r: (r["kind"] != "distro", r["noise"], r["id"]))
    return repos, ""


def list_repo_files():
    """The repositories as their files declare them, without libdnf5.

    An atomic image has no python3-libdnf5 and usually no dnf either, but
    /etc/yum.repos.d is the same directory rpm-ostree reads, so the files
    themselves are a complete answer. dnf treats a section with no `enabled`
    line as enabled, and so does this.
    """
    repos = []
    seen = set()
    for path in sorted(glob.glob("/etc/yum.repos.d/*.repo")):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError:
            continue
        for section in re.split(r"(?m)^\s*\[", text)[1:]:
            repo_id, _, body = section.partition("]")
            repo_id = repo_id.strip()
            if not repo_id or repo_id == "main":
                continue
            # A Copr's dependency repositories are repeated in the file of
            # every project that needs them; the same id twice is one row
            if repo_id in seen:
                continue
            seen.add(repo_id)
            name = re.search(r"(?m)^\s*name\s*=\s*(.+?)\s*$", body)
            enabled = re.search(r"(?m)^\s*enabled\s*=\s*(\d)", body)
            repos.append({
                "id": repo_id,
                "name": name.group(1) if name else "",
                "enabled": enabled is None or enabled.group(1) == "1",
                "kind": _classify(repo_id, path),
                "project": _copr_project(repo_id),
                "file": path,
                "noise": bool(NOISE.search(repo_id)),
                "testing": bool(TESTING.search(repo_id)),
            })
    repos.sort(key=lambda r: (r["kind"] != "distro", r["noise"], r["id"]))
    return repos, ""


def list_apt_repos():
    """Debian sources, read-only: one entry per configured line."""
    repos = []
    paths = ["/etc/apt/sources.list"] + sorted(glob.glob("/etc/apt/sources.list.d/*"))
    for path in paths:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError:
            continue
        if path.endswith(".sources"):  # deb822
            for block in text.split("\n\n"):
                uris = re.search(r"^URIs:\s*(.+)$", block, re.M)
                suites = re.search(r"^Suites:\s*(.+)$", block, re.M)
                if not uris:
                    continue
                enabled = not re.search(r"^Enabled:\s*no", block, re.M)
                repos.append({
                    "id": uris.group(1).strip(),
                    "name": (suites.group(1).strip() if suites else ""),
                    "enabled": enabled,
                    "kind": "third-party",
                    "project": "",
                    "file": path,
                    "noise": False,
                    "testing": False,
                })
            continue
        for line in text.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if not stripped.startswith(("deb ", "deb-src ")):
                continue
            repos.append({
                "id": stripped,
                "name": "",
                "enabled": True,
                "kind": "third-party",
                "project": "",
                "file": path,
                "noise": stripped.startswith("deb-src"),
                "testing": False,
            })
    return repos, ""


def list_pacman_repos():
    repos = []
    try:
        with open("/etc/pacman.conf", "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = re.match(r"^\s*\[([^\]]+)\]", line)
                if match and match.group(1) != "options":
                    repos.append({
                        "id": match.group(1),
                        "name": "",
                        "enabled": True,
                        "kind": "distro" if match.group(1) in ("core", "extra", "multilib") else "third-party",
                        "project": "",
                        "file": "/etc/pacman.conf",
                        "noise": False,
                        "testing": "testing" in match.group(1),
                    })
    except OSError as error:
        return [], str(error)
    return repos, ""


def list_flatpak_remotes():
    remotes = []
    result = _run(["flatpak", "remotes", "--columns=name,title,url,options"])
    if result.returncode != 0:
        return remotes
    for line in result.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        options = parts[3] if len(parts) > 3 else ""
        remotes.append({
            "name": parts[0].strip(),
            "title": parts[1].strip(),
            "url": parts[2].strip(),
            "scope": "user" if "user" in options else "system",
            "disabled": "disabled" in options,
            # Local build repositories are not sources anyone manages here
            "local": parts[2].strip().startswith("file://"),
        })
    return remotes


# The Flatpak remotes worth offering as a button. Names match what each
# .flatpakrepo calls itself, so a remote added by hand earlier is recognised
# as present rather than offered a second time. Descriptions live in the UI,
# where they can be translated.
FLATPAK_CATALOG = [
    {"name": "flathub", "title": "Flathub",
     "url": "https://dl.flathub.org/repo/flathub.flatpakrepo", "distro": ""},
    {"name": "flathub-beta", "title": "Flathub Beta",
     "url": "https://flathub.org/beta-repo/flathub-beta.flatpakrepo", "distro": ""},
    {"name": "fedora", "title": "Fedora Flatpaks",
     "url": "oci+https://registry.fedoraproject.org", "distro": "dnf"},
    {"name": "gnome-nightly", "title": "GNOME Nightly",
     "url": "https://nightly.gnome.org/gnome-nightly.flatpakrepo", "distro": ""},
    {"name": "kdeapps", "title": "KDE Nightly",
     "url": "https://cdn.kde.org/flatpak/kdeapps-nightly/kdeapps.flatpakrepo", "distro": ""},
]


def flatpak_catalog(backend, remotes):
    present = {r["name"] for r in remotes}
    out = []
    for entry in FLATPAK_CATALOG:
        if entry["distro"] and entry["distro"] != backend:
            continue
        item = dict(entry)
        item["present"] = entry["name"] in present
        out.append(item)
    return out


def fedora_release():
    result = _run(["rpm", "-E", "%fedora"])
    value = result.stdout.strip()
    return value if value.isdigit() else ""


def suggestions(backend, repos, remotes):
    """The handful of sources most systems are expected to want.

    Each one says what it is for, whether it is already there, and what it
    would take — so the offer is a fact about this machine rather than a
    generic recommendation.
    """
    out = []
    if backend == "dnf":
        installed = {}
        for flavour in ("free", "nonfree"):
            result = _run(["rpm", "-q", "rpmfusion-%s-release" % flavour])
            installed[flavour] = result.returncode == 0
        missing = [f for f in ("free", "nonfree") if not installed[f]]
        if missing:
            # Offered together when both are absent: much of nonfree builds on
            # free, so adding nonfree alone is half an installation
            out.append({
                "id": "rpmfusion-both" if len(missing) == 2 else "rpmfusion-" + missing[0],
                "kind": "rpmfusion",
                "flavours": missing,
                "present": False,
            })
    return out


def read_all(backend):
    if backend == "apt":
        repos, error = list_apt_repos()
    elif backend == "pacman":
        repos, error = list_pacman_repos()
    elif backend == "ostree":
        repos, error = list_repo_files()
    else:
        repos, error = list_dnf_repos()
        # Without the bindings the files still say what is configured, which
        # is a better answer than an error where a list should be
        if error:
            repos, error = list_repo_files()
    remotes = list_flatpak_remotes()
    return {
        "backend": backend,
        "error": error,
        # Only the dnf family can be changed from here — an atomic Fedora
        # included: /etc/yum.repos.d is writable there, and it is what
        # rpm-ostree layers from
        "writable": backend in ("dnf", "ostree"),
        "repos": repos,
        "flatpak": remotes,
        "suggestions": suggestions(backend, repos, remotes),
        "flatpakCatalog": flatpak_catalog(backend, remotes),
        "fedora": fedora_release() if backend == "dnf" else "",
    }


# ── Searching Copr ─────────────────────────────────────────────────────────
# A package built in Copr is invisible to dnf until its project is enabled,
# which is the wrong way round for anyone looking for software they have not
# found yet. Two API calls answer it without enabling anything:
#
#   · /api_3/project/search matches project names and descriptions, and each
#     hit says which chroots it builds for. It takes several seconds.
#   · /api_3/package/list turns a project into the packages it actually built.
#     One call per project, fast, and they run together.
#
# The hub's own package-by-name page would be the shorter road, but it is
# HTML behind a bot check that any non-browser client fails; the API is the
# interface offered to programs, so the API is what this uses.
#
# Only projects building for this machine's own chroot are offered. One that
# stopped at fedora-43 cannot be enabled here, and offering it would end in
# dnf's "Chroot not found" — the failure this search exists to keep people
# out of. Answers are cached for a few hours: the same search twice in an
# afternoon is common, and the slow half of it never changes that fast.

COPR_HUB = "https://copr.fedorainfracloud.org"
COPR_AGENT = "dankSoftwareDepot/0.1"
COPR_PROJECT_LIMIT = 20      # package lists fetched for one search
COPR_RESULT_LIMIT = 40
COPR_CACHE = os.path.join(
    os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")),
    "dankSoftwareDepot", "copr-search.json")
COPR_CACHE_TTL = 6 * 3600
COPR_CACHE_MAX = 60
TAGS = re.compile(r"<[^>]+>")


def _quote(text):
    import urllib.parse
    return urllib.parse.quote(text, safe="")


def _http_text(url, timeout=25):
    import urllib.request
    request = urllib.request.Request(url, headers={"User-Agent": COPR_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", "replace")


def _http_json(url, timeout=25):
    return json.loads(_http_text(url, timeout))


def system_chroot():
    """The one chroot this machine can install from, e.g. fedora-44-x86_64."""
    release = fedora_release()
    return "fedora-%s-%s" % (release, os.uname().machine) if release else ""


def _plain(text):
    """Project descriptions are markdown with the odd HTML tag in them."""
    return re.sub(r"\s+", " ", TAGS.sub(" ", text or "")).strip()


def _project_packages(full_name, needle):
    owner, _, name = full_name.partition("/")
    try:
        data = _http_json("%s/api_3/package/list?ownername=%s&projectname=%s"
                          % (COPR_HUB, _quote(owner), _quote(name)), timeout=20)
    except Exception:  # noqa: BLE001 - one unreachable project is not an error
        return []
    return [item["name"] for item in data.get("items", [])
            if needle in (item.get("name") or "").lower()]


def _named_project(query, chroot):
    """"owner/project" typed in full: the one project meant, not a search."""
    owner, _, name = query.partition("/")
    if not owner or not name or "/" in name:
        return []
    try:
        project = _http_json("%s/api_3/project?ownername=%s&projectname=%s"
                             % (COPR_HUB, _quote(owner), _quote(name)), timeout=20)
    except Exception:  # noqa: BLE001 - no such project is an empty result
        return []
    if chroot not in (project.get("chroot_repos") or {}):
        return []
    return [{"name": pkg, "project": project["full_name"],
             "description": _plain(project.get("description"))[:160]}
            for pkg in _project_packages(project["full_name"], "")]


def copr_projects(query, chroot):
    """Packages matching the query, in projects that build for this system.

    The project search matches names and descriptions; the package lists are
    what turn a project into something installable, and they are fetched
    together because one at a time is a wait nobody would sit through.
    """
    from concurrent.futures import ThreadPoolExecutor

    data = _http_json("%s/api_3/project/search?query=%s" % (COPR_HUB, _quote(query)), timeout=40)
    needle = query.lower()
    projects = [p for p in data.get("items", []) if chroot in (p.get("chroot_repos") or {})]
    # A project named after the thing being looked for is the likelier home of
    # a package named after it too
    projects.sort(key=lambda p: 0 if needle in (p.get("name") or "").lower() else 1)
    projects = projects[:COPR_PROJECT_LIMIT]

    with ThreadPoolExecutor(max_workers=8) as pool:
        listings = list(pool.map(lambda p: _project_packages(p["full_name"], needle), projects))

    out = []
    for project, packages in zip(projects, listings):
        summary = _plain(project.get("description"))[:160]
        for name in packages:
            out.append({"name": name, "project": project["full_name"], "description": summary})
    return out


def _installed_from(names):
    """Which repository each of these installed packages came out of.

    Five Coprs can offer a package of the same name, and the name alone says
    nothing about which of them is on the machine. dnf records the repository
    a package was installed from, which answers it exactly.
    """
    out = {}
    if not names:
        return out
    try:
        import interp
        interp.ensure("libdnf5")
        import libdnf5

        base = libdnf5.base.Base()
        base.load_config()
        base.setup()
        base.get_repo_sack().load_repos(libdnf5.repo.Repo.Type_SYSTEM)
        query = libdnf5.rpm.PackageQuery(base)
        query.filter_installed()
        for package in query:
            name = package.get_name()
            if name in names:
                out[name] = package.get_from_repo_id()
    except Exception:  # noqa: BLE001 - without it nothing is marked installed
        return {}
    return out


def _cache_read(key):
    import time
    try:
        with open(COPR_CACHE, "r", encoding="utf-8") as handle:
            cache = json.load(handle)
    except (OSError, ValueError):
        return None, {}
    entry = cache.get(key)
    if entry and time.time() - entry.get("ts", 0) < COPR_CACHE_TTL:
        return entry.get("hits"), cache
    return None, cache


def _cache_write(key, hits, cache):
    import time
    cache[key] = {"ts": time.time(), "hits": hits}
    if len(cache) > COPR_CACHE_MAX:
        for stale in sorted(cache, key=lambda k: cache[k].get("ts", 0))[:len(cache) - COPR_CACHE_MAX]:
            cache.pop(stale, None)
    try:
        os.makedirs(os.path.dirname(COPR_CACHE), exist_ok=True)
        with open(COPR_CACHE, "w", encoding="utf-8") as handle:
            json.dump(cache, handle)
    except OSError:
        pass


def copr_search(query):
    query = (query or "").strip()
    chroot = system_chroot()
    if len(query) < 2:
        return {"query": query, "chroot": chroot, "items": [], "error": ""}
    if not chroot:
        return {"query": query, "chroot": "", "items": [],
                "error": "searching Copr needs a Fedora release"}

    error = ""
    key = chroot + " " + query.lower()
    hits, cache = _cache_read(key)
    if hits is None:
        try:
            hits = _named_project(query, chroot) if "/" in query else copr_projects(query, chroot)
            _cache_write(key, hits, cache)
        except Exception as exc:  # noqa: BLE001 - the UI says why the search is empty
            hits = []
            error = str(exc)

    needle = query.lower()

    def rank(hit):
        name = hit["name"].lower()
        if name == needle:
            return 0
        if name.startswith(needle):
            return 1
        return 2

    hits.sort(key=lambda h: (rank(h), h["name"], h["project"]))
    hits = hits[:COPR_RESULT_LIMIT]
    # Which Coprs are already configured: an installable package from one of
    # them needs no repository added, and needs no warning either
    enabled = {r["project"] for r in list_dnf_repos()[0] if r["project"]}
    # Installed is a fact about one build, not about a name: the row that says
    # so has to be the Copr the package actually came from
    origin = _installed_from({hit["name"] for hit in hits})
    items = []
    for hit in hits:
        items.append({
            "id": "copr:%s:%s" % (hit["project"], hit["name"]),
            "name": hit["name"],
            "summary": hit["description"],
            "homepage": "%s/coprs/%s/" % (COPR_HUB, hit["project"]),
            "icon": "",
            "updated": 0,
            "rating": None,
            "score": rank(hit),
            "sources": [{
                "source": "copr",
                "kind": "copr",
                "ref": hit["name"],
                "project": hit["project"],
                "enabled": hit["project"] in enabled,
                "installed": _copr_project(origin.get(hit["name"], "")) == hit["project"],
            }],
        })
    return {"query": query, "chroot": chroot, "items": items, "error": error}


# ── Changing ───────────────────────────────────────────────────────────────


def remote_name_from_url(url):
    base = url.rstrip("/").split("/")[-1]
    for suffix in (".flatpakrepo", ".flatpakref"):
        if base.endswith(suffix):
            return base[: -len(suffix)]
    host = re.sub(r"^https?://", "", url).split("/")[0]
    host = re.sub(r"^(dl|repo|www)\.", "", host)
    return host.split(".")[0] or "remote"


# dnf5 draws its downloads on the same stream it later fails on, so a failure
# opens with a line like "…/api_ 100% |  434.0   B/s | 334.0   B |  00m01s".
# That is a picture of a finished download, not a reason, and it pushes the
# actual reason out of view.
PROGRESS_LINE = re.compile(r"\d{1,3}%\s*\|")


def _clean_output(text):
    lines = [line.strip() for line in (text or "").splitlines()]
    return "\n".join(l for l in lines if l and not PROGRESS_LINE.search(l))


def _copr_reason(output):
    """dnf's chroot complaint, said as the fact behind it.

    "Chroot not found in the given Copr project (fedora-44-x86_64)" followed by
    every chroot the project does build for means one thing worth reading: this
    Copr has nothing built for this system. The list is long, mostly EPEL, and
    is why the reason itself never fits on screen.
    """
    if "Chroot not found" not in output:
        return {}
    match = re.search(r"\(([\w.+-]+)\)", output)
    return {"code": "copr-no-chroot", "chroot": match.group(1) if match else ""}


# ── Adding a Copr where dnf is not ─────────────────────────────────────────
# `dnf copr enable` writes one file into /etc/yum.repos.d, and the hub serves
# that exact file. An atomic image has the directory but not dnf, so it is
# fetched and written directly — the same file, the same name, so `dnf copr
# remove` on a mutable system and this on an atomic one are interchangeable.

REPOS_DIR = "/etc/yum.repos.d"


def copr_repo_url(project, release):
    owner, _, name = project.partition("/")
    if owner.startswith("@"):
        group = owner[1:]
        return ("%s/coprs/g/%s/%s/repo/fedora-%s/group_%s-%s-fedora-%s.repo"
                % (COPR_HUB, group, name, release, group, name, release))
    return ("%s/coprs/%s/%s/repo/fedora-%s/%s-%s-fedora-%s.repo"
            % (COPR_HUB, owner, name, release, owner, name, release))


def copr_repo_path(project):
    owner, _, name = project.partition("/")
    return os.path.join(REPOS_DIR, "_copr:copr.fedorainfracloud.org:%s:%s.repo"
                        % (owner.lstrip("@"), name))


def copr_enable_file(project, description):
    """Install the hub's own .repo file, checking the chroot exists first."""
    _emit("op-start", message=description)
    release = fedora_release()
    chroot = system_chroot()
    if not release:
        _emit("op-error", message=description, detail="not a Fedora release")
        return False
    try:
        # The same fact dnf's copr plugin refuses on, found before writing
        # anything rather than after
        owner, _, name = project.partition("/")
        info = _http_json("%s/api_3/project?ownername=%s&projectname=%s"
                          % (COPR_HUB, _quote(owner), _quote(name)), timeout=20)
        if chroot not in (info.get("chroot_repos") or {}):
            _emit("op-error", message=description,
                  detail="Chroot not found in the given Copr project (%s)" % chroot,
                  code="copr-no-chroot", chroot=chroot)
            return False
        text = _http_text(copr_repo_url(project, release), timeout=20)
    except Exception as exc:  # noqa: BLE001 - the UI shows the reason
        _emit("op-error", message=description, detail=str(exc))
        return False
    if "[copr:" not in text:
        _emit("op-error", message=description, detail="the Copr hub returned no repository file")
        return False
    try:
        with open(copr_repo_path(project), "w", encoding="utf-8") as handle:
            handle.write(text)
    except OSError as error:
        _emit("op-error", message=description, detail=str(error))
        return False
    return True


def copr_remove_file(project, description):
    _emit("op-start", message=description)
    path = copr_repo_path(project)
    try:
        os.remove(path)
    except FileNotFoundError:
        # Nothing to remove is the state that was asked for
        return True
    except OSError as error:
        _emit("op-error", message=description, detail=str(error))
        return False
    return True


def _has_dnf():
    import shutil
    return shutil.which("dnf") is not None


def _atomic():
    """Booted from an ostree deployment — rpm-ostree country."""
    return os.path.exists("/run/ostree-booted")


def set_enabled_file(repo_id, value, description):
    """Flip `enabled=` in the file that declares this repository.

    What `dnf config-manager setopt` does, for a system that has no dnf. Only
    the named section is touched: a file can hold half a dozen.
    """
    _emit("op-start", message=description)
    path = _repo_files().get(repo_id, "")
    if not path:
        _emit("op-error", message=description, detail="no file declares %s" % repo_id)
        return False
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
    except OSError as error:
        _emit("op-error", message=description, detail=str(error))
        return False

    out = []
    inside = False
    written = False
    header_at = -1
    for line in lines:
        header = re.match(r"^\s*\[([^\]]+)\]", line)
        if header:
            inside = header.group(1).strip() == repo_id
            if inside:
                header_at = len(out)
        elif inside and re.match(r"^\s*enabled\s*=", line):
            line = "enabled=%s\n" % value
            written = True
        out.append(line)
    # A section with no `enabled` line was relying on the default, so the
    # line is added — directly under its heading, where a reader looks
    if header_at >= 0 and not written:
        out.insert(header_at + 1, "enabled=%s\n" % value)

    try:
        with open(path, "w", encoding="utf-8") as handle:
            handle.writelines(out)
    except OSError as error:
        _emit("op-error", message=description, detail=str(error))
        return False
    return True


def _step(command, description, explain=None):
    _emit("op-start", message=description)
    result = _run(command)
    if result.returncode != 0:
        detail = _clean_output(result.stderr) or _clean_output(result.stdout)
        fields = explain(detail) if explain else {}
        _emit("op-error", message=description, detail=detail[:4000], **fields)
        return False
    return True


def write_action(argv):
    action = argv[0]
    rest = argv[1:]

    if os.geteuid() != 0 and action != "flatpak-add" and action != "flatpak-remove":
        _emit("error", message="this action needs root")
        _emit("done", ok=False)
        return 1

    ok = True
    if action == "enable" or action == "disable":
        value = "1" if action == "enable" else "0"
        for repo_id in rest:
            description = "%s %s" % (action, repo_id)
            if _has_dnf():
                ok = _step(["dnf", "-y", "config-manager", "setopt",
                            "%s.enabled=%s" % (repo_id, value)], description) and ok
            else:
                ok = set_enabled_file(repo_id, value, description) and ok
    elif action == "copr-enable":
        for project in rest:
            description = "enable copr %s" % project
            if _has_dnf():
                ok = _step(["dnf", "-y", "copr", "enable", project], description,
                           _copr_reason) and ok
            else:
                ok = copr_enable_file(project, description) and ok
    elif action == "copr-remove":
        for project in rest:
            description = "remove copr %s" % project
            if _has_dnf():
                ok = _step(["dnf", "-y", "copr", "remove", project], description) and ok
            else:
                ok = copr_remove_file(project, description) and ok
    elif action == "rpmfusion":
        release = fedora_release()
        if not release:
            _emit("error", message="could not determine the Fedora release")
            _emit("done", ok=False)
            return 1
        urls = []
        for flavour in rest:
            urls.append(
                "https://mirrors.rpmfusion.org/%s/fedora/rpmfusion-%s-release-%s.noarch.rpm"
                % (flavour, flavour, release))
        if _atomic():
            # The release packages are layered like anything else, and take
            # effect at the next boot — which is what RPM Fusion's own
            # Silverblue instructions say too
            ok = _step(["rpm-ostree", "install", "--idempotent"] + urls, "install RPM Fusion")
        else:
            ok = _step(["dnf", "-y", "install"] + urls, "install RPM Fusion")
    elif action == "flatpak-add":
        # Flathub by name, anything else by URL, and always system-wide when
        # run as root — a user remote from a root process would land in root's
        # own installation, which is nobody's
        name = rest[0] if rest else "flathub"
        url = rest[1] if len(rest) > 1 else "https://dl.flathub.org/repo/flathub.flatpakrepo"
        if not name:
            # A .flatpakrepo file names the remote it describes; failing that,
            # the host it came from is a better guess than asking twice
            name = remote_name_from_url(url)
        scope = "--system" if os.geteuid() == 0 else "--user"
        ok = _step(["flatpak", scope, "remote-add", "--if-not-exists", name, url],
                   "add Flatpak remote %s" % name)
    elif action == "flatpak-remove":
        name = rest[0] if rest else ""
        scope = "--system" if (len(rest) > 1 and rest[1] == "system") else "--user"
        ok = _step(["flatpak", scope, "remote-delete", "--force", name],
                   "remove Flatpak remote %s" % name)
    else:
        _emit("error", message="unknown action: %s" % action)
        _emit("done", ok=False)
        return 1

    _emit("done", ok=ok)
    return 0 if ok else 1


def main():
    argv = sys.argv[1:]
    if not argv:
        argv = ["list"]
    if argv[0] == "list":
        backend = argv[1] if len(argv) > 1 else "dnf"
        sys.stdout.write(json.dumps(read_all(backend)) + "\n")
        return 0
    if argv[0] == "copr-search":
        sys.stdout.write(json.dumps(copr_search(argv[1] if len(argv) > 1 else "")) + "\n")
        return 0
    return write_action(argv)


if __name__ == "__main__":
    sys.exit(main())
