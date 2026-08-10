#!/usr/bin/env python3
"""AppImage management for Dank Software Depot (Gearlever-style).

AppImages live in ~/Applications; each install gets a desktop entry and an
icon extracted from the image, and a record in
~/.local/share/dankSoftwareDepot/appimages.json. Apps installed from a GitHub
repository track releases for updates.

Modes:
  --index                          search catalog (appimage.github.io, cached daily)
  --install <url-or-path> [name]   install from URL or local file  (NDJSON progress)
  --install-github <owner/repo> [name]                             (NDJSON progress)
  --list                           registered AppImages (JSON)
  --check-updates                  pending updates for registered apps (JSON, cached 30 min)
  --update-ids <id...>             update registered apps            (NDJSON progress)
  --set-repo <id> [link]           set/clear the GitHub update source (JSON)
  --uninstall <id>                 remove file, desktop entry, icon and record
  --inspect <path>                 name/version/icon of a file, and the app it
                                   would replace, without installing (JSON)
  --replace <id> <path>            put this file in place of a registered app
  --handler-status                 are we the default for .appimage? (JSON)
  --handler-set / --handler-clear  become that default, or stop being it
"""
import glob
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request

def _gearlever_dir():
    """Gearlever's folder, but only when it was pointed somewhere else.

    `dconf read` prints explicitly set values only — a default Gearlever
    install leaves the key unset and answers from its GSettings schema, so
    this is empty far more often than it looks. That is fine: the schema
    default is ~/AppImages, which is also ours.
    """
    try:
        res = subprocess.run(["dconf", "read", "/it/mijorus/gearlever/appimages-default-folder"],
                             capture_output=True, text=True, timeout=5)
        value = res.stdout.strip().strip("'\"")
        if value:
            return os.path.expanduser(value)
    except (OSError, subprocess.SubprocessError):
        pass
    return ""


DEFAULT_APP_DIR = os.path.expanduser("~/AppImages")


def resolve_app_dir():
    """Where new AppImages go.

    ~/AppImages regardless of whether Gearlever is installed: it is
    Gearlever's own default, so the two agree on one folder even on a
    machine that never had it. Created on first install rather than
    required up front — an empty folder in $HOME is not worth leaving
    behind for someone who never installs an AppImage.
    """
    return _gearlever_dir() or DEFAULT_APP_DIR


APP_DIR = resolve_app_dir()
SCAN_DIRS = [d for d in dict.fromkeys([APP_DIR, os.path.expanduser("~/AppImages"), os.path.expanduser("~/Applications")]) if os.path.isdir(d)]
DATA_DIR = os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")), "dankSoftwareDepot")
DATA_FILE = os.path.join(DATA_DIR, "appimages.json")
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "dankSoftwareDepot")
FEED_CACHE = os.path.join(CACHE_DIR, "appimage-feed.json")
UPDATES_CACHE = os.path.join(CACHE_DIR, "appimage-updates.json")
DESKTOP_DIR = os.path.expanduser("~/.local/share/applications")
ICON_DIR = os.path.expanduser("~/.local/share/icons")
FEED_URL = "https://appimage.github.io/feed.json"
DB_BASE = "https://appimage.github.io/database/"
UA = {"User-Agent": "dankSoftwareDepot/0.1"}


def emit(obj):
    print(json.dumps(obj), flush=True)


def load_records():
    try:
        with open(DATA_FILE) as f:
            records = json.load(f)
        return records if isinstance(records, list) else []
    except (OSError, ValueError):
        return []


def save_records(records):
    os.makedirs(DATA_DIR, exist_ok=True)
    tmp = DATA_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(records, f, indent=1)
    os.replace(tmp, DATA_FILE)


def slugify(name):
    slug = re.sub(r"[^a-z0-9]+", "-", (name or "appimage").lower()).strip("-")
    return slug or "appimage"


def http_json(url, timeout=20):
    req = urllib.request.Request(url, headers={**UA, "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def extract_zsync_repo(path):
    """owner/repo from the embedded gh-releases-zsync update info, if any."""
    try:
        with open(path, "rb") as f:
            data = f.read(4 * 1024 * 1024)
        idx = data.find(b"gh-releases-zsync|")
        if idx < 0:
            return ""
        blob = data[idx:idx + 300].split(b"\x00")[0].decode(errors="replace")
        parts = blob.split("|")
        if len(parts) >= 3:
            return parts[1] + "/" + parts[2]
    except OSError:
        pass
    return ""


def find_desktop_for(file_path):
    """Existing desktop entry (e.g. written by Gearlever) pointing at this file."""
    for desktop in glob.glob(os.path.join(DESKTOP_DIR, "*.desktop")):
        try:
            with open(desktop, errors="replace") as f:
                content = f.read()
        except OSError:
            continue
        if file_path in content:
            name = ""
            icon = ""
            for line in content.splitlines():
                if line.startswith("Name=") and not name:
                    name = line[5:].strip()
                elif line.startswith("Icon=") and not icon:
                    icon = line[5:].strip()
            return {"path": desktop, "name": name, "icon": icon}
    return None


def resolve_icon_name(icon):
    """Desktop entries may reference a themed icon NAME — resolve it to a file."""
    if not icon:
        return ""
    if os.path.isabs(icon):
        return icon if os.path.isfile(icon) else ""
    bases = (
        os.path.expanduser("~/.local/share/icons"),
        os.path.expanduser("~/.local/share/pixmaps"),
        "/usr/share/icons/hicolor",
        "/usr/share/pixmaps",
    )
    for base in bases:
        for ext in ("png", "svg", "xpm"):
            direct = os.path.join(base, f"{icon}.{ext}")
            if os.path.isfile(direct):
                return direct
        matches = sorted(glob.glob(os.path.join(base, "**", f"{icon}.png"), recursive=True) +
                         glob.glob(os.path.join(base, "**", f"{icon}.svg"), recursive=True), reverse=True)
        if matches:
            return matches[0]
    return ""


def adhoc_icon(path, app_id, desktop_icon):
    """Icon for an unmanaged AppImage: themed desktop icon, previously
    extracted icon, or a one-time extraction from the image itself."""
    resolved = resolve_icon_name(desktop_icon)
    if resolved:
        return resolved
    for ext in ("png", "svg"):
        cached = os.path.join(ICON_DIR, f"dsd-appimage-{app_id}.{ext}")
        if os.path.isfile(cached):
            return cached
    marker = os.path.join(ICON_DIR, f".dsd-appimage-{app_id}.noicon")
    if os.path.exists(marker):
        return ""
    meta = extract_metadata(path, app_id)
    if meta.get("icon"):
        return meta["icon"]
    try:
        os.makedirs(ICON_DIR, exist_ok=True)
        with open(marker, "w"):
            pass
    except OSError:
        pass
    return ""


def scan_adhoc(records):
    """AppImage files already present in the app folders but not managed by
    us (e.g. installed by Gearlever or dropped in manually)."""
    known_files = {r.get("file") for r in records}
    known_ids = {r.get("id") for r in records}
    found = []
    for directory in SCAN_DIRS:
        for path in sorted(glob.glob(os.path.join(directory, "*.[Aa]pp[Ii]mage"))):
            if path in known_files:
                continue
            stem = re.sub(r"\.appimage$", "", os.path.basename(path), flags=re.I)
            desktop = find_desktop_for(path)
            display = (desktop or {}).get("name") or stem
            app_id = slugify(display)
            if app_id in known_ids:
                app_id = slugify(stem)
                if app_id in known_ids:
                    continue
            try:
                st = os.stat(path)
            except OSError:
                continue
            found.append({
                "id": app_id,
                "name": display,
                "file": path,
                "icon": adhoc_icon(path, app_id, (desktop or {}).get("icon", "")),
                "repo": extract_zsync_repo(path),
                "tag": "",
                "managed": False,
                "installedAt": int(st.st_mtime),
                "sizeBytes": st.st_size,
            })
            known_ids.add(app_id)
    return found


# ── Catalog ──────────────────────────────────────────────────────────────────

def run_index():
    try:
        st = os.stat(FEED_CACHE)
        if time.time() - st.st_mtime < 24 * 3600:
            with open(FEED_CACHE) as f:
                print(f.read())
                return
    except OSError:
        pass
    entries = []
    try:
        feed = http_json(FEED_URL, timeout=30)
        for item in feed.get("items", []):
            name = item.get("name") or ""
            if not name:
                continue
            repo = ""
            download = ""
            for link in item.get("links") or []:
                if link.get("type") == "GitHub" and not repo:
                    repo = link.get("url") or ""
                elif link.get("type") == "Download" and not download:
                    download = link.get("url") or ""
            icons = item.get("icons") or []
            import html as htmlmod
            raw = (item.get("description") or "").strip()
            # Rows/search use plain text (single elided line can't render HTML)
            summary = " ".join(htmlmod.unescape(re.sub(r"<[^>]+>", " ", raw)).split())
            # The popup keeps basic structure: escape everything, then allow
            # a safe subset of tags back in
            desc = htmlmod.escape(htmlmod.unescape(raw))
            for tag in ("p", "ul", "ol", "li", "br"):
                desc = desc.replace(f"&lt;{tag}&gt;", f"<{tag}>").replace(f"&lt;/{tag}&gt;", f"</{tag}>")
                desc = desc.replace(f"&lt;{tag}/&gt;", f"<{tag}/>").replace(f"&lt;{tag} /&gt;", f"<{tag}/>")
            entries.append({
                "id": slugify(name),
                "name": name,
                "summary": summary,
                "descriptionHtml": desc if desc != summary else "",
                "screenshots": [DB_BASE + s for s in (item.get("screenshots") or [])[:8]],
                "homepage": download or ("https://github.com/" + repo if repo else ""),
                "iconUrl": (DB_BASE + icons[0]) if icons else "",
                "repo": repo,
                "download": download,
                "categories": item.get("categories") or [],
                "nl": name.lower(),
                "sl": summary.lower(),
            })
    except Exception:
        entries = []
    if entries:
        try:
            os.makedirs(CACHE_DIR, exist_ok=True)
            with open(FEED_CACHE, "w") as f:
                json.dump(entries, f)
        except OSError:
            pass
    json.dump(entries, sys.stdout)


# ── Install / update mechanics ───────────────────────────────────────────────

def resolve_github_release(repo):
    """Latest release tag + AppImage asset URL for owner/repo."""
    release = http_json(f"https://api.github.com/repos/{repo}/releases/latest")
    assets = [a for a in release.get("assets", []) if (a.get("name") or "").lower().endswith(".appimage")]
    if not assets:
        raise RuntimeError("no AppImage asset in latest release")
    preferred = [a for a in assets if re.search(r"(x86[_-]?64|amd64)", a["name"], re.I)]
    unwanted = re.compile(r"(aarch64|arm64|armhf|i686|zsync)", re.I)
    pool = preferred or [a for a in assets if not unwanted.search(a["name"])] or assets
    asset = pool[0]
    published = 0
    try:
        import datetime
        published = int(datetime.datetime.fromisoformat((release.get("published_at") or "").replace("Z", "+00:00")).timestamp())
    except (ValueError, TypeError):
        pass
    return {
        "tag": release.get("tag_name") or "",
        "url": asset.get("browser_download_url") or "",
        "size": asset.get("size") or 0,
        "assetName": asset.get("name") or "",
        "published": published,
    }


def download(url, dest, total_hint=0):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as resp:
        total = int(resp.headers.get("Content-Length") or total_hint or 0)
        done = 0
        last_pct = -1
        with open(dest, "wb") as f:
            while True:
                chunk = resp.read(256 * 1024)
                if not chunk:
                    break
                f.write(chunk)
                done += len(chunk)
                pct = int(done * 100 / total) if total else 0
                if pct != last_pct:
                    last_pct = pct
                    emit({"event": "progress", "percent": pct, "bytes": done, "total": total})


def extract_metadata(appimage_path, app_id):
    """Best-effort icon + desktop info via --appimage-extract (runs the
    AppImage runtime only, not the app)."""
    info = {"icon": "", "desktopName": "", "categories": "", "version": ""}
    tmp = tempfile.mkdtemp(prefix="dsd-appimage-")
    try:
        subprocess.run([appimage_path, "--appimage-extract"], cwd=tmp,
                       capture_output=True, timeout=60)
        root = os.path.join(tmp, "squashfs-root")
        desktops = glob.glob(os.path.join(root, "*.desktop"))
        icon_name = ""
        if desktops:
            with open(desktops[0], errors="replace") as f:
                for line in f:
                    if line.startswith("Name=") and not info["desktopName"]:
                        info["desktopName"] = line.strip()[5:]
                    elif line.startswith("Icon=") and not icon_name:
                        icon_name = line.strip()[5:]
                    elif line.startswith("Categories=") and not info["categories"]:
                        info["categories"] = line.strip()[11:]
                    elif line.startswith("X-AppImage-Version=") and not info["version"]:
                        info["version"] = line.strip()[19:]
        candidates = []
        diricon = os.path.join(root, ".DirIcon")
        if os.path.exists(diricon):
            candidates.append(os.path.realpath(diricon))
        if icon_name:
            for ext in ("png", "svg"):
                candidates += glob.glob(os.path.join(root, f"{icon_name}.{ext}"))
                candidates += glob.glob(os.path.join(root, "usr/share/icons/**", f"{icon_name}.{ext}"), recursive=True)
        for cand in candidates:
            if os.path.isfile(cand) and os.path.getsize(cand) > 0:
                ext = ".svg" if cand.endswith(".svg") else ".png"
                os.makedirs(ICON_DIR, exist_ok=True)
                dest = os.path.join(ICON_DIR, f"dsd-appimage-{app_id}{ext}")
                shutil.copyfile(cand, dest)
                info["icon"] = dest
                break
    except Exception:
        pass
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return info


def write_desktop(record):
    os.makedirs(DESKTOP_DIR, exist_ok=True)
    path = os.path.join(DESKTOP_DIR, f"dsd-appimage-{record['id']}.desktop")
    lines = [
        "[Desktop Entry]",
        "Type=Application",
        f"Name={record['name']}",
        f"Exec=\"{record['file']}\" %U",
        "Terminal=false",
        "X-AppImage-Managed=dankSoftwareDepot",
    ]
    if record.get("icon"):
        lines.append(f"Icon={record['icon']}")
    if record.get("categories"):
        lines.append(f"Categories={record['categories']}")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return path


def install_from(source, name, repo="", tag="", size_hint=0):
    os.makedirs(APP_DIR, exist_ok=True)
    display = name or os.path.basename(source).replace(".AppImage", "").replace(".appimage", "")
    app_id = slugify(display)
    records = load_records()
    if any(r["id"] == app_id for r in records):
        emit({"event": "error", "message": "already installed", "id": app_id})
        return
    dest = os.path.join(APP_DIR, f"{display}.AppImage".replace("/", "-"))
    emit({"event": "start", "id": app_id, "name": display})
    if re.match(r"^https?://", source):
        download(source, dest, size_hint)
    else:
        src = os.path.expanduser(source)
        if not os.path.isfile(src):
            emit({"event": "error", "message": "file not found: " + src})
            return
        shutil.copyfile(src, dest)
    os.chmod(dest, os.stat(dest).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    meta = extract_metadata(dest, app_id)
    record = {
        "id": app_id,
        "name": display,
        "file": dest,
        "icon": meta.get("icon", ""),
        "categories": meta.get("categories", ""),
        "repo": repo,
        "tag": tag,
        "source": source if re.match(r"^https?://", source) else "file",
        "installedAt": int(time.time()),
        "sizeBytes": os.path.getsize(dest),
    }
    write_desktop(record)
    records.append(record)
    save_records(records)
    _invalidate_updates_cache()
    emit({"event": "done", "ok": True, "record": record})


def run_install_github(repo, name):
    try:
        release = resolve_github_release(repo)
    except Exception as exc:
        emit({"event": "error", "message": f"release lookup failed: {exc}"})
        return
    install_from(release["url"], name or repo.split("/")[-1], repo=repo,
                 tag=release["tag"], size_hint=release["size"])


def _invalidate_updates_cache():
    try:
        os.unlink(UPDATES_CACHE)
    except OSError:
        pass


def run_list():
    records = load_records()
    for record in records:
        if not os.path.isfile(record.get("file", "")):
            record["missing"] = True
        else:
            record["sizeBytes"] = os.path.getsize(record["file"])
            record["managed"] = True
    records = [r for r in records if not r.get("missing")]
    json.dump(records + scan_adhoc(records), sys.stdout)


def run_check_updates():
    try:
        st = os.stat(UPDATES_CACHE)
        if time.time() - st.st_mtime < 30 * 60:
            with open(UPDATES_CACHE) as f:
                print(f.read())
                return
    except OSError:
        pass
    updates = []
    records = load_records()
    for record in records + scan_adhoc(records):
        repo = record.get("repo")
        if not repo:
            continue
        try:
            release = resolve_github_release(repo)
        except Exception:
            continue
        if record.get("managed", True) and record.get("tag"):
            newer = release["tag"] and release["tag"] != record.get("tag")
        else:
            # Unmanaged file: compare the release date against the file mtime
            try:
                mtime = int(os.stat(record["file"]).st_mtime)
            except OSError:
                continue
            newer = release["published"] > 0 and release["published"] > mtime + 60
        if newer:
            updates.append({
                "id": record["id"],
                "name": record["name"],
                "current": record.get("tag") or "?",
                "latest": release["tag"],
                "url": release["url"],
                "size": release["size"],
            })
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(UPDATES_CACHE, "w") as f:
            json.dump(updates, f)
    except OSError:
        pass
    json.dump(updates, sys.stdout)


def run_update_ids(ids):
    records = load_records()
    adopted = False
    by_id = {r["id"]: r for r in records}
    for adhoc in scan_adhoc(records):
        if adhoc["id"] in ids and adhoc["id"] not in by_id:
            adhoc.pop("managed", None)
            adhoc["source"] = "adopted"
            records.append(adhoc)
            by_id[adhoc["id"]] = adhoc
            adopted = True
    if adopted:
        save_records(records)
    for app_id in ids:
        record = by_id.get(app_id)
        if not record or not record.get("repo"):
            emit({"event": "ai-done", "id": app_id, "ok": False, "message": "not updatable"})
            continue
        emit({"event": "ai-start", "id": app_id, "name": record["name"]})
        try:
            release = resolve_github_release(record["repo"])
            tmp = record["file"] + ".new"
            download(release["url"], tmp, release["size"])
            os.chmod(tmp, os.stat(tmp).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            os.replace(tmp, record["file"])
            record["tag"] = release["tag"]
            record["installedAt"] = int(time.time())
            record["sizeBytes"] = os.path.getsize(record["file"])
            save_records(records)
            emit({"event": "ai-done", "id": app_id, "ok": True, "tag": release["tag"]})
        except Exception as exc:
            emit({"event": "ai-done", "id": app_id, "ok": False, "message": str(exc)})
    _invalidate_updates_cache()
    emit({"event": "done", "ok": True})


def normalize_repo(value):
    """owner/repo from a GitHub URL or a plain owner/repo string; '' clears,
    None means the input is not recognizable."""
    value = (value or "").strip()
    if not value:
        return ""
    m = re.search(r"github\.com[/:]([^/\s]+)/([^/\s#?]+)", value)
    if m:
        return m.group(1) + "/" + re.sub(r"\.git$", "", m.group(2))
    if re.match(r"^[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+$", value):
        return re.sub(r"\.git$", "", value)
    return None


def run_set_repo(app_id, link):
    repo = normalize_repo(link)
    if repo is None:
        json.dump({"ok": False, "error": "not a GitHub link (use https://github.com/owner/project)"}, sys.stdout)
        return
    records = load_records()
    record = next((r for r in records if r["id"] == app_id), None)
    if not record:
        # Unmanaged file: adopt it into the records so the repo sticks
        for adhoc in scan_adhoc(records):
            if adhoc["id"] == app_id:
                adhoc.pop("managed", None)
                adhoc["source"] = "adopted"
                records.append(adhoc)
                record = adhoc
                break
    if not record:
        json.dump({"ok": False, "error": "app not found"}, sys.stdout)
        return
    latest = ""
    if repo:
        try:
            latest = resolve_github_release(repo)["tag"]
        except Exception as exc:
            json.dump({"ok": False, "error": str(exc)}, sys.stdout)
            return
    record["repo"] = repo
    if not repo:
        record["tag"] = ""
    save_records(records)
    _invalidate_updates_cache()
    json.dump({"ok": True, "repo": repo, "latestTag": latest}, sys.stdout)


def run_uninstall(app_id):
    records = load_records()
    keep = []
    removed = None
    for record in records:
        if record["id"] == app_id:
            removed = record
        else:
            keep.append(record)
    if not removed:
        for adhoc in scan_adhoc(records):
            if adhoc["id"] == app_id:
                removed = adhoc
                break
    if not removed:
        json.dump({"ok": False, "error": "not found"}, sys.stdout)
        return
    desktop = find_desktop_for(removed.get("file", "")) if removed.get("file") else None
    if desktop:
        try:
            os.unlink(desktop["path"])
        except OSError:
            pass
    for path in (removed.get("file"), removed.get("icon"),
                 os.path.join(DESKTOP_DIR, f"dsd-appimage-{app_id}.desktop")):
        try:
            if path:
                os.unlink(path)
        except OSError:
            pass
    save_records(keep)
    _invalidate_updates_cache()
    json.dump({"ok": True}, sys.stdout)


# ── Double-clicked AppImages ───────────────────────────────────────────────
# A file arriving from the file manager is a file and nothing else: no name,
# no version, and no telling whether it is a new app or a newer build of one
# that is already here. --inspect answers all three without installing
# anything, so the window can ask the right question instead of the generic
# one. --replace is the answer to the second question; --install is the first.

def _version_from_filename(path):
    """A version out of "Foo-1.2.3-x86_64.AppImage", when the image itself
    does not say. Architecture and build tags are not versions."""
    stem = re.sub(r"\.appimage$", "", os.path.basename(path), flags=re.I)
    for token in re.split(r"[-_]", stem):
        if re.fullmatch(r"v?\d+(\.\d+)+[a-z0-9.]*", token, flags=re.I):
            return token.lstrip("vV")
    return ""


def _match_installed(display, path, records):
    """The registered app this file is a build of, or None.

    Matched on the name inside the image rather than the file name: a
    download is called Foo-1.2.3-x86_64.AppImage and the app is called Foo,
    and the version in between is exactly what changes between builds.
    """
    wanted = {slugify(display)} if display else set()
    stem = re.sub(r"\.appimage$", "", os.path.basename(path), flags=re.I)
    wanted.add(slugify(stem))
    # Same file name minus the version tail: kdrive-3.6.5 → kdrive
    trimmed = re.split(r"[-_]v?\d", stem)[0]
    if trimmed:
        wanted.add(slugify(trimmed))
    wanted.discard("")
    for record in records:
        if record.get("id") in wanted or slugify(record.get("name", "")) in wanted:
            return record
    return None


def run_inspect(path):
    src = os.path.expanduser(path)
    if not os.path.isfile(src):
        json.dump({"ok": False, "error": "file not found: " + src}, sys.stdout)
        return

    # --appimage-extract has to run the image, and a fresh download is not
    # executable. Inspecting is not installing, so the user's own file is
    # left exactly as it was found and a temporary copy is run instead.
    probe, tmpdir = src, ""
    if not os.access(src, os.X_OK):
        tmpdir = tempfile.mkdtemp(prefix="dsd-inspect-")
        probe = os.path.join(tmpdir, os.path.basename(src))
        try:
            shutil.copyfile(src, probe)
            os.chmod(probe, os.stat(probe).st_mode | stat.S_IXUSR)
        except OSError as exc:
            shutil.rmtree(tmpdir, ignore_errors=True)
            json.dump({"ok": False, "error": str(exc)}, sys.stdout)
            return

    stem = re.sub(r"\.appimage$", "", os.path.basename(src), flags=re.I)
    try:
        meta = extract_metadata(probe, slugify(stem) or "unknown")
    finally:
        if tmpdir:
            shutil.rmtree(tmpdir, ignore_errors=True)

    display = meta.get("desktopName") or stem
    records = load_records()
    match = _match_installed(meta.get("desktopName", ""), src, records + scan_adhoc(records))
    json.dump({
        "ok": True,
        "path": src,
        "name": display,
        "version": meta.get("version") or _version_from_filename(src),
        "icon": meta.get("icon", ""),
        "sizeBytes": os.path.getsize(src),
        "executable": os.access(src, os.X_OK),
        "installed": match,
    }, sys.stdout)


def run_replace(app_id, path):
    """Put a newer build in place of a registered AppImage, keeping its id,
    its update source and the desktop entry that already points at it."""
    src = os.path.expanduser(path)
    if not os.path.isfile(src):
        emit({"event": "error", "message": "file not found: " + src})
        return
    records = load_records()
    record = next((r for r in records if r["id"] == app_id), None)
    adopted = False
    if record is None:
        record = next((r for r in scan_adhoc(records) if r["id"] == app_id), None)
        adopted = record is not None
    if record is None:
        emit({"event": "error", "message": "not registered: " + app_id})
        return

    dest = record.get("file") or os.path.join(APP_DIR, f"{record['name']}.AppImage")
    emit({"event": "start", "id": app_id, "name": record.get("name", app_id)})
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    # Written beside the target and moved into place: a copy that fails
    # halfway must not leave a working app truncated
    staging = dest + ".dsd-new"
    try:
        shutil.copyfile(src, staging)
        os.chmod(staging, os.stat(staging).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        os.replace(staging, dest)
    except OSError as exc:
        try:
            os.unlink(staging)
        except OSError:
            pass
        emit({"event": "error", "message": str(exc)})
        return

    meta = extract_metadata(dest, app_id)
    record["file"] = dest
    record["sizeBytes"] = os.path.getsize(dest)
    record["installedAt"] = int(time.time())
    record["source"] = "file"
    # A build installed by hand is no longer the one the release feed knows
    record["tag"] = ""
    if meta.get("icon"):
        record["icon"] = meta["icon"]
    if meta.get("categories"):
        record["categories"] = meta["categories"]
    write_desktop(record)
    if adopted:
        records.append(record)
    save_records(records)
    _invalidate_updates_cache()
    emit({"event": "done", "ok": True, "record": record})


# ── Default handler for .appimage files ────────────────────────────────────
# xdg-mime writes the same file, but it is not everywhere, it cannot unset a
# default, and it would drop the other handlers on a shared line. This edits
# only our own name in and out of mimeapps.list.

APPIMAGE_MIME_TYPES = ("application/vnd.appimage", "application/x-iso9660-appimage")
DEPOT_DESKTOP = "com.danklinux.dankSoftwareDepot.desktop"
MIMEAPPS = os.path.expanduser("~/.config/mimeapps.list")


def _read_mimeapps():
    import configparser
    parser = configparser.RawConfigParser()
    parser.optionxform = str  # MIME types are case-sensitive keys, not options
    try:
        parser.read(MIMEAPPS, encoding="utf-8")
    except (OSError, configparser.Error):
        pass
    return parser


def _entries(value):
    return [e for e in (value or "").split(";") if e]


def run_handler_status():
    parser = _read_mimeapps()
    defaults = {}
    for mime in APPIMAGE_MIME_TYPES:
        current = _entries(parser.get("Default Applications", mime, fallback=""))
        defaults[mime] = current[0] if current else ""
    json.dump({
        "isDefault": all(defaults[m] == DEPOT_DESKTOP for m in APPIMAGE_MIME_TYPES),
        "defaults": defaults,
        "entryPresent": os.path.isfile(os.path.expanduser(
            "~/.local/share/applications/" + DEPOT_DESKTOP)),
    }, sys.stdout)


def _write_mimeapps(parser):
    os.makedirs(os.path.dirname(MIMEAPPS), exist_ok=True)
    tmp = MIMEAPPS + ".dsd-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        parser.write(f, space_around_delimiters=False)
    os.replace(tmp, MIMEAPPS)


def run_handler_set():
    parser = _read_mimeapps()
    for section in ("Default Applications", "Added Associations"):
        if not parser.has_section(section):
            parser.add_section(section)
        for mime in APPIMAGE_MIME_TYPES:
            current = _entries(parser.get(section, mime, fallback=""))
            if DEPOT_DESKTOP in current:
                current.remove(DEPOT_DESKTOP)
            parser.set(section, mime, ";".join([DEPOT_DESKTOP] + current) + ";")
    _write_mimeapps(parser)
    json.dump({"ok": True}, sys.stdout)


def run_handler_clear():
    parser = _read_mimeapps()
    for section in ("Default Applications", "Added Associations"):
        if not parser.has_section(section):
            continue
        for mime in APPIMAGE_MIME_TYPES:
            current = _entries(parser.get(section, mime, fallback=""))
            if DEPOT_DESKTOP not in current:
                continue
            # Only our own name goes: another handler on the same line was
            # someone else's choice and stays theirs
            current.remove(DEPOT_DESKTOP)
            if current:
                parser.set(section, mime, ";".join(current) + ";")
            else:
                parser.remove_option(section, mime)
    _write_mimeapps(parser)
    json.dump({"ok": True}, sys.stdout)


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    mode = args[0]
    if mode == "--index":
        run_index()
    elif mode == "--install" and len(args) >= 2:
        install_from(args[1], args[2] if len(args) >= 3 else "")
    elif mode == "--install-github" and len(args) >= 2:
        run_install_github(args[1], args[2] if len(args) >= 3 else "")
    elif mode == "--list":
        run_list()
    elif mode == "--check-updates":
        run_check_updates()
    elif mode == "--update-ids" and len(args) >= 2:
        run_update_ids(args[1:])
    elif mode == "--set-repo" and len(args) >= 2:
        run_set_repo(args[1], args[2] if len(args) >= 3 else "")
    elif mode == "--inspect" and len(args) >= 2:
        run_inspect(args[1])
    elif mode == "--replace" and len(args) >= 3:
        run_replace(args[1], args[2])
    elif mode == "--handler-status":
        run_handler_status()
    elif mode == "--handler-set":
        run_handler_set()
    elif mode == "--handler-clear":
        run_handler_clear()
    elif mode == "--uninstall" and len(args) >= 2:
        run_uninstall(args[1])
    else:
        print(__doc__, file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
