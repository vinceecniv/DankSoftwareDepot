#!/usr/bin/env python3
"""Checks flatpak_helper.py against a stand-in for libflatpak.

The case that matters here cannot be produced on demand on a real machine:
libostree 2026.3 refuses to pull a delta whose decompressed size crosses a cap
it sets too low, which needs an app whose delta happens to be large enough. A
stand-in can fail on cue, and can then be asked whether the second attempt
really disabled static deltas.

The stub is a package on PYTHONPATH rather than a patched import, because the
helper re-execs itself looking for an interpreter that can import gi (see
interp.ensure) and only a real, importable module stops it.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HELPER = Path(__file__).resolve().parent / "flatpak_helper.py"

DELTA_ERROR = ("While pulling app/one.ablaze.floorp/x86_64/stable from remote flathub: "
               "Decompressed delta part exceeds configured limit of 67386875 bytes")

GI_STUB = '''
import json, os

SCENARIO = json.loads(os.environ["FLATPAK_STUB"])
TRACE = os.environ["FLATPAK_TRACE"]


def _trace(what):
    with open(TRACE, "a") as fh:
        fh.write(what + "\\n")


def require_version(name, version):
    pass


class _Error(Exception):
    def __init__(self, message=""):
        super().__init__(message)
        self.message = message

    def matches(self, quark, code):
        return False


class _GLib:
    Error = _Error


class _Cancellable:
    def is_cancelled(self):
        return False

    def cancel(self):
        pass


class _Gio:
    Cancellable = _Cancellable

    @staticmethod
    def io_error_quark():
        return 1

    class IOErrorEnum:
        CANCELLED = 19
        NO_SPACE = 28


class _Ref:
    def __init__(self, name, branch="stable"):
        self._name = name
        self._branch = branch

    def get_name(self):
        return self._name

    def format_ref(self):
        return "app/%s/x86_64/%s" % (self._name, self._branch)


class _Op:
    def __init__(self, ref):
        self._ref = ref

    def get_ref(self):
        return self._ref

    def get_operation_type(self):
        return 1

    def get_download_size(self):
        return 50 * 1024 * 1024


class _Progress:
    def set_update_frequency(self, ms):
        pass

    def connect(self, signal, handler):
        pass

    def get_progress(self):
        return 100

    def get_bytes_transferred(self):
        return 1024

    def get_status(self):
        return "done"


class _Transaction:
    def __init__(self):
        self._refs = []
        self._handlers = {}
        self.no_deltas = False

    @staticmethod
    def new_for_installation(installation, cancellable):
        return _Transaction()

    def set_disable_static_deltas(self, value):
        _trace("disable_static_deltas %s" % value)
        self.no_deltas = value

    def connect(self, signal, handler):
        self._handlers[signal] = handler

    def add_update(self, ref, arches, commit):
        self._refs.append(ref)

    def add_install(self, remote, ref, arches):
        self._refs.append(ref)

    def get_operations(self):
        return [_Op(ref) for ref in self._refs]

    def run(self, cancellable):
        _trace("run deltas=%s refs=%s" % (not self.no_deltas, ",".join(self._refs)))
        self._handlers["ready"](self)
        for ref in self._refs:
            op = _Op(ref)
            self._handlers["new-operation"](self, op, _Progress())
            fails = ref in SCENARIO.get("failWithDelta", []) and not self.no_deltas
            if fails or ref in SCENARIO.get("failAlways", []):
                err = _Error(SCENARIO["message"] if fails else "no space left on device")
                # libflatpak stops the transaction when a handler answers
                # False, and raises out of run() — the install path relies on
                # that, the update path returns True and carries on.
                if self._handlers["operation-error"](self, op, err, 0) is False:
                    raise err
                continue
            _trace("installed %s" % ref)
            self._handlers["operation-done"](self, op, "commit", 0)


class _Installation:
    def __init__(self, label):
        self.label = label

    def list_installed_refs_for_update(self, cancellable):
        if self.label != "system":
            return []
        return [_Ref(name) for name in SCENARIO.get("updates", [])]

    def list_remotes(self, cancellable):
        class R:
            def get_name(self):
                return "flathub"
        return [R()] if self.label == "system" else []

    def list_remote_refs_sync(self, remote, cancellable):
        return []


class _Flatpak:
    Transaction = _Transaction

    class Installation:
        @staticmethod
        def new_system(cancellable):
            return _Installation("system")

        @staticmethod
        def new_user(cancellable):
            return _Installation("user")

    class TransactionOperationType:
        INSTALL = 0
        UPDATE = 1

    class RefKind:
        APP = 0

    @staticmethod
    def get_default_arch():
        return "x86_64"


class repository:
    Flatpak = _Flatpak
    Gio = _Gio
    GLib = _GLib
'''


def run(scenario, *args):
    with tempfile.TemporaryDirectory() as tmp:
        pkg = Path(tmp) / "gi"
        pkg.mkdir()
        (pkg / "__init__.py").write_text(GI_STUB)
        (pkg / "repository.py").write_text(
            "from gi import repository as _r\n"
            "Flatpak = _r.Flatpak\nGio = _r.Gio\nGLib = _r.GLib\n")
        trace = Path(tmp) / "trace"
        trace.write_text("")
        env = dict(os.environ)
        env["PYTHONPATH"] = tmp
        env["FLATPAK_STUB"] = json.dumps(scenario)
        env["FLATPAK_TRACE"] = str(trace)
        proc = subprocess.run([sys.executable, str(HELPER), *args],
                              capture_output=True, text=True, env=env, timeout=60)
        events = []
        for line in proc.stdout.splitlines():
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
        return events, trace.read_text().splitlines(), proc


def check(label, condition, detail=""):
    print(("  ok   " if condition else "  FAIL ") + label + (" — " + detail if detail and not condition else ""))
    return condition


def main():
    ok = True
    floorp = "app/one.ablaze.floorp/x86_64/stable"

    # The reported case: the pull trips libostree's delta cap.
    hit = {"updates": ["one.ablaze.floorp"], "failWithDelta": [floorp], "message": DELTA_ERROR}
    events, trace, proc = run(hit, "update")
    ok &= check("the first attempt uses deltas",
                trace[0].startswith("run deltas=True"), str(trace))
    ok &= check("the second attempt disables them",
                "disable_static_deltas True" in trace and
                any(l.startswith("run deltas=False") for l in trace), str(trace))
    ok &= check("and only the package that asked for it is retried",
                sum(1 for l in trace if l.startswith("run ")) == 2
                and trace[-2:] == ["run deltas=False refs=%s" % floorp, "installed %s" % floorp],
                str(trace))
    ok &= check("the cap is not reported as a failed update",
                not any(e.get("event") == "op-error" for e in events),
                json.dumps([e for e in events if e.get("event") == "op-error"]))
    ok &= check("but it is said out loud",
                any(e.get("event") == "warning" and "without static deltas" in e.get("message", "")
                    for e in events))
    done = [e for e in events if e.get("event") == "done"][-1]
    ok &= check("and the run ends clean", done.get("ok") is True and done.get("failed") == [],
                json.dumps(done))

    # A real failure is still a real failure, and is not retried.
    broken = {"updates": ["org.example.Thing"],
              "failAlways": ["app/org.example.Thing/x86_64/stable"], "message": DELTA_ERROR}
    events, trace, proc = run(broken, "update")
    ok &= check("an ordinary error is reported as one",
                any(e.get("event") == "op-error" for e in events))
    ok &= check("and is not retried without deltas",
                not any("disable_static_deltas" in l for l in trace), str(trace))
    done = [e for e in events if e.get("event") == "done"][-1]
    ok &= check("the run ends failed", done.get("ok") is False)

    # Installing runs into the same cap, and takes the same way around it.
    events, trace, proc = run(hit, "install", "flathub", "one.ablaze.floorp")
    ok &= check("install retries without deltas as well",
                "disable_static_deltas True" in trace
                and any(l.startswith("run deltas=False") for l in trace), str(trace))
    ok &= check("and gets there in the end",
                any(l == "installed %s" % floorp for l in trace), str(trace))
    ok &= check("without reporting a failed install",
                not any(e.get("event") == "op-error" for e in events)
                and proc.returncode == 0,
                str(proc.returncode) + " " + json.dumps([e for e in events if e.get("event") in ("op-error", "error")]))

    # A real install failure is still reported, once.
    events, trace, proc = run({"failAlways": ["app/org.example.Thing/x86_64/stable"],
                               "message": DELTA_ERROR},
                              "install", "flathub", "org.example.Thing")
    ok &= check("a real install failure is not retried",
                not any("disable_static_deltas" in l for l in trace), str(trace))
    ok &= check("and is reported", proc.returncode != 0
                and any(e.get("event") == "op-error" for e in events))

    # Nothing pending: no transaction, no retry.
    events, trace, proc = run({"updates": []}, "update")
    done = [e for e in events if e.get("event") == "done"][-1]
    ok &= check("an empty run says nothing to do", done.get("nothingToDo") is True, json.dumps(done))

    print("\n" + ("all checks passed" if ok else "FAILURES"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
