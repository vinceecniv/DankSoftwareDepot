#!/usr/bin/env python3
"""Checks pacman_helper.py against a stand-in for pyalpm.

This runs on a machine that has no pacman and no pyalpm, which is the point:
the Arch path is the one nobody here can try by hand, and it is where #13
happened — the transaction resolved against sync databases that nothing had
refreshed, so a run of eight updates reinstalled the eight versions already
installed and then reported that none of them had arrived.

The stand-in is a module on PYTHONPATH rather than a patched import, because
the helper re-execs itself looking for an interpreter that can import pyalpm
(see interp.ensure) and only a real, importable module stops it.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HELPER = Path(__file__).resolve().parent / "pacman_helper.py"

# name -> (installed version, version in the repositories before a refresh,
#          version in the repositories after one)
STUB = '''
import json, os

error = Exception
SCENARIO = json.loads(os.environ["PACMAN_STUB"])
TRACE = os.environ["PACMAN_TRACE"]


def _trace(what):
    with open(TRACE, "a") as fh:
        fh.write(what + "\\n")


def vercmp(a, b):
    return (a > b) - (a < b)


class Pkg:
    def __init__(self, name, version):
        self.name = name
        self.version = version
        self.download_size = 1000
        self.isize = 2000


class SyncDB:
    name = "extra"

    def __init__(self):
        self.refreshed = False

    def update(self, force):
        if SCENARIO.get("refreshFails"):
            raise error("mirror unreachable")
        _trace("refresh")
        self.refreshed = True
        return True

    def get_pkg(self, name):
        entry = SCENARIO["packages"].get(name)
        if entry is None:
            return None
        version = entry["after"] if self.refreshed else entry["before"]
        _trace("resolve %s -> %s" % (name, version))
        return Pkg(name, version)


class LocalDB:
    def get_pkg(self, name):
        entry = SCENARIO["packages"].get(name)
        if entry is None or entry.get("installed") is None:
            return None
        return Pkg(name, entry["installed"])


class Transaction:
    def __init__(self):
        self.to_add = []
        self.to_remove = []

    def add_pkg(self, pkg):
        _trace("add %s-%s" % (pkg.name, pkg.version))
        self.to_add.append(pkg)

    def remove_pkg(self, pkg):
        self.to_remove.append(pkg)

    def prepare(self):
        pass

    def commit(self):
        _trace("commit")

    def release(self):
        pass


class Handle:
    def __init__(self, root, dbpath):
        self._sync = [SyncDB()]

    def register_syncdb(self, name, level):
        pass

    def get_syncdbs(self):
        return self._sync

    def get_localdb(self):
        return LocalDB()

    def init_transaction(self, **kwargs):
        return Transaction()

    # The helper installs progress callbacks when they exist; it checks with
    # hasattr, so leaving them off is a supported shape.
'''


def run(scenario, *args):
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "pyalpm.py").write_text(STUB)
        trace = Path(tmp) / "trace"
        trace.write_text("")
        env = dict(os.environ)
        env["PYTHONPATH"] = tmp
        env["PACMAN_STUB"] = json.dumps(scenario)
        env["PACMAN_TRACE"] = str(trace)
        proc = subprocess.run([sys.executable, str(HELPER), *args],
                              capture_output=True, text=True, env=env, timeout=60)
        events = []
        for line in proc.stdout.splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
        return events, trace.read_text().splitlines(), proc


def event(events, kind):
    for item in events:
        if item.get("event") == kind:
            return item
    return None


def check(label, condition, detail=""):
    print(("  ok   " if condition else "  FAIL ") + label + (" — " + detail if detail and not condition else ""))
    return condition


def main():
    ok = True

    # The reported case: the repositories have a newer build, the sync
    # database on disk does not know it yet.
    behind = {"packages": {"dolphin": {"installed": "26.08.0-2",
                                       "before": "26.08.0-2",
                                       "after": "26.08.1-1"}}}
    events, trace, proc = run(behind, "upgrade", "dolphin")
    ok &= check("refresh happens before the package is resolved",
                trace[:2] == ["refresh", "resolve dolphin -> 26.08.1-1"], str(trace))
    plan = event(events, "plan")
    ok &= check("the plan carries the version the refresh revealed",
                plan is not None and plan["ops"][0]["evr"] == "26.08.1-1", json.dumps(plan))
    ok &= check("and it is an upgrade, not a reinstall",
                plan is not None and plan["ops"][0]["action"] == "Upgrade")
    ok &= check("the transaction is committed", "commit" in trace)

    # Already at the version the repositories offer: adding it anyway is the
    # "is up to date -- reinstalling" line from the report.
    current = {"packages": {"libdeflate": {"installed": "1.25-1",
                                           "before": "1.25-1",
                                           "after": "1.25-1"}}}
    events, trace, proc = run(current, "upgrade", "libdeflate")
    ok &= check("a package already at the repository version is not added",
                not any(line.startswith("add ") for line in trace), str(trace))
    done = event(events, "done")
    ok &= check("and the run says there was nothing to do",
                done is not None and done.get("ok") is True and done.get("nothingToDo") is True,
                json.dumps(done))

    # An unreachable mirror is not a reason to refuse the transaction: what
    # the database already knows about still gets installed.
    partly = {"refreshFails": True,
              "packages": {"dolphin": {"installed": "26.08.0-2",
                                       "before": "26.08.1-1",
                                       "after": "26.08.2-1"}}}
    events, trace, proc = run(partly, "upgrade", "dolphin")
    ok &= check("a failed refresh still installs what the stale database has",
                "commit" in trace and "add dolphin-26.08.1-1" in trace, str(trace))
    ok &= check("and says why it could not refresh",
                any(e.get("event") == "error" and "refresh" in e.get("message", "") for e in events))

    # And when the stale database has nothing newer, the run has nothing it
    # can do — which must not read as "updated". The reason is the failed
    # refresh, and it has to reach the caller, because the check that follows
    # will otherwise fail every row with nothing to show for it.
    stuck = dict(behind)
    stuck["refreshFails"] = True
    events, trace, proc = run(stuck, "upgrade", "dolphin")
    ok &= check("a stale database with nothing newer adds nothing",
                not any(line.startswith("add ") for line in trace), str(trace))
    ok &= check("and the refresh failure is the reason on the wire",
                any(e.get("event") == "error" and "mirror unreachable" in e.get("message", "") for e in events))

    # `plan` is unprivileged: writing the sync databases needs root.
    events, trace, proc = run(behind, "plan", "upgrade", "dolphin")
    ok &= check("plan does not try to refresh", "refresh" not in trace, str(trace))
    ok &= check("and does not commit", "commit" not in trace)

    # Installing is the other side of the same staleness: a package added to
    # the repositories today is not in yesterday's database at all.
    fresh = {"packages": {"newthing": {"installed": None,
                                       "before": None,
                                       "after": "1.0-1"}}}
    events, trace, proc = run(fresh, "install", "newthing")
    ok &= check("install resolves against the refreshed database",
                any(line == "add newthing-1.0-1" for line in trace), str(trace))

    print("\n" + ("all checks passed" if ok else "FAILURES"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
