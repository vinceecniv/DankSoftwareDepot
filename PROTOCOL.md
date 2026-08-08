# Package-helper event protocol

The QML layer never scrapes package-manager output. Every transaction runs
through a small privileged helper that talks to the package manager's
*library* and reports newline-delimited JSON (NDJSON) events on stdout.
Three helpers implement the protocol today:

| Helper | Library | Covers |
|---|---|---|
| `scripts/rpm_helper.py` | libdnf5 (python3-libdnf5) | rpm install / remove / upgrade / downgrade / plan |
| `scripts/apt_helper.py` | python-apt (python3-apt) | deb install / remove / upgrade / downgrade / plan |
| `scripts/pacman_helper.py` | pyalpm | pacman install / remove / upgrade / plan (official repos only, no AUR) |
| `scripts/flatpak_helper.py` | libflatpak (gi) | flatpak update / install (+ eol listing) |

`Backend.qml` picks the transaction helper from the detected distro
family (`/etc/os-release`). The protocol is deliberately package-
manager-agnostic — the QML layer needs no changes per backend. See
[Porting inventory](#porting-inventory) for what lives outside it.

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

**Distro-specific, outside the protocol.** The metadata layer dispatches
per backend: on Fedora the dnf code paths in `enrich.py` run; on the
Debian family `scripts/pkg_backend.py` provides the apt implementations.

| Area | dnf | apt |
|---|---|---|
| Update checks & counts | DMS `SystemUpdateService` daemon | same daemon (backend support on the DMS side) |
| Shell self-update pass | DMS daemon — must survive the shell reload | same |
| Post-run verification | `rpm -q` version compare | `dpkg-query -W` (via `Backend.installedVersionsCommand`) |
| Name search fallback | dnf repoquery | `pkg_backend.name_search` |
| Package info fallback | dnf repoquery --info | `pkg_backend.package_info` |
| Update sizes | dnf repoquery --info | `pkg_backend.update_sizes` |
| Previous versions / restore | `dnf repoquery` + helper `downgrade` | `pkg_backend.available_versions` + helper `downgrade name=version` |
| Held packages | dnf versionlock/excludepkgs + DMS ignored list | `apt-mark showhold` + DMS ignored list |
| Installed inventory & dashboard | `rpm -qa` | `pkg_backend.installed_table` / `dashboard` (`.list` mtimes as install times) |
| Reboot recommendation | kernel/glibc/… name pattern | linux-image/libc6/… pattern (`Backend.rebootPackagePattern`) |
| Distro upgrade notice | Bodhi (Fedora releases) | not offered |
| Package changelogs | dnf/rpm changelog | `/usr/share/doc/<pkg>/changelog.Debian.gz` — the installed version, read locally |
| AppStream catalog for system apps | Fedora swcatalog XML | DEP-11 YAML from apt's lists and the appstream cache |

The pacman column of `pkg_backend.py` mirrors the same functions via a
read-only libalpm handle: real install dates, IgnorePkg holds, an
AUR/foreign count on the dashboard, and an always-empty previous-versions
answer (pacman repos keep no history). Its changelog answer comes from
`pacman -Qc`, which is empty for the many packages that ship none; Arch
reads its AppStream catalog from the same XML paths as Fedora, filled by
`archlinux-appstream-data`. AUR is deliberately out of scope for
transactions: read-only awareness (update notices via the AUR RPC) is a
possible later step; building or installing AUR packages from a GUI is
not — the interactive PKGBUILD review exists for safety.

Two notes on the metadata sources, both of which apply to Fedora too:
changelogs and AppStream data are only as present as their distro
package (`appstream-data`, `appstream`, `archlinux-appstream-data`) —
without it, names and icons fall back to the package manager and the
desktop entries on disk. And a package's changelog outside dnf describes
the *installed* version: fetching the pending version's changelog would
mean a network round trip inside a synchronous popup, which is not worth
it.

Known open item for parity: confirming the DMS daemon's update checks on
real installs of both families. The metadata layer itself is complete.
