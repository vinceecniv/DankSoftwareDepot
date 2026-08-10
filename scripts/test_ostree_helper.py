#!/usr/bin/env python3
"""Exercise the rpm-ostree helper without an atomic box.

rpm-ostree's output is the only thing the helper reads, so the transcripts
below are what the tests are: an install that layers two packages, an upgrade
whose progress bar is one line rewritten with carriage returns, a failure, and
the two paths that must never reach the daemon at all — a plan (it would ask
for a password) and a downgrade (it has no meaning on a deployment).

Run from anywhere:  python3 scripts/test_ostree_helper.py
"""
import io
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ostree_helper as oh

INSTALL_OUTPUT = """\
Checking out tree 5a9f0e1... done
Enabled rpm-md repositories: fedora updates copr:copr.fedorainfracloud.org:yalter:niri
Updating metadata for 'updates'... done
Importing rpm-md... done
Resolving dependencies... done
Will download: 2 packages (1.6 MB)
Downloading from 'updates'... done
Importing packages... done
Checking out packages... done
Running pre scripts... done
Running post scripts... done
Writing rpmdb... done
Staging deployment... done
Freed: 20.0 MB (pkgcache branches: 0)
Added:
  htop-3.3.0-1.fc44.x86_64
  lsof-4.99.0-1.fc44.x86_64
Changes queued for next boot. Run "systemctl reboot" to start a reboot
"""

UPGRADE_OUTPUT = """\
Receiving metadata objects: 12/(estimating) 180.0 kB/s 1.4 MB\r\
Receiving objects: 45% (1234/2700) 12.4 MB/s 120.0 MB\r\
Receiving objects: 100% (2700/2700) 260.0 MB
Staging deployment... done
Upgraded:
  kernel 6.14.0-1.fc44 -> 6.15.0-1.fc44
  vim-minimal 9.1-1.fc44 -> 9.1-2.fc44
Changes queued for next boot. Run "systemctl reboot" to start a reboot
"""

FAIL_OUTPUT = """\
Checking out tree 5a9f0e1... done
Resolving dependencies... done
error: Package/capability 'nosuchpkg' not found
"""


class FakeProcess:
    def __init__(self, text, code):
        self.stdout = io.StringIO(text)
        self._code = code

    def wait(self):
        return self._code


def capture(output, code, action, specs, dry_run=False):
    events = []
    oh.emit = lambda obj: events.append(obj)
    oh.shutil.which = lambda name: "/usr/bin/" + name
    oh.subprocess.Popen = lambda *a, **k: FakeProcess(output, code)
    exit_code = oh.run(action, specs, dry_run)
    return exit_code, events


def kinds(events):
    return [e["event"] for e in events]


def check(label, condition, detail=""):
    print(("  ok   " if condition else "  FAIL ") + label + (("  " + detail) if not condition else ""))
    return condition


ok = True

print("install (layering two packages)")
code, events = capture(INSTALL_OUTPUT, 0, "install", ["htop"])
ok &= check("exit 0", code == 0, str(code))
ok &= check("ends in done", kinds(events)[-1] == "done")
ok &= check("done ok", events[-1]["ok"] is True)
ok &= check("staged reported", events[-1].get("staged") is True, json.dumps(events[-1]))
plan = next((e for e in events if e["event"] == "plan"), None)
ok &= check("plan emitted", plan is not None)
ok &= check("plan size parsed (1.6 MB)", plan and plan["totalDownloadBytes"] == 1600000,
            plan and str(plan["totalDownloadBytes"]))
ok &= check("download phase seen", any(e["event"] == "op-start" and e["phase"] == "download" for e in events))
ok &= check("install phase seen", any(e["event"] == "op-start" and e["phase"] == "install" for e in events))
ok &= check("status/repos seen", any(e["event"] == "status" for e in events))

print("summary parsing")
ops = oh.parse_summary(INSTALL_OUTPUT.splitlines())
ok &= check("two ops from Added block", len(ops) == 2, str(ops))
ok &= check("name/evr split", ops and ops[0] == {"name": "htop", "evr": "3.3.0-1.fc44",
                                                 "action": "Install", "downloadBytes": 0,
                                                 "installBytes": 0}, str(ops[:1]))
ops = oh.parse_summary(UPGRADE_OUTPUT.splitlines())
ok &= check("arrow form parsed", [o["name"] for o in ops] == ["kernel", "vim-minimal"], str(ops))
ok &= check("arrow takes the new evr", ops and ops[0]["evr"] == "6.15.0-1.fc44", str(ops[:1]))
ok &= check("arrow action is Upgrade", ops and ops[0]["action"] == "Upgrade")

print("upgrade (whole deployment, \\r progress)")
code, events = capture(UPGRADE_OUTPUT, 0, "upgrade", ["kernel", "vim-minimal"])
ok &= check("exit 0", code == 0)
ok &= check("warns that packages cannot be chosen",
            any(e["event"] == "warning" for e in events))
percents = [e["percent"] for e in events if e["event"] == "progress"]
ok &= check("percent from \\r-rewritten line", 45 in percents, str(percents))
ok &= check("staged reported", events[-1].get("staged") is True)

print("failure")
code, events = capture(FAIL_OUTPUT, 1, "install", ["nosuchpkg"])
ok &= check("exit 1", code == 1)
ok &= check("error carries rpm-ostree's words",
            any(e["event"] == "error" and "not found" in e["message"] for e in events),
            json.dumps([e for e in events if e["event"] == "error"]))
ok &= check("done ok false", events[-1]["ok"] is False)
ok &= check("failed lists the spec", events[-1]["failed"] == ["nosuchpkg"])

print("plan (must not run rpm-ostree)")
def explode(*a, **k):
    raise AssertionError("plan ran rpm-ostree, which would ask for a password")
oh.subprocess.Popen = explode
events = []
oh.emit = lambda obj: events.append(obj)
code = oh.run("install", ["htop"], dry_run=True)
ok &= check("exit 0", code == 0)
ok &= check("plan emitted from the specs",
            any(e["event"] == "plan" and e["ops"] and e["ops"][0]["name"] == "htop" for e in events))
ok &= check("warns that sizes are unknown", any(e["event"] == "warning" for e in events))
ok &= check("ends in done ok", events[-1]["event"] == "done" and events[-1]["ok"] is True)

print("downgrade is refused, not guessed")
events = []
oh.emit = lambda obj: events.append(obj)
code = oh.run("downgrade", ["htop"], False)
ok &= check("exit 1", code == 1)
ok &= check("says why", any(e["event"] == "error" and "rollback" in e["message"] for e in events))

print()
print("ALL OK" if ok else "FAILURES")
sys.exit(0 if ok else 1)
