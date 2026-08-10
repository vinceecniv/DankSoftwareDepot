#!/usr/bin/env python3
"""rpm-ostree transactions, reported as the same NDJSON events as the other
helpers — so an atomic Fedora (Silverblue, Kinoite, Bazzite, Bluefin) reaches
the same UI as a mutable one:

  {"event":"status","message":"repos"}                       metadata, resolving
  {"event":"plan","ops":[{"name","evr","action","downloadBytes","installBytes"}],
   "totalDownloadBytes":N}
  {"event":"op-start"/"progress"/"op-done","phase":"download"|"install"}
  {"event":"warning","message":...}                          what differs here
  {"event":"error","message":...}
  {"event":"done","ok":true|false,"failed":[names],"staged":true}

Usage: ostree_helper.py [plan] <install|remove|upgrade|downgrade> <spec>...
       ostree_helper.py install --copr <owner/project> <spec>...
       ostree_helper.py selftest

`--copr` adds that Copr before layering, so a package found by the Copr search
costs one authorisation instead of two — the same option rpm_helper.py takes,
because the two steps are the same two steps here.

An atomic system is not a mutable one with a read-only /usr, and three
differences are visible here rather than hidden:

- **Nothing takes effect until the next boot.** rpm-ostree writes a new
  deployment; the running one is untouched. Every successful transaction
  therefore ends with `"staged": true`, and the UI says so instead of
  claiming the package is in use.
- **An upgrade is the whole image.** There is no upgrading two packages out
  of five: `rpm-ostree upgrade` moves to the next base commit. The specs a
  caller passes are reported back in the plan, but the transaction is the
  deployment.
- **A plan costs a password here.** rpm-ostree resolves inside its daemon,
  which asks polkit even for `--dry-run`, and the protocol says a plan must
  be free. So a plan is answered from what was asked rather than resolved,
  with a warning saying as much — better an honest "this is what you asked
  for" than a password prompt for a preview.

Removal only covers packages that were layered. One that came with the image
needs `rpm-ostree override remove`, which is a different promise (it changes
what the image is), so it is refused with a reason instead of guessed at.
"""
import json
import re
import shutil
import subprocess
import sys

RPM_OSTREE = "rpm-ostree"
ACTIONS = ("install", "remove", "upgrade", "downgrade")


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


# ── Reading rpm-ostree's running commentary ────────────────────────────────
# Piped, rpm-ostree prints one line per step and percentages while it moves
# bytes. None of it is a stable interface, so every pattern that fails to
# match costs progress detail and nothing else — the transaction is driven by
# the exit code, never by the text.

RESOLVING = re.compile(
    r"^(Checking out tree|Enabled rpm-md|Updating metadata|Importing rpm-md|"
    r"Resolving dependencies|Checking out packages)", re.I)
# "Will download: 3 packages (12.4 MB)"
WILL_DOWNLOAD = re.compile(
    r"Will download:\s*(\d+)\s*package.*?\(([\d.]+)\s*([kKMG]?i?B)\)", re.I)
DOWNLOADING = re.compile(r"^(Downloading|Receiving|Fetching|Importing packages)", re.I)
INSTALLING = re.compile(
    r"^(Applying|Installing|Running pre|Running post|Writing|Committing|"
    r"Staging deployment|Building|Generating)", re.I)
PERCENT = re.compile(r"(\d{1,3})%")
STAGED = re.compile(r"(queued for next boot|Staging deployment)", re.I)
# The summary blocks at the end: "Added:", "Removed:", "Upgraded:", each
# followed by indented NEVRA lines ("foo-1.2-1.fc44.x86_64" or, for an
# upgrade, "foo 1.1-1.fc44 -> 1.2-1.fc44")
SUMMARY_HEAD = re.compile(r"^(Added|Removed|Upgraded|Downgraded|Installed):\s*$", re.I)
NEVRA = re.compile(r"^(?P<name>[\w.+-]+?)-(?P<evr>[\w.:+~]+-[\w.+~]+)\.[\w_]+$")
ARROW = re.compile(r"^(?P<name>\S+)\s+(?P<from>\S+)\s*->\s*(?P<to>\S+)$")

UNITS = {"b": 1, "kb": 1000, "kib": 1024, "mb": 1000 ** 2, "mib": 1024 ** 2,
         "gb": 1000 ** 3, "gib": 1024 ** 3}

SUMMARY_ACTION = {"added": "Install", "installed": "Install", "removed": "Remove",
                  "upgraded": "Upgrade", "downgraded": "Downgrade"}


def _bytes(value, unit):
    try:
        return int(float(value) * UNITS.get(unit.lower(), 1))
    except ValueError:
        return 0


def parse_summary(lines):
    """The Added/Removed/Upgraded blocks rpm-ostree ends with, as plan ops."""
    ops = []
    action = ""
    for raw in lines:
        head = SUMMARY_HEAD.match(raw.strip())
        if head:
            action = SUMMARY_ACTION.get(head.group(1).lower(), "Install")
            continue
        if not action:
            continue
        if not raw.startswith((" ", "\t")):
            action = ""
            continue
        for entry in raw.split():
            arrow = ARROW.match(raw.strip())
            if arrow:
                ops.append({"name": arrow.group("name"), "evr": arrow.group("to"),
                            "action": action, "downloadBytes": 0, "installBytes": 0})
                break
            match = NEVRA.match(entry)
            if match:
                ops.append({"name": match.group("name"), "evr": match.group("evr"),
                            "action": action, "downloadBytes": 0, "installBytes": 0})
    return ops


class Reporter:
    """One rpm-ostree run, turned into protocol events as it speaks."""

    def __init__(self, specs):
        self.specs = list(specs)
        self.lines = []
        self.staged = False
        self.planned = False
        self.phase = ""

    def line(self, raw):
        text = raw.rstrip()
        if not text.strip():
            return
        self.lines.append(text)
        if STAGED.search(text):
            self.staged = True
        download = WILL_DOWNLOAD.search(text)
        if download and not self.planned:
            self.plan(_bytes(download.group(2), download.group(3)))
            return
        if RESOLVING.match(text):
            emit({"event": "status", "message": "repos"})
            return
        percent = PERCENT.search(text)
        if DOWNLOADING.match(text):
            self._phase("download", percent)
            return
        if INSTALLING.match(text):
            self._phase("install", percent)

    def _phase(self, phase, percent):
        name = self.specs[0] if self.specs else "system"
        if phase != self.phase:
            self.phase = phase
            emit({"event": "op-start", "name": name, "phase": phase})
        if percent:
            emit({"event": "progress", "name": name, "phase": phase,
                  "percent": min(100, int(percent.group(1)))})

    def plan(self, total_download=0, ops=None):
        """The transaction as far as it is known, emitted once."""
        if self.planned:
            return
        self.planned = True
        emit({"event": "plan", "ops": ops or self.pending_ops(),
              "totalDownloadBytes": total_download, "installDeltaBytes": 0})

    def pending_ops(self):
        return [{"name": spec, "evr": "", "action": "Install",
                 "downloadBytes": 0, "installBytes": 0} for spec in self.specs]


def run_command(argv, reporter):
    """Run rpm-ostree, relaying its lines as events. Returns its exit code."""
    process = subprocess.Popen(argv, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, bufsize=1)
    for raw in process.stdout:
        # A progress bar is one line rewritten with \r; each piece is a line
        for piece in raw.replace("\r", "\n").split("\n"):
            reporter.line(piece)
    process.stdout.close()
    return process.wait()


def enable_copr(project):
    """Add the Copr this package lives in, inside the same authorisation.

    An atomic image has no dnf and therefore no `dnf copr enable`; the hub's
    own .repo file is what that command installs anyway, and repo_backend
    knows how to fetch it. rpm-ostree layers from /etc/yum.repos.d like dnf
    installs from it.
    """
    import os

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import repo_backend
    except ImportError as exc:
        emit({"event": "error", "message": "cannot add the Copr: %s" % exc})
        return False
    emit({"event": "status", "message": "repos"})
    if shutil.which("dnf"):
        result = subprocess.run(["dnf", "-y", "copr", "enable", project],
                                capture_output=True, text=True)
        if result.returncode == 0:
            return True
        reason = (result.stderr or result.stdout or "").strip().splitlines()
        emit({"event": "error", "message": "could not enable the Copr %s: %s"
                                           % (project, reason[-1] if reason else "unknown error")})
        return False
    return repo_backend.copr_enable_file(project, "enable copr %s" % project)


def run(action, specs, dry_run=False, copr=""):
    if copr and not dry_run and not enable_copr(copr):
        emit({"event": "done", "ok": False, "failed": list(specs)})
        return 1
    if not shutil.which(RPM_OSTREE):
        emit({"event": "error", "message": "rpm-ostree is not installed"})
        emit({"event": "done", "ok": False, "failed": list(specs)})
        return 1

    if action == "downgrade":
        # Per-package downgrade has no meaning here: the previous deployment
        # is a whole image, and rolling back to it is `rpm-ostree rollback`,
        # which is not what a caller asking for one package meant.
        emit({"event": "error",
              "message": "rpm-ostree cannot downgrade a single package; "
                         "the previous deployment is a whole image "
                         "(rpm-ostree rollback)"})
        emit({"event": "done", "ok": False, "failed": list(specs)})
        return 1

    reporter = Reporter(specs)

    if dry_run:
        # Resolving happens inside the rpm-ostree daemon, which asks polkit
        # even for --dry-run. A plan that prompts for a password is worse than
        # a plan that says what it does not know.
        emit({"event": "warning",
              "message": "on rpm-ostree the dependencies and sizes of a "
                         "transaction are only known while it runs"})
        action_word = {"install": "Install", "remove": "Remove",
                       "upgrade": "Upgrade"}[action]
        reporter.plan(0, [{"name": spec, "evr": "", "action": action_word,
                           "downloadBytes": 0, "installBytes": 0} for spec in specs])
        emit({"event": "done", "ok": True, "failed": []})
        return 0

    if action == "upgrade":
        # There is no upgrading two packages out of five: the deployment is
        # the unit. Said out loud, because the caller asked per package.
        if specs:
            emit({"event": "warning",
                  "message": "rpm-ostree updates the whole deployment; "
                             "individual packages cannot be chosen"})
        argv = [RPM_OSTREE, "upgrade"]
    elif action == "install":
        argv = [RPM_OSTREE, "install", "--idempotent"] + list(specs)
    else:
        argv = [RPM_OSTREE, "uninstall", "--idempotent"] + list(specs)

    code = run_command(argv, reporter)
    summary = parse_summary(reporter.lines)
    # Nothing said "Will download", so the plan is whatever it turned out to
    # be — late for a progress bar, but it is what happened
    reporter.plan(0, summary or None)

    if code != 0:
        tail = [l for l in reporter.lines if l.strip()][-3:]
        message = " · ".join(tail) or ("%s exited %d" % (RPM_OSTREE, code))
        if "not currently requested" in message or "not layered" in message:
            message = ("that package came with the image rather than being "
                       "layered; removing it needs an override")
        emit({"event": "error", "message": message})
        emit({"event": "done", "ok": False, "failed": list(specs)})
        return 1

    if not summary and action != "upgrade":
        emit({"event": "done", "ok": True, "failed": [], "nothingToDo": True,
              "staged": reporter.staged})
        return 0
    emit({"event": "done", "ok": True, "failed": [], "staged": reporter.staged})
    return 0


def selftest():
    """Whether this helper can work here at all, in the protocol's own words."""
    if not shutil.which(RPM_OSTREE):
        emit({"event": "error", "message": "rpm-ostree is not installed"})
        emit({"event": "done", "ok": False, "failed": []})
        return 1
    emit({"event": "done", "ok": True, "failed": []})
    return 0


def main():
    argv = sys.argv[1:]
    if len(argv) == 1 and argv[0] == "selftest":
        return selftest()
    dry_run = bool(argv) and argv[0] == "plan"
    if dry_run:
        argv = argv[1:]
    copr = ""
    if len(argv) > 2 and argv[1] == "--copr":
        copr = argv[2]
        argv = [argv[0]] + argv[3:]
    if not argv or argv[0] not in ACTIONS or (copr and argv[0] != "install"):
        print(__doc__, file=sys.stderr)
        return 2
    if argv[0] != "upgrade" and len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        return run(argv[0], argv[1:], dry_run, copr)
    except Exception as exc:  # the stream ends in `done` whatever happens
        emit({"event": "error", "message": str(exc)})
        emit({"event": "done", "ok": False, "failed": argv[1:]})
        return 1


if __name__ == "__main__":
    sys.exit(main())
