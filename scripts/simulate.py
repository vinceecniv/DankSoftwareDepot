#!/usr/bin/env python3
"""Record a real update run, and play it back as a simulation.

Nothing in the updater window is drawn from the system directly. Every phase,
every row, every byte counter and every error comes from the newline-delimited
JSON a helper writes on stdout (see PROTOCOL.md), so a recording of those
streams is a recording of everything the window can show. Playing one back
puts the entire interface through a real run — the same rows, the same
ordering, the same pauses — without root, without a network, and without
waiting for a distribution to ship thirty-one updates.

That is the point: the visual side of a run used to be testable only on the
mornings when there happened to be something to install, and only once,
because installing it is what makes it stop being available.

    simulate.py begin  <root> <name> <packages-json>
    simulate.py record <dir> <tag> -- <command>...
    simulate.py play   <dir> <tag> [--speed N]
    simulate.py list   <root>
    simulate.py meta   <dir>

A recording is a directory:

    <root>/<name>/meta.json     what was pending, which backend, when
    <root>/<name>/<tag>.jsonl   one line per line of output, with its time

Each `.jsonl` line is {"t": seconds-since-this-process-started, "s":
"out"|"err", "line": "..."}, and the last one is {"t": ..., "exit": N}. `t` is
relative to the process, not to the run, because the engine decides itself
when each pass starts; what a recording has to preserve is the shape of each
pass in time.

`record` is deliberately hard to fail with. It sits between the shell and a
transaction that is really installing packages, and a recorder that breaks
that is worse than no recorder at all — so anything that goes wrong while
setting up the recording falls through to running the command untouched.
"""

import errno
import json
import os
import signal
import subprocess
import sys
import threading
import time

META = "meta.json"
FORMAT_VERSION = 1


# ── Recording ───────────────────────────────────────────────────────────────

def cmd_begin(root, name, packages_json):
    """Create a recording directory and its metadata.

    The package list is passed as an argument rather than read from the
    system: what the window was showing is what the replay has to show, and
    only the caller knows that. Thirty-one packages are a few kilobytes, well
    inside any argument limit.
    """
    try:
        packages = json.loads(packages_json)
    except ValueError:
        packages = []
    path = os.path.join(root, name)
    os.makedirs(path, exist_ok=True)
    meta = {
        "format": FORMAT_VERSION,
        "name": name,
        "recordedAt": int(time.time()),
        "packages": packages,
    }
    # Anything the caller knows that is not a package goes in as-is, so the
    # format can grow without this script needing to know what grew.
    if isinstance(packages, dict):
        meta.update(packages)
        meta["packages"] = packages.get("packages", [])
    with open(os.path.join(path, META), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, ensure_ascii=False, indent=2)
    print(path)
    return 0


def _pump(stream, sink, kind, started, lock, out):
    """Copy one stream through, writing what went past into the recording."""
    for raw in iter(stream.readline, b""):
        text = raw.decode("utf-8", "replace")
        out.write(text)
        out.flush()
        stripped = text[:-1] if text.endswith("\n") else text
        with lock:
            sink.write(json.dumps({"t": round(time.monotonic() - started, 4),
                                   "s": kind, "line": stripped},
                                  ensure_ascii=False) + "\n")
            sink.flush()
    stream.close()


def cmd_record(directory, tag, command):
    if not command:
        print("record needs a command", file=sys.stderr)
        return 2
    try:
        os.makedirs(directory, exist_ok=True)
        sink = open(os.path.join(directory, tag + ".jsonl"), "w",
                    encoding="utf-8")
    except OSError:
        # A recording is never worth a failed transaction.
        os.execvp(command[0], command)
        return 127

    started = time.monotonic()
    lock = threading.Lock()
    proc = subprocess.Popen(command, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)

    # The shell kills this process to cancel a run; the transaction below it
    # is what actually has to hear about that.
    def relay(signum, frame):
        try:
            proc.send_signal(signum)
        except OSError:
            pass

    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            signal.signal(sig, relay)
        except (ValueError, OSError):
            pass

    threads = [
        threading.Thread(target=_pump, args=(proc.stdout, sink, "out", started,
                                             lock, sys.stdout)),
        threading.Thread(target=_pump, args=(proc.stderr, sink, "err", started,
                                             lock, sys.stderr)),
    ]
    for thread in threads:
        thread.daemon = True
        thread.start()
    code = proc.wait()
    for thread in threads:
        thread.join(timeout=5)
    with lock:
        sink.write(json.dumps({"t": round(time.monotonic() - started, 4),
                               "exit": code}) + "\n")
        sink.flush()
    sink.close()
    return code


# ── Playing back ────────────────────────────────────────────────────────────

def cmd_play(directory, tag, speed):
    path = os.path.join(directory, tag + ".jsonl")
    if not os.path.isfile(path):
        # A pass that was never recorded is a pass that did nothing. Ending
        # cleanly is what lets the engine carry on to the next one, which is
        # exactly what happened on the machine this was recorded from.
        return 0

    started = time.monotonic()
    code = 0
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw:
                continue
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            when = float(entry.get("t", 0))
            if speed > 0:
                wait = when / speed - (time.monotonic() - started)
                if wait > 0:
                    time.sleep(wait)
            if "exit" in entry:
                code = int(entry["exit"])
                continue
            out = sys.stderr if entry.get("s") == "err" else sys.stdout
            try:
                out.write(entry.get("line", "") + "\n")
                out.flush()
            except OSError as exc:
                # The reader is gone: the run was cancelled, which is not an
                # error in the thing being played.
                if exc.errno in (errno.EPIPE, errno.EINVAL):
                    return 0
                raise
    return code


# ── Reading what is there ───────────────────────────────────────────────────

def _read_meta(directory):
    try:
        with open(os.path.join(directory, META), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _span(directory, tag):
    """How long a recorded stream lasted, from its own last timestamp."""
    last = 0.0
    try:
        with open(os.path.join(directory, tag + ".jsonl"), encoding="utf-8") as fh:
            for raw in fh:
                try:
                    last = max(last, float(json.loads(raw).get("t", 0)))
                except (ValueError, AttributeError):
                    continue
    except OSError:
        return 0.0
    return last


def cmd_list(root):
    out = []
    for name in sorted(os.listdir(root) if os.path.isdir(root) else []):
        directory = os.path.join(root, name)
        if not os.path.isdir(directory):
            continue
        tags = sorted(f[:-6] for f in os.listdir(directory)
                      if f.endswith(".jsonl"))
        # Either half is enough to be worth listing: a recording whose run was
        # cancelled before anything ran still has its metadata, and one whose
        # metadata never got written still has the streams.
        if not tags and not os.path.isfile(os.path.join(directory, META)):
            continue
        meta = _read_meta(directory)
        out.append({
            "name": name,
            "recordedAt": meta.get("recordedAt", 0),
            "packages": len(meta.get("packages") or []),
            "tags": tags,
            "seconds": round(max([_span(directory, t) for t in tags] or [0])),
        })
    out.sort(key=lambda r: r["recordedAt"], reverse=True)
    print(json.dumps(out, ensure_ascii=False))
    return 0


def cmd_meta(directory):
    print(json.dumps(_read_meta(directory), ensure_ascii=False))
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    mode = argv[1]
    if mode == "begin" and len(argv) >= 5:
        return cmd_begin(argv[2], argv[3], argv[4])
    if mode == "record" and len(argv) >= 5:
        rest = argv[4:]
        if rest and rest[0] == "--":
            rest = rest[1:]
        return cmd_record(argv[2], argv[3], rest)
    if mode == "play" and len(argv) >= 4:
        speed = 1.0
        if "--speed" in argv:
            try:
                speed = float(argv[argv.index("--speed") + 1])
            except (IndexError, ValueError):
                speed = 1.0
        return cmd_play(argv[2], argv[3], speed)
    if mode == "list" and len(argv) >= 3:
        return cmd_list(argv[2])
    if mode == "meta" and len(argv) >= 3:
        return cmd_meta(argv[2])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
