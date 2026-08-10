#!/usr/bin/env python3
"""Flatpak update engine for the dankSoftwareDepot DMS plugin.

Runs flatpak updates through libflatpak (like GNOME Software does), emitting
newline-delimited JSON progress events on stdout:

  {"event":"plan","ops":[{"ref":"app/...","appid":"...","action":"update","downloadBytes":N,"installation":"system"}],"totalDownloadBytes":N}
  {"event":"op-start","ref":"app/...","appid":"..."}
  {"event":"progress","ref":"app/...","appid":"...","percent":42,"bytesTransferred":N,"status":"..."}
  {"event":"op-done","ref":"app/...","appid":"..."}
  {"event":"op-error","ref":"app/...","appid":"...","message":"..."}
  {"event":"done","ok":true,"failed":[]}

Usage:  flatpak_helper.py update [appid ...]
        (no appids = update everything that has an update available)
        flatpak_helper.py install <remote> <appid>
        (install from the named remote, system installation when the remote
        exists there, user installation otherwise; same event stream)

System-installation updates authenticate through polkit (the DMS agent shows
the prompt); no terminal is ever involved. SIGTERM/SIGINT abort the
transaction cleanly.
"""

import json
import signal
import sys

import interp


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


# PyGObject and the Flatpak typelib are distribution packages living in the
# system interpreter; a pyenv shim or an activated virtualenv cannot see them.
# Hand the command over rather than die, and if it still fails, say so inside
# the protocol — an import that kills the process ends the stream before its
# first event, and the caller can only report that everything failed.
interp.ensure("gi")

try:
    import gi
    gi.require_version("Flatpak", "1.0")
    from gi.repository import Flatpak, Gio, GLib  # noqa: E402
except (ImportError, ValueError) as exc:
    emit({"event": "error",
          "message": "the Flatpak bindings could not be loaded by %s (%s)"
                     % (interp.describe(), exc)})
    emit({"event": "done", "ok": False, "failed": []})
    sys.exit(1)


def appid_of(ref_str):
    # ref format: app/org.example.App/x86_64/stable
    parts = ref_str.split("/")
    return parts[1] if len(parts) >= 2 else ref_str


class Runner:
    def __init__(self, wanted_ids):
        self.wanted = set(wanted_ids)
        self.cancellable = Gio.Cancellable()
        self.failed = []
        self.ops_meta = []

    def wants(self, ref):
        if not self.wanted:
            return True
        name = ref.get_name()
        # Match the app itself and its extensions (org.x.App.Locale etc.)
        return any(name == w or name.startswith(w + ".") for w in self.wanted)

    def collect(self, installation, label):
        try:
            updates = installation.list_installed_refs_for_update(self.cancellable)
        except GLib.Error as err:
            emit({"event": "warning", "message": f"{label}: {err.message}"})
            return []
        return [ref for ref in updates if self.wants(ref)]

    def run_transaction(self, installation, label, refs):
        if not refs:
            return
        txn = Flatpak.Transaction.new_for_installation(installation, self.cancellable)

        def on_ready(transaction):
            for op in transaction.get_operations():
                self.ops_meta.append({
                    "ref": op.get_ref(),
                    "appid": appid_of(op.get_ref()),
                    "action": "install" if op.get_operation_type() == Flatpak.TransactionOperationType.INSTALL else "update",
                    "downloadBytes": op.get_download_size(),
                    "installation": label,
                })
            emit({"event": "plan", "installation": label, "ops": self.ops_meta,
                  "totalDownloadBytes": sum(o["downloadBytes"] for o in self.ops_meta)})
            return True

        def on_new_operation(transaction, op, progress):
            ref = op.get_ref()
            emit({"event": "op-start", "ref": ref, "appid": appid_of(ref)})

            def on_changed(prog):
                emit({"event": "progress", "ref": ref, "appid": appid_of(ref),
                      "percent": prog.get_progress(),
                      "bytesTransferred": prog.get_bytes_transferred(),
                      "status": prog.get_status() or ""})

            progress.set_update_frequency(250)
            progress.connect("changed", on_changed)

        def on_operation_done(transaction, op, commit, result):
            ref = op.get_ref()
            emit({"event": "op-done", "ref": ref, "appid": appid_of(ref)})

        def on_operation_error(transaction, op, error, details):
            ref = op.get_ref()
            self.failed.append(appid_of(ref))
            emit({"event": "op-error", "ref": ref, "appid": appid_of(ref),
                  "message": error.message if error else "unknown error"})
            return True  # continue with remaining operations

        txn.connect("ready", on_ready)
        txn.connect("new-operation", on_new_operation)
        txn.connect("operation-done", on_operation_done)
        txn.connect("operation-error", on_operation_error)

        for ref in refs:
            try:
                txn.add_update(ref.format_ref(), None, None)
            except GLib.Error as err:
                emit({"event": "warning", "message": f"{ref.format_ref()}: {err.message}"})

        try:
            txn.run(self.cancellable)
        except GLib.Error as err:
            if err.matches(Gio.io_error_quark(), Gio.IOErrorEnum.CANCELLED):
                emit({"event": "done", "ok": False, "cancelled": True, "failed": self.failed})
                sys.exit(130)
            emit({"event": "error", "message": err.message})
            self.failed.append(label)

    def run(self):
        signal.signal(signal.SIGTERM, lambda *_: self.cancellable.cancel())
        signal.signal(signal.SIGINT, lambda *_: self.cancellable.cancel())

        system = Flatpak.Installation.new_system(self.cancellable)
        user = Flatpak.Installation.new_user(self.cancellable)
        plans = [(system, "system"), (user, "user")]
        collected = [(inst, label, self.collect(inst, label)) for inst, label in plans]

        if not any(refs for _, _, refs in collected):
            emit({"event": "done", "ok": True, "failed": [], "nothingToDo": True})
            return

        for inst, label, refs in collected:
            if self.cancellable.is_cancelled():
                break
            self.run_transaction(inst, label, refs)

        emit({"event": "done", "ok": not self.failed, "failed": self.failed})


def run_install(remote, appid):
    """Install one app from a remote, emitting the same NDJSON event stream
    as updates. Uses the system installation when it has the remote (polkit
    authenticates), the user installation otherwise."""
    runner = Runner([])
    signal.signal(signal.SIGTERM, lambda *_: runner.cancellable.cancel())
    signal.signal(signal.SIGINT, lambda *_: runner.cancellable.cancel())

    installation = None
    label = ""
    for candidate, name in ((Flatpak.Installation.new_system(runner.cancellable), "system"),
                            (Flatpak.Installation.new_user(runner.cancellable), "user")):
        try:
            remotes = [r.get_name() for r in candidate.list_remotes(runner.cancellable)]
        except GLib.Error:
            continue
        if remote in remotes:
            installation = candidate
            label = name
            break
    if installation is None:
        emit({"event": "error", "message": f"remote '{remote}' not found"})
        sys.exit(1)

    txn = Flatpak.Transaction.new_for_installation(installation, runner.cancellable)

    def on_ready(transaction):
        ops = [{
            "ref": op.get_ref(),
            "appid": appid_of(op.get_ref()),
            "action": "install",
            "downloadBytes": op.get_download_size(),
            "installation": label,
        } for op in transaction.get_operations()]
        emit({"event": "plan", "installation": label, "ops": ops,
              "totalDownloadBytes": sum(o["downloadBytes"] for o in ops)})
        return True

    def on_new_operation(transaction, op, progress):
        ref = op.get_ref()
        emit({"event": "op-start", "ref": ref, "appid": appid_of(ref)})

        def on_changed(prog):
            emit({"event": "progress", "ref": ref, "appid": appid_of(ref),
                  "percent": prog.get_progress(),
                  "bytesTransferred": prog.get_bytes_transferred(),
                  "status": prog.get_status() or ""})

        progress.set_update_frequency(250)
        progress.connect("changed", on_changed)

    def on_operation_done(transaction, op, commit, result):
        emit({"event": "op-done", "ref": op.get_ref(), "appid": appid_of(op.get_ref())})

    def on_operation_error(transaction, op, error, details):
        runner.failed.append(appid_of(op.get_ref()))
        emit({"event": "op-error", "ref": op.get_ref(), "appid": appid_of(op.get_ref()),
              "message": error.message if error else "unknown error"})
        return False

    txn.connect("ready", on_ready)
    txn.connect("new-operation", on_new_operation)
    txn.connect("operation-done", on_operation_done)
    txn.connect("operation-error", on_operation_error)

    arch = Flatpak.get_default_arch()
    try:
        # Fast path: flathub apps nearly always live on the stable branch
        txn.add_install(remote, f"app/{appid}/{arch}/stable", None)
    except GLib.Error:
        # Resolve the branch from the remote's published refs
        try:
            refs = installation.list_remote_refs_sync(remote, runner.cancellable)
            match = next((r for r in refs
                          if r.get_kind() == Flatpak.RefKind.APP
                          and r.get_name() == appid and r.get_arch() == arch), None)
            if match is None:
                raise GLib.Error(f"'{appid}' not found in remote '{remote}'")
            txn.add_install(remote, match.format_ref(), None)
        except GLib.Error as err:
            emit({"event": "error", "message": err.message})
            sys.exit(1)

    try:
        txn.run(runner.cancellable)
    except GLib.Error as err:
        if err.matches(Gio.io_error_quark(), Gio.IOErrorEnum.CANCELLED):
            emit({"event": "done", "ok": False, "cancelled": True, "failed": runner.failed})
            sys.exit(130)
        emit({"event": "error", "message": err.message})
        runner.failed.append(appid)

    emit({"event": "done", "ok": not runner.failed, "failed": runner.failed})
    sys.exit(0 if not runner.failed else 1)


def run_eol_check():
    """List installed refs marked end-of-life (or eol-rebased) by their remote."""
    import json as jsonmod
    out = []
    for installation in (Flatpak.Installation.new_system(None), Flatpak.Installation.new_user(None)):
        try:
            refs = installation.list_installed_refs(None)
        except Exception:
            continue
        for ref in refs:
            try:
                eol = ref.get_eol()
                rebase = ref.get_eol_rebase()
            except Exception:
                continue
            if eol or rebase:
                out.append({
                    "ref": ref.format_ref(),
                    "id": ref.get_name(),
                    "kind": "app" if ref.get_kind() == Flatpak.RefKind.APP else "runtime",
                    "appName": ref.get_appdata_name() or ref.get_name(),
                    "eol": eol or "",
                    "eolRebase": rebase or "",
                })
    print(jsonmod.dumps(out), flush=True)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "eol":
        run_eol_check()
        return
    if len(sys.argv) >= 4 and sys.argv[1] == "install":
        run_install(sys.argv[2], sys.argv[3])
        return
    if len(sys.argv) < 2 or sys.argv[1] != "update":
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    Runner(sys.argv[2:]).run()


if __name__ == "__main__":
    main()
