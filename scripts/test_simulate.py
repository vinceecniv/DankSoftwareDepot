#!/usr/bin/env python3
"""Checks that a recorded run plays back as the run that was recorded.

The whole worth of a simulation is that the layer above it cannot tell the
difference, so these checks are about sameness: the same lines, in the same
order, on the same streams, with the same exit code and roughly the same
timing. Plus the two failure modes that matter — a recorder that breaks the
transaction it is wrapped around, and a pass that was never recorded.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SIM = Path(__file__).resolve().parent / "simulate.py"

# A miniature of a real run: a plan, two packages downloading, one failing,
# and the done event the protocol promises is always last.
SCRIPT = r'''
import sys, time
def emit(s):
    sys.stdout.write(s + "\n"); sys.stdout.flush()
emit('{"event":"status","message":"repos"}')
time.sleep(0.05)
emit('{"event":"plan","ops":[{"name":"mesa","evr":"1-1"}],"totalDownloadBytes":10}')
sys.stderr.write("warming up\n"); sys.stderr.flush()
time.sleep(0.05)
emit('{"event":"op-start","name":"mesa","phase":"download","bytesTotal":10}')
emit('{"event":"op-error","name":"kernel","phase":"install","message":"no space"}')
emit('{"event":"done","ok":false,"failed":["kernel"]}')
sys.exit(1)
'''


def run(*args, **kwargs):
    return subprocess.run([sys.executable, str(SIM), *args],
                          capture_output=True, text=True, timeout=60, **kwargs)


def check(label, condition, detail=""):
    print(("  ok   " if condition else "  FAIL ") + label
          + (" — " + detail if detail and not condition else ""))
    return condition


def main():
    ok = True
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "recordings"
        helper = Path(tmp) / "fake_helper.py"
        helper.write_text(SCRIPT)
        directory = root / "run-1"

        # Recording passes the run through untouched — the shell above sees
        # exactly what the helper wrote, or the recording is a liability.
        started = time.monotonic()
        rec = run("record", str(directory), "system", "--",
                  sys.executable, str(helper))
        elapsed = time.monotonic() - started
        direct = subprocess.run([sys.executable, str(helper)],
                                capture_output=True, text=True)
        ok &= check("the recorder passes stdout through unchanged",
                    rec.stdout == direct.stdout, repr(rec.stdout))
        ok &= check("and stderr", rec.stderr == direct.stderr, repr(rec.stderr))
        ok &= check("and the exit code", rec.returncode == 1,
                    str(rec.returncode))

        entries = [json.loads(l) for l in
                   (directory / "system.jsonl").read_text().splitlines() if l]
        ok &= check("every line was written down",
                    [e["line"] for e in entries if e.get("s") == "out"]
                    == direct.stdout.splitlines(), json.dumps(entries))
        ok &= check("stderr is kept apart from stdout",
                    [e["line"] for e in entries if e.get("s") == "err"]
                    == ["warming up"], json.dumps(entries))
        ok &= check("the exit code is the last thing recorded",
                    entries[-1].get("exit") == 1, json.dumps(entries[-1]))
        ok &= check("timestamps carry the shape of the run",
                    entries[0]["t"] < entries[2]["t"] < entries[-1]["t"],
                    json.dumps([e["t"] for e in entries]))

        # Playing it back is indistinguishable from the run itself.
        played = run("play", str(directory), "system")
        ok &= check("playback writes the same stdout",
                    played.stdout == direct.stdout, repr(played.stdout))
        ok &= check("the same stderr", played.stderr == direct.stderr,
                    repr(played.stderr))
        ok &= check("and exits the same way", played.returncode == 1,
                    str(played.returncode))

        started = time.monotonic()
        run("play", str(directory), "system", "--speed", "10")
        fast = time.monotonic() - started
        ok &= check("--speed shortens a run without changing it",
                    fast < max(elapsed, 0.1), "%.2fs vs %.2fs" % (fast, elapsed))

        # A pass the recording does not have is a pass that did nothing on the
        # machine it came from. It has to end, not hang: the engine runs its
        # passes in sequence and waits for each one.
        missing = run("play", str(directory), "flatpak")
        ok &= check("an unrecorded pass ends cleanly and says nothing",
                    missing.returncode == 0 and missing.stdout == "",
                    repr(missing.stdout))

        # Whatever goes wrong with the recording, the command still runs.
        blocked = Path(tmp) / "blocked"
        blocked.write_text("not a directory")
        fell_through = run("record", str(blocked / "nested"), "system", "--",
                           sys.executable, str(helper))
        ok &= check("an unwritable recording still runs the transaction",
                    fell_through.stdout == direct.stdout,
                    repr(fell_through.stdout[:200]))

        # What the window was showing is part of the recording, because
        # nothing else can reconstruct it afterwards.
        packages = {"backendId": "dnf",
                    "packages": [{"name": "mesa", "repo": "updates"},
                                 {"name": "kernel", "repo": "updates"}]}
        run("begin", str(root), "run-2", json.dumps(packages))
        meta = json.loads(run("meta", str(root / "run-2")).stdout)
        ok &= check("the pending list is kept with the recording",
                    [p["name"] for p in meta["packages"]] == ["mesa", "kernel"],
                    json.dumps(meta))
        ok &= check("along with which backend it came from",
                    meta.get("backendId") == "dnf", json.dumps(meta))

        listing = json.loads(run("list", str(root)).stdout)
        by_name = {r["name"]: r for r in listing}
        ok &= check("listing finds both recordings",
                    set(by_name) == {"run-1", "run-2"}, json.dumps(listing))
        ok &= check("and knows which passes each one has",
                    by_name["run-1"]["tags"] == ["system"], json.dumps(listing))

    print("\n" + ("all checks passed" if ok else "FAILURES"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
