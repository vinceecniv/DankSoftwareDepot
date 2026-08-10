#!/usr/bin/env python3
"""apt/dpkg transactions through python-apt, emitting the NDJSON event
protocol documented in PROTOCOL.md — the Debian counterpart of
rpm_helper.py.

Usage: apt_helper.py <install|remove|upgrade|downgrade|plan|selftest> <spec>...

Specs are package names; `downgrade` (and pinned installs) accept the apt
form `name=version`. Transactions need root (run via pkexec); `plan` only
resolves against the existing package lists and works unprivileged, and
`selftest` only reports whether the bindings are present.

Protocol notes specific to this backend:
- dpkg reports overall transaction percent, not per-package percent; the
  install phase derives an approximate per-package percent from it.
- apt has no separate metadata-refresh inside a transaction (that is
  `apt update`, the update daemon's job), so no "status: repos" event.
"""
import json
import os
import sys


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


# Missing bindings must be reported inside the protocol: an import that kills
# the process ends the stream before its first event, and the caller can only
# guess that every package failed. See the same guard in rpm_helper.py.
import interp

interp.ensure("apt")

try:
    import apt
    import apt.progress.base
except ImportError as exc:
    # Names the interpreter: "not installed" is a claim about the system,
    # and this is only ever a fact about one process
    emit({"event": "error",
          "message": "python3-apt cannot be imported by %s (%s)"
                     % (interp.describe(), exc)})
    emit({"event": "done", "ok": False, "failed": sys.argv[2:]})
    sys.exit(1)


class FetchProgress(apt.progress.base.AcquireProgress):
    """Download phase: per-item start/progress/done plus the aggregate
    transferred counter the UI derives its overall bar from."""

    def __init__(self):
        super().__init__()
        self._pct = {}

    @staticmethod
    def _item_name(item):
        return (item.shortdesc or item.description or "").split(":")[0]

    def fetch(self, item):
        emit({"event": "op-start", "name": self._item_name(item), "phase": "download",
              "bytesTotal": int(item.owner.filesize or 0)})

    def done(self, item):
        emit({"event": "op-done", "name": self._item_name(item), "phase": "download",
              "totalTransferred": int(self.current_bytes or 0)})

    def fail(self, item):
        emit({"event": "op-error", "name": self._item_name(item), "phase": "download",
              "message": getattr(item.owner, "error_text", "") or "download failed"})

    def pulse(self, owner):
        super().pulse(owner)
        for worker in owner.workers:
            if not worker.current_item:
                continue
            name = self._item_name(worker.current_item)
            total = worker.total_size or 0
            pct = int(worker.current_size * 100 / total) if total else 0
            if self._pct.get(name) != pct:
                self._pct[name] = pct
                emit({"event": "progress", "name": name, "phase": "download",
                      "percent": pct, "bytesTransferred": int(worker.current_size or 0),
                      "bytesTotal": int(total),
                      "totalTransferred": int(self.current_bytes or 0)})
        return True


class InstallProgress(apt.progress.base.InstallProgress):
    """Install/remove phase. dpkg's percent is transaction-wide; a
    per-package percent is derived from it so the events match the
    protocol's semantics."""

    def __init__(self, planned_names, removing):
        super().__init__()
        self.planned = set(planned_names)
        self.total_ops = max(1, len(self.planned))
        self.phase = "remove" if removing else "install"
        self.index = 0
        self.current = None
        self._pct = -1

    def fork(self):
        pid = os.fork()
        if pid == 0:
            # dpkg's own chatter belongs on stderr — stdout is the event stream
            os.dup2(2, 1)
        return pid

    def status_change(self, pkg, percent, status):
        name = (pkg or "").split(":")[0]
        if name not in self.planned:
            name = ""
        if name and name != self.current:
            if self.current:
                emit({"event": "op-done", "name": self.current, "phase": self.phase})
            self.current = name
            self.index = min(self.index + 1, self.total_ops)
            self._pct = -1
            emit({"event": "op-start", "name": name, "phase": self.phase,
                  "index": self.index, "total": self.total_ops})
        if not self.current:
            return
        # overall dpkg percent -> approximate percent of the current package
        part = percent / 100 * self.total_ops - (self.index - 1)
        pct = max(0, min(100, int(part * 100)))
        if pct != self._pct:
            self._pct = pct
            emit({"event": "progress", "name": self.current, "phase": self.phase,
                  "percent": pct})

    def error(self, pkg, errormsg):
        emit({"event": "op-error", "name": (pkg or "").split(":")[0] or "?",
              "phase": self.phase, "message": errormsg})

    def finish_update(self):
        if self.current:
            emit({"event": "op-done", "name": self.current, "phase": self.phase})


def _split_spec(spec):
    if "=" in spec:
        name, _, version = spec.partition("=")
        return name, version
    return spec, None


def run(action, specs, dry_run=False):
    cache = apt.Cache()
    for spec in specs:
        name, version = _split_spec(spec)
        if name not in cache:
            emit({"event": "error", "message": f"package not found: {name}"})
            emit({"event": "done", "ok": False, "failed": list(specs)})
            return 1
        pkg = cache[name]
        if action == "remove":
            pkg.mark_delete()
            continue
        if version is not None:
            candidate = None
            for v in pkg.versions:
                if v.version == version:
                    candidate = v
                    break
            if candidate is None:
                emit({"event": "error", "message": f"version not found: {spec}"})
                emit({"event": "done", "ok": False, "failed": list(specs)})
                return 1
            pkg.candidate = candidate
            pkg.mark_install()
        elif action == "upgrade":
            pkg.mark_upgrade()
        else:
            pkg.mark_install()

    changes = cache.get_changes()
    ops = []
    total_download = 0
    removing_only = True
    for pkg in changes:
        if pkg.marked_delete:
            act = "Remove"
            down = 0
            size = -(pkg.installed.installed_size if pkg.installed else 0)
        else:
            removing_only = False
            act = "Downgrade" if pkg.marked_downgrade else ("Upgrade" if pkg.marked_upgrade else "Install")
            down = pkg.candidate.size if pkg.candidate else 0
            size = pkg.candidate.installed_size if pkg.candidate else 0
        total_download += down
        ops.append({
            "name": pkg.name,
            "evr": (pkg.candidate.version if pkg.candidate and not pkg.marked_delete else (pkg.installed.version if pkg.installed else "")),
            "action": act,
            "downloadBytes": int(down),
            "installBytes": int(size),
        })
    if not ops:
        emit({"event": "done", "ok": True, "failed": [], "nothingToDo": True})
        return 0
    disk_delta = sum(o["installBytes"] for o in ops)
    emit({"event": "plan", "ops": ops, "totalDownloadBytes": int(total_download),
          "installDeltaBytes": int(disk_delta)})
    if dry_run:
        emit({"event": "done", "ok": True, "failed": []})
        return 0

    try:
        cache.commit(FetchProgress(), InstallProgress([op["name"] for op in ops], removing_only))
    except Exception as exc:
        emit({"event": "error", "message": str(exc)})
        emit({"event": "done", "ok": False, "failed": list(specs)})
        return 1
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
    if len(argv) < 2 or argv[0] not in ("install", "remove", "upgrade", "downgrade"):
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
