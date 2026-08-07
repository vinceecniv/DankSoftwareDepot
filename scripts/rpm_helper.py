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

Transactions need root — run via pkexec. The `plan` action only resolves
against the system cache and prints the plan; it works unprivileged and
exists for testing and dry runs.

Usage: rpm_helper.py <install|remove|upgrade|downgrade|plan> <spec>...

This event protocol is deliberately package-manager-agnostic: an apt or
pacman helper implementing the same events would slot into the same UI.
"""
import json
import sys

import libdnf5


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


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

    def add_new_download(self, user_data, description, total_to_download):
        if self.quiet:
            if not self._announced_repos:
                self._announced_repos = True
                emit({"event": "status", "message": "repos"})
            return None
        self._next_key += 1
        name = _name_of(description or "", self.plan_names)
        self._downloads[self._next_key] = {"name": name, "total": total_to_download, "pct": -1}
        emit({"event": "op-start", "name": name, "phase": "download",
              "bytesTotal": int(total_to_download or 0)})
        return self._next_key

    def progress(self, user_cb_data, total_to_download, downloaded):
        info = self._downloads.get(user_cb_data)
        if not info:
            return 0
        total = total_to_download or info["total"] or 0
        pct = int(downloaded * 100 / total) if total else 0
        if pct != info["pct"]:
            info["pct"] = pct
            emit({"event": "progress", "name": info["name"], "phase": "download",
                  "percent": pct, "bytesTransferred": int(downloaded),
                  "bytesTotal": int(total)})
        return 0

    def end(self, user_cb_data, status, msg):
        info = self._downloads.pop(user_cb_data, None)
        if not info:
            return 0
        if status == libdnf5.repo.DownloadCallbacks.TransferStatus_ERROR:
            emit({"event": "op-error", "name": info["name"], "phase": "download",
                  "message": msg or "download failed"})
        else:
            emit({"event": "op-done", "name": info["name"], "phase": "download"})
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


def _action_string(tp):
    try:
        return libdnf5.transaction.transaction_item_action_to_string(tp.get_action())
    except Exception:
        return str(tp.get_action())


def run(action, specs):
    base = libdnf5.base.Base()
    base.load_config()
    if action == "plan":
        # Unprivileged dry resolve against the existing system cache
        try:
            base.get_config().get_cacheonly_option().set("all")
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
        "plan": goal.add_install,
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
            downloads.plan_names.add(pkg.get_name())
        ops.append(entry)
    if not ops:
        emit({"event": "done", "ok": True, "failed": [], "nothingToDo": True})
        return 0
    emit({"event": "plan", "ops": ops, "totalDownloadBytes": total_download})
    if action == "plan":
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


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("install", "remove", "upgrade", "downgrade", "plan"):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        return run(sys.argv[1], sys.argv[2:])
    except Exception as exc:  # any library error must still end the stream cleanly
        emit({"event": "error", "message": str(exc)})
        emit({"event": "done", "ok": False, "failed": sys.argv[2:]})
        return 1


if __name__ == "__main__":
    sys.exit(main())
