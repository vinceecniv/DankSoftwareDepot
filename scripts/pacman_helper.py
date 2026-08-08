#!/usr/bin/env python3
"""pacman/libalpm transactions through pyalpm, emitting the NDJSON event
protocol documented in PROTOCOL.md — the Arch counterpart of
rpm_helper.py.

Usage: pacman_helper.py <install|remove|upgrade|plan|selftest> <name>...

Transactions need root (run via pkexec); `plan` resolves against the
existing sync databases and works unprivileged, and `selftest` only
reports whether the bindings are present. `downgrade` is not offered:
pacman keeps no version history in its repositories (that is the Arch
Linux Archive's job, out of scope here). Official repositories only —
AUR packages are never touched.
"""
import json
import re
import sys


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


# Missing bindings must be reported inside the protocol: an import that kills
# the process ends the stream before its first event, and the caller can only
# guess that every package failed. See the same guard in rpm_helper.py.
try:
    import pyalpm
except ImportError as exc:
    emit({"event": "error", "message": "pyalpm is not installed (%s)" % exc})
    emit({"event": "done", "ok": False, "failed": sys.argv[2:]})
    sys.exit(1)


def init_handle():
    """Configured handle: pycman parses pacman.conf when available (it
    ships with pyalpm); otherwise register the sync dbs that exist on
    disk — enough for resolving and for reads."""
    try:
        import pycman.config
        return pycman.config.init_with_config("/etc/pacman.conf")
    except Exception:
        import glob
        import os
        handle = pyalpm.Handle("/", "/var/lib/pacman")
        for path in glob.glob("/var/lib/pacman/sync/*.db"):
            handle.register_syncdb(os.path.basename(path)[:-3], 0)
        return handle


def _pkg_of_file(filename, plan_names):
    base = filename.split("/")[-1]
    for name in sorted(plan_names, key=len, reverse=True):
        if base.startswith(name + "-"):
            return name
    return ""


class Callbacks:
    def __init__(self, handle):
        self.plan_names = set()
        self.totals = {}
        self.transferred = {}
        self.pct = {}
        self.phase_started = set()
        self.dl_done = set()
        self.inst_done = set()
        self.install_pct = {}
        self.index = 0
        self.total_ops = 1
        self.removing = False
        handle.dlcb = self.dl
        handle.progresscb = self.progress

    def dl(self, filename, transferred, total):
        name = _pkg_of_file(filename, self.plan_names)
        if not name:
            return
        if name not in self.phase_started:
            self.phase_started.add(name)
            emit({"event": "op-start", "name": name, "phase": "download",
                  "bytesTotal": int(total or 0)})
        if total:
            self.totals[name] = total
        self.transferred[name] = transferred
        agg = int(sum(self.transferred.values()))
        pct = int(transferred * 100 / total) if total else 0
        if self.pct.get(name) != pct:
            self.pct[name] = pct
            emit({"event": "progress", "name": name, "phase": "download",
                  "percent": pct, "bytesTransferred": int(transferred),
                  "bytesTotal": int(total or 0), "totalTransferred": agg})
        if total and transferred >= total and name not in self.dl_done:
            self.dl_done.add(name)
            emit({"event": "op-done", "name": name, "phase": "download",
                  "totalTransferred": agg})

    def progress(self, target, percent, howmany, current):
        if not target:
            return
        self.total_ops = max(self.total_ops, howmany)
        phase = "remove" if self.removing else "install"
        key = (target, current)
        if key not in self.install_pct:
            self.install_pct[key] = -1
            self.index = current
            emit({"event": "op-start", "name": target, "phase": phase,
                  "index": current, "total": howmany})
        if percent != self.install_pct[key]:
            self.install_pct[key] = percent
            emit({"event": "progress", "name": target, "phase": phase,
                  "percent": max(0, min(100, percent))})
        if percent >= 100 and key not in self.inst_done:
            self.inst_done.add(key)
            emit({"event": "op-done", "name": target, "phase": phase})


def find_sync_pkg(handle, name):
    for db in handle.get_syncdbs():
        pkg = db.get_pkg(name)
        if pkg is not None:
            return pkg
    return None


def run(action, specs, dry_run=False):
    handle = init_handle()
    callbacks = Callbacks(handle)
    localdb = handle.get_localdb()

    transaction = handle.init_transaction()
    try:
        for spec in specs:
            name = spec.partition("=")[0]
            if action == "remove":
                pkg = localdb.get_pkg(name)
                if pkg is None:
                    emit({"event": "error", "message": f"package not installed: {name}"})
                    emit({"event": "done", "ok": False, "failed": list(specs)})
                    return 1
                transaction.remove_pkg(pkg)
            else:
                pkg = find_sync_pkg(handle, name)
                if pkg is None:
                    emit({"event": "error", "message": f"package not found: {name}"})
                    emit({"event": "done", "ok": False, "failed": list(specs)})
                    return 1
                transaction.add_pkg(pkg)
        transaction.prepare()

        ops = []
        total_download = 0
        for pkg in transaction.to_add:
            installed = localdb.get_pkg(pkg.name)
            act = "Install" if installed is None else ("Upgrade" if pyalpm.vercmp(pkg.version, installed.version) >= 0 else "Downgrade")
            down = int(pkg.download_size or 0)
            total_download += down
            callbacks.plan_names.add(pkg.name)
            ops.append({"name": pkg.name, "evr": pkg.version, "action": act,
                        "downloadBytes": down, "installBytes": int(pkg.isize or 0)})
        disk_delta = sum(o["installBytes"] for o in ops)
        for pkg in transaction.to_remove:
            ops.append({"name": pkg.name, "evr": pkg.version, "action": "Remove",
                        "downloadBytes": 0, "installBytes": int(pkg.isize or 0)})
            disk_delta -= int(pkg.isize or 0)
        callbacks.removing = bool(transaction.to_remove) and not transaction.to_add
        if not ops:
            emit({"event": "done", "ok": True, "failed": [], "nothingToDo": True})
            return 0
        emit({"event": "plan", "ops": ops, "totalDownloadBytes": total_download,
              "installDeltaBytes": disk_delta})
        if dry_run:
            emit({"event": "done", "ok": True, "failed": []})
            return 0
        transaction.commit()
    except pyalpm.error as exc:
        emit({"event": "error", "message": str(exc)})
        emit({"event": "done", "ok": False, "failed": list(specs)})
        return 1
    finally:
        try:
            transaction.release()
        except pyalpm.error:
            pass
    emit({"event": "done", "ok": True, "failed": []})
    return 0


def main():
    # Reaching this point means the bindings imported: the answer selftest exists for
    if len(sys.argv) == 2 and sys.argv[1] == "selftest":
        emit({"event": "done", "ok": True, "failed": []})
        return 0
    # `plan <action> …` resolves without root and without changing anything
    argv = sys.argv[1:]
    dry_run = bool(argv) and argv[0] == "plan"
    if dry_run:
        argv = argv[1:]
    if len(argv) < 2 or argv[0] not in ("install", "remove", "upgrade"):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        return run(argv[0], argv[1:], dry_run)
    except Exception as exc:
        emit({"event": "error", "message": str(exc)})
        emit({"event": "done", "ok": False, "failed": argv[1:]})
        return 1


if __name__ == "__main__":
    sys.exit(main())
