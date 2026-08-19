#!/usr/bin/env python3
"""Checks the Homebrew path against recorded output, with no brew present.

Runnable anywhere: brew is stubbed, so this says the same thing on the Fedora
machine it was written on as it would on one that has Homebrew installed.
"""

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

OUTDATED = json.dumps({
    "formulae": [
        {"name": "jq", "installed_versions": ["1.7.1"], "current_version": "1.8.0",
         "pinned": False, "pinned_version": None},
        {"name": "ripgrep", "installed_versions": ["14.1.0"], "current_version": "14.2.0",
         "pinned": False, "pinned_version": None},
        {"name": "node", "installed_versions": ["22.1.0", "22.4.0"], "current_version": "23.0.0",
         "pinned": True, "pinned_version": "22.4.0"},
    ],
    "casks": [],
})

LIST_VERSIONS = "jq 1.7.1\nripgrep 14.1.0\nnode 22.1.0 22.4.0\nzlib 1.3.1\n"

# Recorded from a real `brew upgrade` (Homebrew 6.0.18) against a local tap,
# with the summary line brew 4 opened with kept in front of it: the two
# generations word it differently and both are the same shape as a formula
# line, which is why nothing is trusted here unless the run planned it.
UPGRADE_LOG = """==> Upgrading 2 outdated packages:
jq 1.7.1 -> 1.8.0
ripgrep 14.1.0 -> 14.2.0
==> Fetching downloads for: jq
==> Upgrading jq
  1.7.1 -> 1.8.0
==> Pouring jq-1.8.0.x86_64_linux.bottle.tar.gz
\U0001F37A  /home/linuxbrew/.linuxbrew/Cellar/jq/1.8.0: 20 files, 1.2MB
==> Upgrading ripgrep
  14.1.0 -> 14.2.0
==> Pouring ripgrep-14.2.0.x86_64_linux.bottle.tar.gz
\U0001F37A  /home/linuxbrew/.linuxbrew/Cellar/ripgrep/14.2.0: 15 files, 5.5MB
==> Cleanup
==> Upgraded 2 outdated packages
jq 1.7.1 -> 1.8.0
ripgrep 14.1.0 -> 14.2.0
"""

# A formula from a third-party tap is named in full by `brew outdated` and
# short by `brew list` — recorded from the tap this was tested against.
TAP_OUTDATED = json.dumps({
    "formulae": [{"name": "dsd/test/dsdtest", "installed_versions": ["1.0.0"],
                  "current_version": "1.0.1", "pinned": False, "pinned_version": None}],
    "casks": [],
})

failures = []


def check(label, condition, detail=""):
    if condition:
        print(f"  ok    {label}")
    else:
        print(f"  FAIL  {label}{(': ' + detail) if detail else ''}")
        failures.append(label)


class FakeProcess:
    """Enough of Popen for the upgrade loop: lines out, then an exit code."""

    def __init__(self, text, code=0):
        self.stdout = iter(text.splitlines(keepends=True))
        self._code = code

    def wait(self):
        return self._code


def capture(fn, *args):
    import contextlib
    import io
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        fn(*args)
    return [json.loads(line) for line in buf.getvalue().splitlines() if line.strip()]


def main():
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["XDG_CACHE_HOME"] = tmp
        import brew_helper as brew

        # ── Reading what brew reports ────────────────────────────────────────
        rows = brew.parse_outdated(OUTDATED)
        check("three outdated formulae", len(rows) == 3, str(len(rows)))
        by_name = {r["name"]: r for r in rows}
        check("the version it is on comes from the newest installed",
              by_name["node"]["fromVersion"] == "22.4.0", by_name["node"]["fromVersion"])
        check("and the version it would go to", by_name["jq"]["toVersion"] == "1.8.0")
        check("a pinned formula is marked as such", by_name["node"]["pinned"] is True)
        check("an unpinned one is not", by_name["jq"]["pinned"] is False)
        check("sorted by name", [r["name"] for r in rows] == ["jq", "node", "ripgrep"])
        check("nothing usable in, nothing out", brew.parse_outdated("not json") == [])

        tap = brew.parse_outdated(TAP_OUTDATED)[0]
        check("a tap formula keeps the name brew upgrade needs",
              tap["name"] == "dsd/test/dsdtest", tap["name"])
        check("and gains the one a person should read",
              tap["displayName"] == "dsdtest", tap["displayName"])

        installed = brew.parse_installed(LIST_VERSIONS)
        check("four installed formulae", len(installed) == 4, str(len(installed)))
        check("the newest version of a multi-version formula wins",
              {i["name"]: i["version"] for i in installed}["node"] == "22.4.0")

        # ── No brew on this machine is an answer, not an error ───────────────
        brew.brew_path = lambda: ""
        out = capture(brew.run_state, False)
        check("unsupported is reported plainly", out[0]["supported"] is False, str(out[0]))

        events = capture(brew.run_upgrade, ["jq"])
        check("an upgrade without brew fails cleanly",
              events[-1]["event"] == "done" and events[-1]["ok"] is False, str(events[-1]))

        # ── The upgrade event stream ─────────────────────────────────────────
        brew.brew_path = lambda: "/usr/bin/brew"
        brew.subprocess.Popen = lambda *a, **k: FakeProcess(UPGRADE_LOG, 0)
        events = capture(brew.run_upgrade, ["jq", "ripgrep"])
        kinds = [e["event"] for e in events]
        check("it plans before it starts", kinds[0] == "plan", str(kinds[:2]))
        check("both formulae are planned", len(events[0]["ops"]) == 2)
        starts = [e["name"] for e in events if e["event"] == "op-start"]
        dones = [e["name"] for e in events if e["event"] == "op-done"]
        check("each formula starts once", starts == ["jq", "ripgrep"], str(starts))
        check("and finishes once", dones == ["jq", "ripgrep"], str(dones))
        check("the run reports success", events[-1] == {"event": "done", "ok": True, "failed": []},
              str(events[-1]))

        # ── A failure names what did not happen ──────────────────────────────
        broken = UPGRADE_LOG.split("==> Upgrading ripgrep")[0] + "Error: jq: no bottle available\n"
        brew.subprocess.Popen = lambda *a, **k: FakeProcess(broken, 1)
        events = capture(brew.run_upgrade, ["jq", "ripgrep"])
        errors = {e["name"] for e in events if e["event"] == "op-error"}
        check("everything unfinished is reported failed", errors == {"jq", "ripgrep"}, str(errors))
        check("with brew's own words attached",
              "no bottle available" in next(e["message"] for e in events if e["event"] == "op-error"))
        check("and the run says so", events[-1]["ok"] is False)

        # ── Pinned formulae sit out an unnamed upgrade ───────────────────────
        brew.run = lambda args, timeout: OUTDATED if "outdated" in args else ""
        brew.subprocess.Popen = lambda *a, **k: FakeProcess("", 0)
        events = capture(brew.run_upgrade, [])
        planned = [op["name"] for op in events[0]["ops"]]
        check("a run with no names takes everything outdated but the pinned one",
              planned == ["jq", "ripgrep"], str(planned))

    print()
    if failures:
        print(f"{len(failures)} failed")
        return 1
    print("brew helper: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
