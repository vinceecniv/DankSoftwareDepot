#!/usr/bin/env python3
"""rpm transactions through libdnf5 (the library dnf5 itself uses), emitting
newline-delimited JSON progress events on stdout — the same protocol family
as flatpak_helper.py, so the QML side needs no output scraping:

  {"event":"status","message":"repos"}                       metadata refresh
  {"event":"plan","ops":[{"name","evr","action","downloadBytes","installBytes"}],
   "totalDownloadBytes":N}
  {"event":"op-start","name":...,"phase":"download"|"install"|"remove",
   "index":I,"total":T}                                      (index/total: install phase)
  {"event":"progress","name":...,"phase":...,"percent":P,
   "bytesTransferred":N,"bytesTotal":N}                      (bytes: download phase)
  {"event":"op-done","name":...,"phase":...}
  {"event":"script","name":...}                              scriptlet running
  {"event":"error","message":...}
  {"event":"done","ok":true|false,"failed":[names]}

Transactions need root — run via pkexec. Prefixing any action with `plan`
resolves it against the system cache, prints the plan and stops: no root,
no changes, so a caller can show what a transaction would do before asking
for a password. `selftest` only reports whether the bindings are present,
so callers can ask before starting a transaction.

Usage: rpm_helper.py [plan] <install|remove|upgrade|downgrade> <spec>...
       rpm_helper.py install --copr <owner/project> <spec>...
       rpm_helper.py selftest

`--copr` enables that Copr project before resolving, so installing something
found in Copr is one transaction and one password rather than two. It is an
rpm-only option: Copr is a dnf-family thing and no other helper has an
equivalent.

This event protocol is deliberately package-manager-agnostic: an apt or
pacman helper implementing the same events would slot into the same UI.
"""
import json
import sys


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


# The Python bindings ship as their own package (python3-libdnf5) which a
# working dnf5 system does not necessarily carry. Dying on the import would
# end the stream before its first event, leaving the caller with nothing to
# report but "every package failed" — so answer in the protocol instead.
import interp

interp.ensure("libdnf5")

try:
    import libdnf5
except ImportError as exc:
    # Says which interpreter could not see it, because "not installed" is a
    # claim about the system and this is only ever a fact about one process
    emit({"event": "error",
          "message": "python3-libdnf5 cannot be imported by %s (%s)"
                     % (interp.describe(), exc)})
    emit({"event": "done", "ok": False, "failed": sys.argv[2:]})
    sys.exit(1)


def _name_of(description, plan_names):
    """Map a download description (nevra or url) onto a plan package name."""
    for name in sorted(plan_names, key=len, reverse=True):
        if description.startswith(name + "-"):
            return name
    return description


class DownloadProgress(libdnf5.repo.DownloadCallbacks):
    """Per-package download bytes. Repo metadata flows through the same
    callbacks; while `quiet` is set only a single status event is sent."""

    def __init__(self):
        super().__init__()
        self.quiet = True
        self.plan_names = set()
        self._downloads = {}
        self._next_key = 0
        self._announced_repos = False
        # Aggregate over all (parallel) downloads: the UI derives its overall
        # bar from this so interleaved per-package events can't make it jump
        self._total_transferred = 0

    def add_new_download(self, user_data, description, total_to_download):
        if self.quiet:
            if not self._announced_repos:
                self._announced_repos = True
                emit({"event": "status", "message": "repos"})
            return None
        self._next_key += 1
        name = _name_of(description or "", self.plan_names)
        self._downloads[self._next_key] = {"name": name, "total": total_to_download,
                                           "pct": -1, "transferred": 0}
        emit({"event": "op-start", "name": name, "phase": "download",
              "bytesTotal": int(total_to_download or 0)})
        return self._next_key

    def progress(self, user_cb_data, total_to_download, downloaded):
        info = self._downloads.get(user_cb_data)
        if not info:
            return 0
        total = total_to_download or info["total"] or 0
        self._total_transferred += max(0, downloaded - info["transferred"])
        info["transferred"] = downloaded
        pct = int(downloaded * 100 / total) if total else 0
        if pct != info["pct"]:
            info["pct"] = pct
            emit({"event": "progress", "name": info["name"], "phase": "download",
                  "percent": pct, "bytesTransferred": int(downloaded),
                  "bytesTotal": int(total),
                  "totalTransferred": int(self._total_transferred)})
        return 0

    def end(self, user_cb_data, status, msg):
        info = self._downloads.pop(user_cb_data, None)
        if not info:
            return 0
        if status == libdnf5.repo.DownloadCallbacks.TransferStatus_ERROR:
            emit({"event": "op-error", "name": info["name"], "phase": "download",
                  "message": msg or "download failed"})
        else:
            if info["total"]:
                self._total_transferred += max(0, info["total"] - info["transferred"])
            emit({"event": "op-done", "name": info["name"], "phase": "download",
                  "totalTransferred": int(self._total_transferred)})
        return 0


class RpmProgress(libdnf5.rpm.TransactionCallbacks):
    """Per-package install/remove progress from the rpm transaction."""

    def __init__(self):
        super().__init__()
        self.total = 0
        self.index = 0
        self._current = None
        self._pct = -1

    @staticmethod
    def _pkg_name(item):
        try:
            return item.get_package().get_name()
        except Exception:
            return ""

    def before_begin(self, total):
        self.total = total

    def _start(self, item, phase):
        name = self._pkg_name(item)
        self.index += 1
        self._current = (name, phase)
        self._pct = -1
        emit({"event": "op-start", "name": name, "phase": phase,
              "index": self.index, "total": self.total})

    def _progress(self, item, amount, total, phase):
        name = self._pkg_name(item)
        pct = int(amount * 100 / total) if total else 0
        if pct != self._pct:
            self._pct = pct
            emit({"event": "progress", "name": name, "phase": phase, "percent": pct})

    def install_start(self, item, total):
        self._start(item, "install")

    def install_progress(self, item, amount, total):
        self._progress(item, amount, total, "install")

    def install_stop(self, item, amount, total):
        emit({"event": "op-done", "name": self._pkg_name(item), "phase": "install"})

    def uninstall_start(self, item, total):
        self._start(item, "remove")

    def uninstall_progress(self, item, amount, total):
        self._progress(item, amount, total, "remove")

    def uninstall_stop(self, item, amount, total):
        emit({"event": "op-done", "name": self._pkg_name(item), "phase": "remove"})

    def script_start(self, item, nevra, type):
        name = self._pkg_name(item)
        if name:
            emit({"event": "script", "name": name})

    def script_error(self, item, nevra, type, return_code):
        emit({"event": "warning",
              "message": f"scriptlet failed for {self._pkg_name(item)} (exit {return_code})"})

    def unpack_error(self, item):
        emit({"event": "op-error", "name": self._pkg_name(item), "phase": "install",
              "message": "unpack error"})


INBOUND_ACTIONS = ("Install", "Upgrade", "Downgrade", "Reinstall")
# What leaves the disk. "Replaced" is the outgoing half of an upgrade, so
# counting both sides gives the real space delta rather than the gross size
# of everything arriving.
OUTBOUND_ACTIONS = ("Remove", "Replaced", "Obsoleted")


def _action_string(tp):
    try:
        return libdnf5.transaction.transaction_item_action_to_string(tp.get_action())
    except Exception:
        return str(tp.get_action())


def enable_copr(project):
    """Add a Copr repository as part of the transaction that needs it.

    Search can offer a package from a Copr nobody has enabled yet, and the
    repository is the smaller half of installing it. Doing it here keeps the
    whole thing to one authorisation: a second pkexec for the repository
    would ask for a password twice for what the user did once.
    """
    import subprocess

    emit({"event": "status", "message": "repos"})
    result = subprocess.run(["dnf", "-y", "copr", "enable", project],
                            capture_output=True, text=True)
    if result.returncode != 0:
        reason = (result.stderr or result.stdout or "").strip().splitlines()
        emit({"event": "error",
              "message": "could not enable the Copr %s: %s"
                         % (project, reason[-1] if reason else "unknown error")})
        return False
    return True


def run(action, specs, dry_run=False, copr=""):
    if copr and not dry_run and not enable_copr(copr):
        emit({"event": "done", "ok": False, "failed": list(specs)})
        return 1
    base = libdnf5.base.Base()
    base.load_config()
    if dry_run:
        # Unprivileged dry resolve against the existing system cache
        try:
            base.get_config().get_cacheonly_option().set("all")
        except Exception:
            pass
    else:
        # Force a metadata refresh (dnf5 --refresh equivalent): the update
        # was discovered by the daemon's refreshed check, but this cache
        # follows metadata_expire — 48h for Coprs — and a transaction
        # against the stale view ends in a silent "nothing to do" (a Copr
        # build the daemon offered simply doesn't exist here yet).
        try:
            base.get_config().get_metadata_expire_option().set("0")
        except Exception:
            pass
    base.setup()

    downloads = DownloadProgress()
    base.set_download_callbacks(libdnf5.repo.DownloadCallbacksUniquePtr(downloads))
    downloads.__disown__()

    sack = base.get_repo_sack()
    sack.create_repos_from_system_configuration()
    if hasattr(sack, "load_repos"):
        sack.load_repos()
    else:
        sack.update_and_load_enabled_repos(True)

    goal = libdnf5.base.Goal(base)
    add = {
        "install": goal.add_install,
        "remove": goal.add_remove,
        "upgrade": goal.add_upgrade,
        "downgrade": goal.add_downgrade,
    }[action]
    for spec in specs:
        add(spec)

    transaction = goal.resolve()
    if transaction.get_problems() != libdnf5.base.GoalProblem_NO_PROBLEM:
        emit({"event": "error",
              "message": "; ".join(transaction.get_resolve_logs_as_strings()) or "resolution failed"})
        emit({"event": "done", "ok": False, "failed": list(specs)})
        return 1

    ops = []
    total_download = 0
    disk_delta = 0
    for tp in transaction.get_transaction_packages():
        pkg = tp.get_package()
        act = _action_string(tp)
        entry = {
            "name": pkg.get_name(),
            "evr": pkg.get_evr(),
            "action": act,
            "downloadBytes": pkg.get_download_size() if act in INBOUND_ACTIONS else 0,
            "installBytes": pkg.get_install_size(),
        }
        if act in INBOUND_ACTIONS:
            total_download += entry["downloadBytes"]
            disk_delta += entry["installBytes"]
            downloads.plan_names.add(pkg.get_name())
        elif act in OUTBOUND_ACTIONS:
            disk_delta -= entry["installBytes"]
        ops.append(entry)
    if not ops:
        emit({"event": "done", "ok": True, "failed": [], "nothingToDo": True})
        return 0
    emit({"event": "plan", "ops": ops, "totalDownloadBytes": total_download,
          "installDeltaBytes": disk_delta})
    if dry_run:
        emit({"event": "done", "ok": True, "failed": []})
        return 0

    downloads.quiet = False
    transaction.download()
    downloads.quiet = True

    rpm_cb = RpmProgress()
    transaction.set_callbacks(libdnf5.rpm.TransactionCallbacksUniquePtr(rpm_cb))
    rpm_cb.__disown__()
    transaction.set_description(" ".join(["dankSoftwareDepot", action] + list(specs))[:200])
    result = transaction.run()
    if result != libdnf5.base.Transaction.TransactionRunResult_SUCCESS:
        problems = list(transaction.get_transaction_problems())
        emit({"event": "error", "message": "; ".join(problems) or f"transaction failed ({result})"})
        emit({"event": "done", "ok": False, "failed": list(specs)})
        return 1
    emit({"event": "done", "ok": True, "failed": []})
    return 0


# ── Advisories ─────────────────────────────────────────────────────────────
# Fedora ships updateinfo alongside its packages: which update fixes a
# security hole, which is a bug fix, which is a new feature, and the CVE it
# closes. Without it every update looks equally urgent, which is another way
# of saying none of them do.

SEVERITY_RANK = {"critical": 4, "important": 3, "moderate": 2, "low": 1}
TYPE_RANK = {"security": 3, "bugfix": 2, "enhancement": 1}


def run_advisories(names):
    """{name: {type, severity, ids}} for the packages that have an advisory.

    Read-only and cache-only, so it needs no root and no network.
    """
    base = libdnf5.base.Base()
    base.load_config()
    try:
        base.get_config().get_cacheonly_option().set("all")
    except Exception:
        pass
    base.setup()
    sack = base.get_repo_sack()
    sack.create_repos_from_system_configuration()
    if hasattr(sack, "load_repos"):
        sack.load_repos()
    else:
        sack.update_and_load_enabled_repos(True)

    wanted = set(names)
    out = {}
    for adv in libdnf5.advisory.AdvisoryQuery(base):
        adv_type = (adv.get_type() or "").lower()
        severity = (adv.get_severity() or "").lower()
        ids = []
        try:
            ids = [r.get_id() for r in adv.get_references() if (r.get_type() or "").lower() == "cve"]
        except Exception:
            pass
        for collection in adv.get_collections():
            for pkg in collection.get_packages():
                name = pkg.get_name()
                if name not in wanted:
                    continue
                current = out.get(name)
                # Keep the most serious advisory a package appears in: one
                # security fix among five enhancements is what matters
                better = (TYPE_RANK.get(adv_type, 0), SEVERITY_RANK.get(severity, 0))
                if current is None or better > (TYPE_RANK.get(current["type"], 0),
                                                SEVERITY_RANK.get(current["severity"], 0)):
                    out[name] = {"type": adv_type, "severity": severity, "ids": ids}
                elif current["type"] == adv_type:
                    for cve in ids:
                        if cve not in current["ids"]:
                            current["ids"].append(cve)
    emit({"event": "advisories", "packages": out})
    emit({"event": "done", "ok": True, "failed": []})
    return 0


ACTIONS = ("install", "remove", "upgrade", "downgrade")


def main():
    # Reaching this point means the bindings imported: the answer selftest exists for
    if len(sys.argv) == 2 and sys.argv[1] == "selftest":
        emit({"event": "done", "ok": True, "failed": []})
        return 0
    # `plan <action> <spec>...` resolves without touching anything, so a
    # preview costs no root: the helper runs under pkexec, which prompts at
    # process start — asking for a password before showing what it is for
    # would be the wrong way round.
    argv = sys.argv[1:]
    if argv and argv[0] == "advisories":
        try:
            return run_advisories(argv[1:])
        except Exception as exc:
            emit({"event": "error", "message": str(exc)})
            emit({"event": "done", "ok": False, "failed": []})
            return 1
    dry_run = bool(argv) and argv[0] == "plan"
    if dry_run:
        argv = argv[1:]
    copr = ""
    if len(argv) > 2 and argv[1] == "--copr":
        copr = argv[2]
        argv = [argv[0]] + argv[3:]
    if len(argv) < 2 or argv[0] not in ACTIONS or (copr and argv[0] != "install"):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        return run(argv[0], argv[1:], dry_run, copr)
    except Exception as exc:  # any library error must still end the stream cleanly
        emit({"event": "error", "message": str(exc)})
        emit({"event": "done", "ok": False, "failed": argv[1:]})
        return 1


if __name__ == "__main__":
    sys.exit(main())
