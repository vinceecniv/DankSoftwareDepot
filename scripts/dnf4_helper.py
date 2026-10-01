#!/usr/bin/env python3
"""rpm transactions through dnf 4, for the systems that have no dnf5.

RHEL, CentOS Stream and their rebuilds ship dnf 4 and nothing else: there is
no python3-libdnf5 to install, in the distribution or in EPEL (#27). This
helper speaks exactly the protocol rpm_helper.py does — the same events, the
same arguments, the same `plan`, `selftest`, `advisories` and `--copr` — so
the window cannot tell which one answered. rpm_helper.py hands over to it
when libdnf5 will not import and dnf will; nothing calls it directly.

Usage: dnf4_helper.py [plan] <install|remove|upgrade|downgrade> <spec>...
       dnf4_helper.py install --copr <owner/project> <spec>...
       dnf4_helper.py advisories <name>...
       dnf4_helper.py selftest
"""
import json
import sys


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


import interp

interp.ensure("dnf")

try:
    import dnf
    import dnf.callback
    import dnf.exceptions
    import dnf.transaction
except ImportError as exc:
    emit({"event": "error",
          "message": "python3-dnf cannot be imported by %s (%s)"
                     % (interp.describe(), exc)})
    emit({"event": "done", "ok": False, "failed": sys.argv[2:]})
    sys.exit(1)


def _name_of(description, plan_names):
    for name in sorted(plan_names, key=len, reverse=True):
        if description.startswith(name + "-"):
            return name
    return description


class DownloadProgress(dnf.callback.DownloadProgress):
    """Per-package download bytes. Repository metadata comes through the same
    callback while `quiet` is set, and is reported once as a status."""

    def __init__(self):
        super().__init__()
        self.quiet = True
        self.plan_names = set()
        self._announced_repos = False
        self._seen = {}
        self._total_transferred = 0

    def _name(self, payload):
        """The package a payload carries, or "" for repository metadata —
        which dnf 4 can fetch in the middle of the package downloads, and
        which is not a row anyone is waiting on."""
        pkg = getattr(payload, "pkg", None)
        if pkg is not None:
            return pkg.name
        name = _name_of(str(payload), self.plan_names)
        return name if name in self.plan_names else ""

    def start(self, total_files, total_size, total_drpms=0):
        if self.quiet and not self._announced_repos:
            self._announced_repos = True
            emit({"event": "status", "message": "repos"})

    def progress(self, payload, done):
        name = "" if self.quiet else self._name(payload)
        if not name:
            return
        total = int(getattr(payload, "download_size", 0) or 0)
        info = self._seen.get(name)
        if info is None:
            info = self._seen[name] = {"pct": -1, "transferred": 0}
            emit({"event": "op-start", "name": name, "phase": "download", "bytesTotal": total})
        self._total_transferred += max(0, done - info["transferred"])
        info["transferred"] = done
        pct = int(done * 100 / total) if total else 0
        if pct != info["pct"]:
            info["pct"] = pct
            emit({"event": "progress", "name": name, "phase": "download",
                  "percent": pct, "bytesTransferred": int(done), "bytesTotal": total,
                  "totalTransferred": int(self._total_transferred)})

    def end(self, payload, status, msg):
        name = "" if self.quiet else self._name(payload)
        if not name:
            return
        info = self._seen.pop(name, {"transferred": 0})
        if status == dnf.callback.STATUS_FAILED:
            emit({"event": "op-error", "name": name, "phase": "download",
                  "message": msg or "download failed"})
            return
        total = int(getattr(payload, "download_size", 0) or 0)
        if total:
            self._total_transferred += max(0, total - info["transferred"])
        emit({"event": "op-done", "name": name, "phase": "download",
              "totalTransferred": int(self._total_transferred)})


INSTALL_ACTIONS = (dnf.callback.PKG_INSTALL, dnf.callback.PKG_UPGRADE,
                   dnf.callback.PKG_DOWNGRADE, dnf.callback.PKG_REINSTALL)
REMOVE_ACTIONS = (dnf.callback.PKG_ERASE, dnf.callback.PKG_CLEANUP, dnf.callback.PKG_OBSOLETE)


class RpmProgress(dnf.callback.TransactionProgress):
    """Per-package install/remove progress. dnf 4 reports every step through
    one progress() call; the start and the end of each package are read from
    it the way dnf's own output does."""

    def __init__(self):
        super().__init__()
        self.index = 0
        self._current = None
        self._pct = -1

    def progress(self, package, action, ti_done, ti_total, ts_done, ts_total):
        if action in INSTALL_ACTIONS:
            phase = "install"
        elif action in REMOVE_ACTIONS:
            phase = "remove"
        else:
            return
        name = getattr(package, "name", None) or str(package)
        key = (name, phase)
        if key != self._current:
            if self._current is not None:
                emit({"event": "op-done", "name": self._current[0], "phase": self._current[1]})
            self._current = key
            self._pct = -1
            self.index += 1
            emit({"event": "op-start", "name": name, "phase": phase,
                  "index": self.index, "total": ts_total})
        pct = int(ti_done * 100 / ti_total) if ti_total else 0
        if pct != self._pct:
            self._pct = pct
            emit({"event": "progress", "name": name, "phase": phase, "percent": pct})

    def finish(self):
        if self._current is not None:
            emit({"event": "op-done", "name": self._current[0], "phase": self._current[1]})
            self._current = None

    def error(self, message):
        emit({"event": "warning", "message": str(message).strip()})


INBOUND = ("Install", "Upgrade", "Downgrade", "Reinstall")
OUTBOUND = ("Remove", "Replaced", "Obsoleted")


def _action_of(tsi):
    """dnf 4's transaction items, named the way libdnf5 names them, so the
    plan reads the same whichever helper resolved it."""
    action = tsi.action
    names = {
        dnf.transaction.PKG_INSTALL: "Install",
        dnf.transaction.PKG_UPGRADE: "Upgrade",
        dnf.transaction.PKG_DOWNGRADE: "Downgrade",
        dnf.transaction.PKG_REINSTALL: "Reinstall",
        dnf.transaction.PKG_REMOVE: "Remove",
        dnf.transaction.PKG_UPGRADED: "Replaced",
        dnf.transaction.PKG_DOWNGRADED: "Replaced",
        dnf.transaction.PKG_REINSTALLED: "Replaced",
        dnf.transaction.PKG_OBSOLETED: "Obsoleted",
        dnf.transaction.PKG_OBSOLETE: "Install",
    }
    return names.get(action, str(action))


def enable_copr(project):
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


def make_base(cache_only, refresh, progress=None):
    base = dnf.Base()
    base.conf.read()
    base.conf.substitutions.update_from_etc(base.conf.installroot)
    if cache_only:
        base.conf.cacheonly = True
    base.read_all_repos()
    for repo in base.repos.iter_enabled():
        if progress is not None:
            repo.set_progress_bar(progress)
        if refresh:
            # `dnf --refresh`, for the reason rpm_helper.expire_repos gives:
            # the list on screen was built from fresh metadata, and the
            # transaction has to resolve against the same
            try:
                repo._repo.expire()
            except Exception as exc:
                emit({"event": "warning", "message": "could not expire %s: %s" % (repo.id, exc)})
    return base


def run(action, specs, dry_run=False, copr=""):
    if copr and not dry_run and not enable_copr(copr):
        emit({"event": "done", "ok": False, "failed": list(specs)})
        return 1
    downloads = DownloadProgress()
    base = make_base(cache_only=dry_run, refresh=not dry_run, progress=downloads)
    try:
        base.fill_sack(load_system_repo=True, load_available_repos=True)

        unknown = []
        for spec in specs:
            try:
                if action == "install":
                    base.install(spec)
                elif action == "remove":
                    base.remove(spec)
                elif action == "upgrade":
                    base.upgrade(spec)
                else:
                    base.downgrade_to(spec)
            except dnf.exceptions.PackagesNotInstalledError:
                # Upgrading or removing what is not there: nothing to do for
                # it, which the "no newer build" line below says for upgrades
                if action == "remove":
                    unknown.append(spec)
            except dnf.exceptions.MarkingError:
                unknown.append(spec)
        if unknown:
            emit({"event": "error", "message": "no package matches: " + ", ".join(unknown)})
            if action != "upgrade":
                emit({"event": "done", "ok": False, "failed": list(specs)})
                return 1

        try:
            base.resolve(allow_erasing=(action == "remove"))
        except dnf.exceptions.DepsolveError as exc:
            emit({"event": "error", "message": str(exc).strip() or "resolution failed"})
            emit({"event": "done", "ok": False, "failed": list(specs)})
            return 1

        ops = []
        total_download = 0
        disk_delta = 0
        for tsi in base.transaction:
            pkg = tsi.pkg
            act = _action_of(tsi)
            entry = {
                "name": pkg.name,
                "evr": pkg.evr,
                "action": act,
                "downloadBytes": int(pkg.downloadsize or 0) if act in INBOUND else 0,
                "installBytes": int(pkg.installsize or 0),
            }
            if act in INBOUND:
                total_download += entry["downloadBytes"]
                disk_delta += entry["installBytes"]
                downloads.plan_names.add(pkg.name)
            elif act in OUTBOUND:
                disk_delta -= entry["installBytes"]
            ops.append(entry)

        if not ops:
            emit({"event": "done", "ok": True, "failed": [], "nothingToDo": True})
            return 0
        if action == "upgrade":
            planned = {o["name"] for o in ops}
            missing = [spec for spec in specs if spec not in planned]
            if missing:
                emit({"event": "error",
                      "message": "the repositories offer no newer build of: " + ", ".join(missing)})
        emit({"event": "plan", "ops": ops, "totalDownloadBytes": total_download,
              "installDeltaBytes": disk_delta})
        if dry_run:
            emit({"event": "done", "ok": True, "failed": []})
            return 0

        downloads.quiet = False
        inbound = [tsi.pkg for tsi in base.transaction if _action_of(tsi) in INBOUND]
        try:
            base.download_packages(inbound, downloads)
        except dnf.exceptions.DownloadError as exc:
            emit({"event": "error", "message": str(exc) or "download failed"})
            emit({"event": "done", "ok": False, "failed": list(specs)})
            return 1
        downloads.quiet = True

        rpm_cb = RpmProgress()
        try:
            base.do_transaction(display=rpm_cb)
        except dnf.exceptions.Error as exc:
            rpm_cb.finish()
            emit({"event": "error", "message": str(exc) or "transaction failed"})
            emit({"event": "done", "ok": False, "failed": list(specs)})
            return 1
        rpm_cb.finish()
        emit({"event": "done", "ok": True, "failed": []})
        return 0
    finally:
        base.close()


SEVERITY_RANK = {"critical": 4, "important": 3, "moderate": 2, "low": 1}
TYPE_RANK = {"security": 3, "bugfix": 2, "enhancement": 1}
ADVISORY_TYPES = {}


def _advisory_type(kind):
    if not ADVISORY_TYPES:
        import hawkey
        ADVISORY_TYPES.update({
            hawkey.ADVISORY_SECURITY: "security",
            hawkey.ADVISORY_BUGFIX: "bugfix",
            hawkey.ADVISORY_ENHANCEMENT: "enhancement",
            hawkey.ADVISORY_NEWPACKAGE: "newpackage",
        })
    return ADVISORY_TYPES.get(kind, "")


def run_advisories(names):
    """{name: {type, severity, ids}}, read-only and from the cache: RHEL and
    its rebuilds publish updateinfo; CentOS Stream mostly does not, and then
    the answer is simply empty."""
    import hawkey

    base = make_base(cache_only=True, refresh=False)
    try:
        base.fill_sack(load_system_repo=True, load_available_repos=True)
        wanted = set(names)
        out = {}
        # The advisories behind builds newer than the installed one: the
        # pending updates, as `dnf updateinfo list updates` finds them
        installed = base.sack.query().installed().filterm(name=list(wanted))
        for apkg in installed.get_advisory_pkgs(hawkey.GT):
            if apkg.name not in wanted:
                continue
            adv = apkg.get_advisory(base.sack)
            adv_type = _advisory_type(adv.type)
            severity = (adv.severity or "").lower()
            ids = [ref.id for ref in adv.references if ref.type == hawkey.REFERENCE_CVE]
            current = out.get(apkg.name)
            better = (TYPE_RANK.get(adv_type, 0), SEVERITY_RANK.get(severity, 0))
            if current is None or better > (TYPE_RANK.get(current["type"], 0),
                                            SEVERITY_RANK.get(current["severity"], 0)):
                out[apkg.name] = {"type": adv_type, "severity": severity, "ids": ids}
            elif current["type"] == adv_type:
                for cve in ids:
                    if cve not in current["ids"]:
                        current["ids"].append(cve)
        emit({"event": "advisories", "packages": out})
        emit({"event": "done", "ok": True, "failed": []})
        return 0
    finally:
        base.close()


ACTIONS = ("install", "remove", "upgrade", "downgrade")


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "selftest":
        emit({"event": "done", "ok": True, "failed": []})
        return 0
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
    except Exception as exc:
        emit({"event": "error", "message": str(exc)})
        emit({"event": "done", "ok": False, "failed": argv[1:]})
        return 1


if __name__ == "__main__":
    sys.exit(main())
