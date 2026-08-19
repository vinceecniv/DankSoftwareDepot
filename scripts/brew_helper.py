#!/usr/bin/env python3
"""Homebrew support for the dankSoftwareDepot DMS plugin.

Homebrew is not another distribution backend. dnf, apt and pacman are
mutually exclusive — a machine has one — and pkg_backend.py picks between
them. Brew sits *beside* whichever of those a machine has, the way Flatpak and
AppImages do, so it is handled here as its own kind of software rather than as
a fourth entry in that list.

Two properties shape everything below:

* It needs no privileges. There is no pkexec, no polkit, no daemon pass. The
  helper runs as the user and that is the whole story.
* It reports no machine-readable progress. `brew upgrade` prints prose. So the
  events emitted here are per-formula steps, not bytes — the same honesty the
  firmware phase settles for, for the same reason. A formula with no bottle is
  compiled from source and can take a very long time; nothing can be promised
  about how long, and nothing is.

Modes:

    brew_helper.py --state                 what is installed and what is outdated
    brew_helper.py --state --refresh       ...after `brew update`, throttled
    brew_helper.py --search <term>         formulae matching a word
    brew_helper.py --info <name>           one formula, in detail
    brew_helper.py --upgrade [name ...]    upgrade those, or everything outdated
    brew_helper.py --install <name>        install one formula

Searching goes through brew itself rather than through the API. The index at
formulae.brew.sh is a 30 MB document, and brew already has it: it downloaded
it to answer its own questions. Asking `brew search` costs nothing and stays
correct as brew's copy is refreshed.

Linux is the reason a search needs filtering at all. Homebrew grew up on macOS
and its core still carries formulae that cannot run here — a formula is taken
as usable when it has a Linux bottle, or when it at least does not declare a
macOS requirement, which is the difference between "builds here" and "will
refuse".

`--state` prints one JSON document. `--upgrade` prints newline-delimited
events, in the shape the other helpers use:

    {"event":"plan","ops":[{"name":"jq","from":"1.7","to":"1.8"}]}
    {"event":"op-start","name":"jq"}
    {"event":"op-done","name":"jq"}
    {"event":"op-error","name":"jq","message":"..."}
    {"event":"done","ok":true,"failed":[]}
"""

import json
import os
import re
import subprocess
import sys
import time

CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "dankSoftwareDepot")
REFRESH_STAMP = os.path.join(CACHE_DIR, "brew-refreshed")
# `brew update` fetches from git; it is the slow half of knowing whether
# anything is outdated, and nothing about the answer changes minute to minute.
REFRESH_MAX_AGE = 6 * 3600
STATE_TIMEOUT = 60
REFRESH_TIMEOUT = 180


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def brew_path():
    """Where brew is, or "" — checked before anything else asks it a question.

    The standard Linux prefix is not on a login shell's PATH in every setup,
    so the two documented locations are looked at directly rather than being
    left to chance.
    """
    from shutil import which
    found = which("brew")
    if found:
        return found
    for candidate in ("/home/linuxbrew/.linuxbrew/bin/brew",
                      os.path.expanduser("~/.linuxbrew/bin/brew")):
        if os.access(candidate, os.X_OK):
            return candidate
    return ""


def run(args, timeout):
    """brew's stdout, or None when it could not be asked."""
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                                env={**os.environ, "HOMEBREW_NO_AUTO_UPDATE": "1",
                                     "HOMEBREW_NO_ENV_HINTS": "1"})
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout


def refresh_due():
    try:
        return time.time() - os.stat(REFRESH_STAMP).st_mtime > REFRESH_MAX_AGE
    except OSError:
        return True


def mark_refreshed():
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        with open(REFRESH_STAMP, "w") as f:
            f.write(str(int(time.time())))
    except OSError:
        pass


def parse_outdated(raw):
    """`brew outdated --json=v2` into rows this plugin's UI understands.

    Casks are read too, and are always empty on Linux — the format has the key
    either way, and a helper that only works on one platform because it
    assumed the other one's absence is a helper that breaks the day it stops
    being absent.
    """
    try:
        doc = json.loads(raw or "{}")
    except ValueError:
        return []
    rows = []
    for kind in ("formulae", "casks"):
        for entry in doc.get(kind) or []:
            name = entry.get("name") or ""
            if not name:
                continue
            installed = entry.get("installed_versions") or []
            rows.append({
                # brew names a formula from a third-party tap in full —
                # "dsd/test/dsdtest" — and that is what `brew upgrade` has to
                # be given. It is not what anyone wants to read in a list, and
                # `brew list` reports the short name for the same formula, so
                # both travel: one to act on, one to show.
                "name": name,
                "displayName": name.rsplit("/", 1)[-1],
                "kind": "cask" if kind == "casks" else "formula",
                "fromVersion": installed[-1] if installed else "",
                "toVersion": entry.get("current_version") or "",
                # brew's own word for held, and it means the same thing: the
                # user asked for this one to stay where it is
                "pinned": bool(entry.get("pinned")),
            })
    rows.sort(key=lambda r: r["name"])
    return rows


def parse_installed(raw):
    """`brew list --versions` — "name 1.2 1.3" per line, newest last."""
    rows = []
    for line in (raw or "").splitlines():
        parts = line.split()
        if len(parts) >= 2:
            rows.append({"name": parts[0], "version": parts[-1]})
    return rows


def run_state(refresh):
    brew = brew_path()
    if not brew:
        print(json.dumps({"supported": False, "outdated": [], "installed": []}))
        return

    refreshed = False
    if refresh and refresh_due():
        # A failure here is not fatal: `outdated` still answers from the
        # formula index already on disk, it is simply answering about
        # yesterday. Saying so is better than saying nothing.
        if run([brew, "update", "--quiet"], REFRESH_TIMEOUT) is not None:
            mark_refreshed()
            refreshed = True

    outdated = parse_outdated(run([brew, "outdated", "--json=v2"], STATE_TIMEOUT))
    installed = parse_installed(run([brew, "list", "--versions"], STATE_TIMEOUT))
    print(json.dumps({
        "supported": True,
        "prefix": (run([brew, "--prefix"], STATE_TIMEOUT) or "").strip(),
        "refreshed": refreshed,
        "outdated": outdated,
        "installed": installed,
    }))


# ── Searching and describing ─────────────────────────────────────────────────

def _usable_on_linux(info):
    """Whether this formula can run here at all.

    A Linux bottle is the plain yes. Without one it can still be built from
    source — unless it says it needs macOS, which is the plain no.
    """
    files = (((info.get("bottle") or {}).get("stable") or {}).get("files") or {})
    if any("linux" in key for key in files):
        return True
    return not any((req.get("name") or "") == "macos" for req in (info.get("requirements") or []))


def _installs_30d(info):
    """How many installs the last thirty days saw, as brew's own analytics
    report it — the same kind of number the Flathub rows carry."""
    counts = (((info.get("analytics") or {}).get("install") or {}).get("30d") or {})
    name = info.get("name") or ""
    if name in counts:
        return counts[name]
    # The key carries the invocation, so a formula usually installed with a
    # flag appears as "name --HEAD"; take the plain one, else the largest
    plain = [v for k, v in counts.items() if k.split()[0] == name]
    return max(plain) if plain else 0


def _describe(info, installed_names):
    return {
        "name": info.get("name") or "",
        "desc": info.get("desc") or "",
        "homepage": info.get("homepage") or "",
        "license": info.get("license") or "",
        "version": ((info.get("versions") or {}).get("stable") or ""),
        "installs30d": _installs_30d(info),
        "linux": _usable_on_linux(info),
        "deprecated": bool(info.get("deprecated")) or bool(info.get("disabled")),
        "installed": (info.get("name") or "") in installed_names,
    }


def _info_documents(brew, names):
    """`brew info --json=v2` for a list of names, as formula documents."""
    if not names:
        return []
    raw = run([brew, "info", "--json=v2", "--formula"] + names, STATE_TIMEOUT)
    try:
        return (json.loads(raw or "{}").get("formulae") or [])
    except ValueError:
        return []


def run_search(term, limit=40):
    brew = brew_path()
    if not brew or not (term or "").strip():
        print(json.dumps({"supported": bool(brew), "results": []}))
        return
    raw = run([brew, "search", "--formula", term], STATE_TIMEOUT) or ""
    names = [line.strip() for line in raw.splitlines()
             if line.strip() and not line.startswith("==>") and "/" not in line]
    installed = {row["name"] for row in parse_installed(run([brew, "list", "--versions"], STATE_TIMEOUT))}
    results = [_describe(doc, installed) for doc in _info_documents(brew, names[:limit])]
    # Unusable here is worth showing rather than hiding — "this exists but not
    # for Linux" is an answer — but not worth showing first
    results.sort(key=lambda r: (not r["linux"], r["deprecated"], -r["installs30d"], r["name"]))
    print(json.dumps({
        "supported": True,
        "term": term,
        "truncated": len(names) > limit,
        "results": results,
    }))


def run_info(name):
    brew = brew_path()
    if not brew:
        print(json.dumps({"supported": False}))
        return
    installed = {row["name"] for row in parse_installed(run([brew, "list", "--versions"], STATE_TIMEOUT))}
    docs = _info_documents(brew, [name])
    if not docs:
        print(json.dumps({"supported": True, "found": False, "name": name}))
        return
    out = _describe(docs[0], installed)
    out.update({"supported": True, "found": True,
                "dependencies": (docs[0].get("dependencies") or [])[:12]})
    print(json.dumps(out))


# ── Upgrading ────────────────────────────────────────────────────────────────
# brew announces what it is about to do in prose, and these are the two lines
# that name a formula. Anything else it prints is ignored rather than guessed
# at: a wrong "now installing X" is worse than no line at all.
UPGRADING = re.compile(r"^==> Upgrading (\S+)")
# brew 6 opens with "==> Would upgrade 1 outdated package" and closes with
# "==> Upgraded ..."; brew 4 opened with "==> Upgrading 2 outdated packages:",
# which is the same shape as a formula line. Neither is a formula, and the
# guard below — a name must be one this run planned — is what tells them apart
# without having to know which brew is installed.
POURING = re.compile(r"^==> Pouring (\S+?)-")


def run_upgrade(names):
    brew = brew_path()
    if not brew:
        emit({"event": "error", "message": "Homebrew is not installed"})
        emit({"event": "done", "ok": False, "failed": names})
        return

    planned = names
    if not planned:
        planned = [row["name"] for row in
                   parse_outdated(run([brew, "outdated", "--json=v2"], STATE_TIMEOUT))
                   if not row["pinned"]]
    if not planned:
        emit({"event": "plan", "ops": []})
        emit({"event": "done", "ok": True, "failed": []})
        return

    emit({"event": "plan", "ops": [{"name": n} for n in planned]})

    remaining = list(planned)
    current = None
    tail = []

    def finish(ok):
        nonlocal current
        if current is None:
            return
        if ok:
            emit({"event": "op-done", "name": current})
        current = None

    process = subprocess.Popen(
        [brew, "upgrade"] + planned,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
        env={**os.environ, "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1",
             "HOMEBREW_NO_COLOR": "1"})

    for line in process.stdout:
        line = line.rstrip("\n")
        tail.append(line)
        del tail[:-40]
        match = UPGRADING.match(line) or POURING.match(line)
        if not match:
            continue
        token = match.group(1)
        # brew prints the versioned name when pouring a bottle; the plan holds
        # the plain one, and the row is keyed on that. Anything that does not
        # resolve to a formula this run planned is not a formula: the first
        # line brew prints is "==> Upgrading 2 outdated packages:", which is
        # the same shape and announced a package called 2.
        name = next((n for n in planned if token == n or token.startswith(n + "-")), None)
        if name is None or name == current:
            continue
        finish(True)
        current = name
        if name in remaining:
            remaining.remove(name)
        emit({"event": "op-start", "name": name})

    code = process.wait()
    # Read before finish() clears it: the one in flight when brew gave up is
    # the one the user most needs named, and it was being dropped
    unfinished = current
    finish(code == 0)

    if code == 0:
        emit({"event": "done", "ok": True, "failed": []})
        return
    # Whatever it was, brew said it in the last few lines. Everything the run
    # never reached is reported as failed rather than silently dropped.
    message = "\n".join(t for t in tail[-8:] if t.strip())
    failed = ([unfinished] if unfinished else []) + remaining
    for name in failed:
        emit({"event": "op-error", "name": name, "message": message})
    emit({"event": "done", "ok": False, "failed": failed})


def run_install(name):
    """One formula, through the same event stream an upgrade uses.

    Installing and upgrading are the same shape of work to brew and to the
    window watching it, so they are the same shape of report — a plan, a start,
    an end, and brew's own words when it goes wrong.
    """
    brew = brew_path()
    if not brew:
        emit({"event": "error", "message": "Homebrew is not installed"})
        emit({"event": "done", "ok": False, "failed": [name]})
        return

    emit({"event": "plan", "ops": [{"name": name}]})
    emit({"event": "op-start", "name": name})
    tail = []
    process = subprocess.Popen(
        [brew, "install", "--formula", name],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
        env={**os.environ, "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1",
             "HOMEBREW_NO_COLOR": "1"})
    for line in process.stdout:
        tail.append(line.rstrip("\n"))
        del tail[:-40]
    if process.wait() == 0:
        emit({"event": "op-done", "name": name})
        emit({"event": "done", "ok": True, "failed": []})
        return
    emit({"event": "op-error", "name": name,
          "message": "\n".join(t for t in tail[-8:] if t.strip())})
    emit({"event": "done", "ok": False, "failed": [name]})


def main():
    args = sys.argv[1:]
    if args and args[0] == "--state":
        run_state("--refresh" in args)
        return
    if args and args[0] == "--search":
        run_search(" ".join(args[1:]).strip())
        return
    if args and args[0] == "--info" and len(args) >= 2:
        run_info(args[1])
        return
    if args and args[0] == "--upgrade":
        run_upgrade([a for a in args[1:] if not a.startswith("--")])
        return
    if args and args[0] == "--install" and len(args) >= 2:
        run_install(args[1])
        return
    print(json.dumps({"error": "usage: brew_helper.py --state [--refresh] | --search <term> | --info <name> | --upgrade [name ...] | --install <name>"}))


if __name__ == "__main__":
    main()
