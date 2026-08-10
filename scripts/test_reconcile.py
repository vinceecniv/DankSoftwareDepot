#!/usr/bin/env python3
"""Exercise the "who changed this machine" comparison without a machine.

The whole answer rests on one judgement: whether a burst of package installs
can be explained by something this app logged. Two ways to get it wrong, and
both are worse than saying nothing. Calling one of our own runs a stranger
teaches people to distrust the number; missing a real one is the feature not
working. The cases below are the ones that decide it — chiefly that
dependencies count as ours, because the log names what was asked for and dnf
installs what that needs.

Run from anywhere:  python3 scripts/test_reconcile.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reconcile

failures = []


def check(label, got, want):
    ok = got == want
    print(("  ok   " if ok else "  FOUT ") + label)
    if not ok:
        print(f"         verwacht: {want!r}")
        print(f"         gekregen: {got!r}")
        failures.append(label)


HOUR = 3600
DAY = 86400
T = 1_780_000_000  # a fixed "now"; the logic only ever compares differences

print("Bursts uit elkaar halen")
check("wijzigingen dicht op elkaar zijn één gelegenheid",
      len(reconcile.cluster([(T, "a"), (T + 60, "b"), (T + 120, "c")])), 1)
check("een gat van een uur splitst",
      len(reconcile.cluster([(T, "a"), (T + HOUR, "b")])), 2)
check("niets in, niets uit", reconcile.cluster([]), [])

print("\nWie was het")
# A run this app performed: the log entry is written when it finishes, which
# is a good while after the first package landed
ours = [(T, "gimp"), (T + 30, "babl"), (T + 45, "gegl")]
check("een gelogde ronde is van ons", reconcile.unaccounted(ours, [T + 20 * 60]), [])
check("meegekomen afhankelijkheden ook — er wordt op tijd gematcht, niet op naam",
      reconcile.unaccounted(ours, [T + 20 * 60]), [])
check("zonder logboekregel is het een vreemde",
      [len(c) for c in reconcile.unaccounted(ours, [])], [3])
check("een logboekregel van een andere dag verklaart niets",
      [len(c) for c in reconcile.unaccounted(ours, [T - 3 * DAY])], [3])

# A long run: first package in at T, the log written 40 minutes later
long_run = [(T + i * 60, "pkg%d" % i) for i in range(40)]
check("een lange ronde wordt door zijn eigen regel aan het eind gedekt",
      reconcile.unaccounted(long_run, [T + 40 * 60]), [])

mixed = [(T, "ours-1"), (T + 60, "ours-2"),
         (T + 5 * DAY, "stranger-1"), (T + 5 * DAY + 30, "stranger-2"),
         (T + 9 * DAY, "ours-3")]
result = reconcile.unaccounted(mixed, [T + 10 * 60, T + 9 * DAY + 10 * 60])
check("alleen de onverklaarde burst blijft over", [len(c) for c in result], [2])
check("en het zijn de juiste pakketten",
      [name for _, name in result[0]], ["stranger-1", "stranger-2"])

print("\nRandgevallen")
check("geen wijzigingen, geen beschuldigingen", reconcile.unaccounted([], [T]), [])
check("ongesorteerde invoer wordt eerst gesorteerd",
      [len(c) for c in reconcile.unaccounted([(T + 60, "b"), (T, "a")], [])], [2])
check("de slack telt aan beide kanten",
      reconcile.unaccounted([(T, "a")], [T + reconcile.MATCH_SLACK - 60]), [])
check("net buiten de slack telt niet mee",
      [len(c) for c in reconcile.unaccounted([(T, "a")], [T + reconcile.MATCH_SLACK + 60])], [1])

print()
if failures:
    print(f"{len(failures)} controle(s) mislukt")
    sys.exit(1)
print("alles goed")
