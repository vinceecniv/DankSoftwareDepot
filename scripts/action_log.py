#!/usr/bin/env python3
"""Persistent action log for dankSoftwareDepot.

Called with a JSON entry as argv[1] it appends the entry; called without
arguments it only reads. Either way it prunes entries older than the
retention window and prints the resulting log (newest last) to stdout.
"""
import json
import os
import sys
import time

LOG_DIR = os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")), "dankSoftwareDepot")
LOG_FILE = os.path.join(LOG_DIR, "action-log.json")
RETENTION_SECONDS = 90 * 24 * 3600


def main():
    try:
        with open(LOG_FILE) as f:
            entries = json.load(f)
        if not isinstance(entries, list):
            entries = []
    except (OSError, ValueError):
        entries = []

    changed = False
    if len(sys.argv) >= 2:
        try:
            entry = json.loads(sys.argv[1])
            if isinstance(entry, dict) and entry.get("type"):
                entry.setdefault("ts", int(time.time()))
                entries.append(entry)
                changed = True
        except ValueError:
            pass

    cutoff = time.time() - RETENTION_SECONDS
    pruned = [e for e in entries if isinstance(e, dict) and e.get("ts", 0) >= cutoff]
    if len(pruned) != len(entries):
        changed = True
    entries = pruned

    if changed:
        try:
            os.makedirs(LOG_DIR, exist_ok=True)
            tmp = LOG_FILE + ".tmp"
            with open(tmp, "w") as f:
                json.dump(entries, f)
            os.replace(tmp, LOG_FILE)
        except OSError:
            pass

    json.dump(entries, sys.stdout)


main()
