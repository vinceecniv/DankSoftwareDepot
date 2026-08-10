#!/usr/bin/env python3
"""What changed on this machine that this app did not do.

The package database knows when every package last arrived; the action log
knows what this plugin did. Anything in the first that the second cannot
account for was somebody else: dnf-automatic, a terminal, GNOME Software, an
unattended-upgrade timer, another person over SSH. That gap is worth showing
— it is the first thing anyone wants when they wonder why their system is not
what they left it as, and without it the log quietly reads like a complete
record when it is only a record of this window.

Matched on time rather than on name, deliberately. Installing one package
pulls in its dependencies and the log names only what was asked for, so
name-matching would report every dependency as a stranger. The honest
question is not "did this app name this package" but "was this app doing
something at that moment", and clusters of install times answer it.

    reconcile.py [days]     → JSON on stdout (default 90 days)
"""
import json
import os
import subprocess
import sys
import time

import pkg_backend

LOG_FILE = os.path.join(
    os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
    "dankSoftwareDepot", "action-log.json")

# Package installs land in a burst; anything within a quarter of an hour of
# the last one belongs to the same occasion
CLUSTER_GAP = 15 * 60
# A run logs itself when it finishes, which can be a long way after its first
# package went in. Generous on purpose: claiming one of our own runs as a
# stranger is a worse mistake than missing a real one.
MATCH_SLACK = 2 * 3600
SAMPLE_LIMIT = 8


def install_times():
    """[(name, installtime)] for everything installed, newest first."""
    rows = []
    if pkg_backend.detect() != "dnf":
        try:
            for line in pkg_backend.installed_table().splitlines():
                fields = line.split("\t")
                if len(fields) >= 4 and fields[3].isdigit():
                    rows.append((fields[0], int(fields[3])))
        except Exception:
            pass
        return rows
    try:
        res = subprocess.run(["rpm", "-qa", "--qf", "%{NAME}\t%{INSTALLTIME}\n"],
                             capture_output=True, text=True, timeout=30)
        for line in res.stdout.splitlines():
            fields = line.split("\t")
            if len(fields) == 2 and fields[1].isdigit():
                rows.append((fields[0], int(fields[1])))
    except (OSError, subprocess.SubprocessError):
        pass
    return rows


def log_times():
    try:
        with open(LOG_FILE) as f:
            entries = json.load(f)
        return sorted(int(e.get("ts", 0)) for e in entries if isinstance(e, dict) and e.get("ts"))
    except (OSError, ValueError, TypeError):
        return []


def cluster(changes):
    """[(ts, name)] sorted by time → list of bursts."""
    if not changes:
        return []
    clusters = []
    current = [changes[0]]
    for ts, name in changes[1:]:
        if ts - current[-1][0] > CLUSTER_GAP:
            clusters.append(current)
            current = []
        current.append((ts, name))
    clusters.append(current)
    return clusters


def unaccounted(changes, logs):
    """The bursts no log entry can explain. Pure, so it can be tested
    without a package database or a machine that has been left alone."""
    return [c for c in cluster(sorted(changes))
            if not any(c[0][0] - MATCH_SLACK <= ts <= c[-1][0] + MATCH_SLACK for ts in logs)]


def main():
    days = 90
    if len(sys.argv) >= 2 and sys.argv[1].isdigit():
        days = max(1, int(sys.argv[1]))

    logs = log_times()
    now = int(time.time())
    # Before the log's first entry there is nothing to compare against, so
    # that stretch is unknown rather than unaccounted for — a plugin
    # installed last week must not report the system's own installation as a
    # stranger's work
    window_from = now - days * 86400
    if logs:
        window_from = max(window_from, logs[0])

    changes = sorted(((ts, name) for name, ts in install_times() if ts >= window_from))
    if not changes:
        json.dump({"packages": 0, "occasions": 0, "windowFrom": window_from,
                   "logStart": logs[0] if logs else 0, "lastTs": 0, "samples": []}, sys.stdout)
        return

    strangers = unaccounted(changes, logs)
    packages = sum(len(c) for c in strangers)
    samples = []
    for burst in reversed(strangers):
        for ts, name in reversed(burst):
            samples.append({"name": name, "ts": ts})
            if len(samples) >= SAMPLE_LIMIT:
                break
        if len(samples) >= SAMPLE_LIMIT:
            break

    json.dump({
        "packages": packages,
        "occasions": len(strangers),
        "windowFrom": window_from,
        "logStart": logs[0] if logs else 0,
        "lastTs": strangers[-1][-1][0] if strangers else 0,
        "samples": samples,
    }, sys.stdout)


if __name__ == "__main__":
    main()
