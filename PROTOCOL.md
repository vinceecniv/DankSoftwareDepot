# Package-helper event protocol

The QML layer never scrapes package-manager output. Every transaction runs
through a small privileged helper that talks to the package manager's
*library* and reports newline-delimited JSON (NDJSON) events on stdout.
Three helpers implement the protocol today:

| Helper | Library | Covers |
|---|---|---|
| `scripts/rpm_helper.py` | libdnf5 (python3-libdnf5) | rpm install / remove / upgrade / downgrade / plan |
| `scripts/apt_helper.py` | python-apt (python3-apt) | deb install / remove / upgrade / downgrade / plan |
| `scripts/flatpak_helper.py` | libflatpak (gi) | flatpak update / install (+ eol listing) |

`Backend.qml` picks the transaction helper from the detected distro
family (`/etc/os-release`). The protocol is deliberately package-manager-
agnostic: an Arch port ships a `pacman_helper.py` (pyalpm) speaking the
same events, and the QML layer needs no changes at the transaction
level. See [Porting inventory](#porting-inventory) for what lives
outside this protocol.

## CLI contract

```
<helper> <action> <spec>...
```

- Actions: `install`, `remove`, `upgrade`, `downgrade`, `plan`.
- `<spec>` is a package name or name-version in the package manager's
  native spec syntax. Dependencies are the resolver's job — callers pass
  the packages the user chose, never a dependency closure.
- Transactions require root (run via `pkexec`). `plan` resolves against
  the existing metadata cache, prints the `plan` event and exits — it must
  work unprivileged and make no changes.
- stdout carries only NDJSON events. stderr is free-form (never parsed).
- Exit code 0 on success, 1 on failure, 2 on usage errors. Regardless of
  the exit path, the last event on stdout is always `done`.

## Events

One JSON object per line. Unknown fields and unknown event types must be
ignored by consumers (forward compatibility).

| Event | Fields | Meaning |
|---|---|---|
| `status` | `message` | Coarse state before the plan exists (`"repos"` = refreshing repo metadata) |
| `plan` | `ops: [{name, evr, action, downloadBytes, installBytes}]`, `totalDownloadBytes` | The resolved transaction. `action` is a human string (`Install`, `Upgrade`, `Remove`, …); outbound-only ops have `downloadBytes: 0` |
| `op-start` | `name`, `phase`, `bytesTotal`? (download), `index`/`total`? (install/remove) | Work on one package begins in the given phase |
| `progress` | `name`, `phase`, `percent`, download also: `bytesTransferred`, `bytesTotal`, `totalTransferred` | Per-package progress. `percent` is the package's own 0–100 |
| `op-done` | `name`, `phase`, `totalTransferred`? | The package finished this phase |
| `op-error` | `name`, `phase`, `message` | The package failed this phase |
| `script` | `name` | A scriptlet/hook of that package is running |
| `warning` | `message` | Non-fatal problem worth surfacing in logs |
| `error` | `message` | Fatal problem (resolution, transaction). Followed by `done` |
| `done` | `ok`, `failed: [spec]`, `nothingToDo`? | Always the final event |

Phases: `download`, `install`, `remove`. Package managers without a
distinct download phase simply never emit it.

### Invariants

- `totalTransferred` is the byte sum across **all** downloads of the
  transaction and is monotonically non-decreasing. UIs derive their
  overall download bar from `totalTransferred / totalDownloadBytes` —
  never from interleaved per-package percentages (parallel downloads make
  those jump).
- When a download ends, any bytes not yet reported are folded into
  `totalTransferred`, so it reaches `totalDownloadBytes` exactly.
- Install/remove phases are serial: `index`/`total` on `op-start` order
  the transaction; `percent` covers the current package only.
- Events for a package may interleave with other packages during the
  download phase, never during install/remove.
- Emitting `progress` at most on integer-percent changes keeps event
  volume bounded.

## Porting inventory

What a Debian/Arch port must provide, beyond a protocol helper:

**Neutral already** (no work): `flatpak_helper.py`, `appimage.py`, fwupd
firmware (fwupdmgr/LVFS), reviews (ODRS), Flathub metadata, the whole QML
layer at transaction level.

**The transaction seam** — `Backend.qml` holds the helper path the QML
call sites use. A port swaps this (or branches on the detected distro).

**Distro-specific, outside the protocol** (each needs a per-backend
implementation):

| Area | Current implementation |
|---|---|
| Update checks & counts | DMS `SystemUpdateService` daemon (multi-backend on the DMS side) |
| Shell self-update pass | DMS daemon (`DMSService.sysupdateUpgrade`) — must survive the shell reload |
| Post-run verification | `Backend.installedVersionsCommand`: `rpm -q` / `dpkg-query -W` version compare |
| Search & app metadata | `scripts/enrich.py`: dnf repoquery/search, rpm changelog, AppStream |
| Update sizes | `dnf repoquery --info` (`--update-sizes`) |
| Previous versions / restore | `dnf5 --showduplicates` + helper `downgrade` |
| Held packages | dnf versionlock/excludepkgs + DMS ignored list |
| Installed inventory & dashboard | `rpm -qa` (counts, recently-updated) |
| Distro upgrade notice | Bodhi (Fedora releases) |

The QML layer treats all of these as opaque data sources, so ports are a
matter of implementing the same script entry points per backend — the
protocol above stays identical.
