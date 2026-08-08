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
    else:
        repos, error = list_dnf_repos()
    remotes = list_flatpak_remotes()
    return {
        "backend": backend,
        "error": error,
        # Only the dnf family can be changed from here
        "writable": backend == "dnf",
        "repos": repos,
        "flatpak": remotes,
        "suggestions": suggestions(backend, repos, remotes),
        "flatpakCatalog": flatpak_catalog(backend, remotes),
        "fedora": fedora_release() if backend == "dnf" else "",
    }


# ── Changing ───────────────────────────────────────────────────────────────


def remote_name_from_url(url):
    base = url.rstrip("/").split("/")[-1]
    for suffix in (".flatpakrepo", ".flatpakref"):
        if base.endswith(suffix):
            return base[: -len(suffix)]
    host = re.sub(r"^https?://", "", url).split("/")[0]
    host = re.sub(r"^(dl|repo|www)\.", "", host)
    return host.split(".")[0] or "remote"


def _step(command, description):
    _emit("op-start", message=description)
    result = _run(command)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        _emit("op-error", message=description, detail=detail[:4000])
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
            ok = _step(["dnf", "-y", "config-manager", "setopt", "%s.enabled=%s" % (repo_id, value)],
                       "%s %s" % (action, repo_id)) and ok
    elif action == "copr-enable":
        for project in rest:
            ok = _step(["dnf", "-y", "copr", "enable", project], "enable copr %s" % project) and ok
    elif action == "copr-remove":
        for project in rest:
            ok = _step(["dnf", "-y", "copr", "remove", project], "remove copr %s" % project) and ok
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
    return write_action(argv)


if __name__ == "__main__":
    sys.exit(main())
