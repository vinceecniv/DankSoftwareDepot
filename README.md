# <picture><source media="(prefers-color-scheme: dark)" srcset="assets/icons/dank-software-depot-dark.svg"><img src="assets/icons/dank-software-depot-light.svg" alt="" width="42"></picture> Dank Software Depot

**Beta** · **Fedora-based distros (atomic Fedora, Debian/Ubuntu & Arch experimental)** · English / Nederlands / Deutsch / Français / Español / Português / Italiano / Polski / Svenska / Українська / Русский / Magyar / 日本語 / 한국어 / Tiếng Việt / 中文

A full software & updates center plugin for
[DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell):
everything the built-in updater does, plus app logos, release notes, reviews,
honest per-package progress, an app store, [full AppImage
management](#appimages-end-to-end), firmware support and an action log — and no
terminal output anywhere.

Four kinds of software, managed the same way: system packages, Flatpaks,
AppImages and firmware. Beyond what the system already knows about, it can
[search Copr](#3--install) for packages no configured repository carries, and
it can be [the app that opens a downloaded
`.appimage`](#appimages-end-to-end).

![screenshot](screenshot.png)

Built on top of the DMS system update service (the `dms` daemon does update
detection and dnf transactions; polkit prompts appear through the DMS agent).

## Status

- **Beta.** Actively developed; things may move around. Feedback and issues
  are welcome.
- **Fedora-based distros first** (Fedora, Nobara, RHEL/CentOS family):
  package management uses libdnf5 and Fedora AppStream metadata.
  **Debian/Ubuntu and Arch support is experimental**: transactions
  (python-apt / pyalpm), search, sizes, inventory, holds, changelogs and
  the AppStream catalog are implemented, but not yet validated on real
  desktop installs — see PROTOCOL.md for what is left. AUR is out of
  scope (official Arch repos only). The app shows an experimental banner
  on these distros and warns on unsupported ones. Flatpak, AppImage and
  firmware support are distro-agnostic.
- **An atomic Fedora (Silverblue, Kinoite, Bazzite, Bluefin) is
  experimental too.** Detected by `/run/ostree-booted` and driven through
  `rpm-ostree` instead of libdnf5: installing layers a package, removing
  unlayers one, and an update is the whole deployment rather than a
  choice of packages. Everything lands in the *next* boot, so a finished
  transaction says "takes effect after reboot" and raises the reboot
  notice instead of claiming the package is in use. Removing something
  that came with the image is refused with a reason — that needs an
  override, which is a different promise. See PROTOCOL.md for the whole
  table of differences.

## The five tabs

### 1 · Updates
- Rich update cards: logo, name, summary, `old → new` versions, repo chip,
  homepage link, expandable sanitized release notes (AppStream releases for
  apps, rpm changelog fallback), per-app update button
- **Packages built from git** (a `*-git` Copr, an AUR `-git` build) have no
  release for the distro to describe, so their notes come from the upstream
  forge instead: the published notes of the release being installed, or the
  commits between the two snapshots when both sides are builds of a branch
- Sections (Applications / System / Runtimes / Firmware / Held)
  with a hover **Update these** button per section
- **Held packages**: dnf versionlock/excludepkgs detected automatically,
  plus user-holds via the lock button — never counted or updated,
  releasable any time
- **Automatic updates**: off / notify only / auto-install Flatpaks
- During a run the list regroups by what is happening — **In progress**,
  **Waiting**, **Completed** (collapsed) — so the packages actually being
  worked on are the first thing on screen. Each row has its own progress
  bar built from real bytes (flatpak transaction events, libdnf5 callbacks)
- A package that fails keeps its reason on its card, including after the
  shell reload a DMS update causes, with the tool's verbatim output one
  click away under **Show details** — the same detail the action log keeps
- Reboot recommendation banner (kernel/systemd/glibc/firmware) with
  confirm-restart button, persisted per boot
- End-of-life Flatpak detection and distro-upgrade notice
- **DMS updates run last**: updating DMS/Quickshell packages live-reloads
  the shell, so they run in a final daemon pass after everything else
  (the transaction completes even if the shell reloads mid-way)
- Up-to-date dashboard: installed-software counts per source, system info,
  recently updated packages and the current updater status at a glance

### 2 · Installed
- All Flatpak apps, rpm packages and AppImages in one list: live search,
  source filter, sorting (name / largest / recently updated) with sizes
- **Applications first, supporting packages after**: anything that owns a
  desktop entry your launcher would show counts as an application, in its
  own group with a count — which is also where packages outside AppStream
  get their icon and name from
- Details popup per app: description, screenshots, star ratings and review
  texts (ODRS), release notes / changelog, homepage, sandbox permissions —
  and you can write a review yourself
- Actions: uninstall (with confirm), hold toggle, open, restore a previous
  version (Flatpak via commit history, rpm via `dnf downgrade` where repos
  still carry an older build)
- **AppImage update source**: link a GitHub project to any AppImage in the
  popup and its releases become the update channel
- Live progress on every mutation: phase text and an animated progress bar
  ("Loading repositories…", "Removing 2/3 · 67%", …)

### 3 · Install
- **Popular-software storefront** before you search: most-reviewed apps
  (ODRS) grouped by category, one-click install
- Live search across the system repos and Flathub (cached AppStream
  index), plus a package-name fallback so plain CLI packages
  (e.g. `playerctl`) are found too
- **Source choice** when an app ships from multiple sources
  (system repo / Flathub / AppImage)
- **Search Copr** for software no configured repository has. Nothing in Copr
  can turn up in a local search — a package there is invisible to dnf until
  its project is enabled — so the Install tab offers the search as one
  deliberate press rather than a request per keystroke. Results are listed
  apart, under the name of the individual who builds them, and only from
  projects that build for this Fedora and architecture: a Copr that stopped at
  the previous release cannot be enabled here and is not offered. Installing
  one adds its repository as part of the same transaction, so it asks for a
  password once rather than twice
- ODRS star ratings with review counts
- Live install progress: package-manager library and libflatpak events are
  turned into a progress panel with app icon, phase text and a transaction-
  wide percentage (repositories → download x/y → install)
- **Software sources** behind the header button (or Ctrl+K → Software
  sources): the configured repositories with enable/disable switches, the
  Flatpak remotes, one-click RPM Fusion and Flathub where they are missing,
  and Copr add/remove. Debug, source and testing repositories are folded away
  — on a normal Fedora they are two thirds of the list. Switching off a
  repository the distribution is made of asks twice; writing a repository
  definition by hand stays a job for a text editor. Only the dnf family can be
  changed from here: apt and pacman sources are shown read-only, because an
  apt source is a file plus a signing key and a pacman repo lives in a single
  hand-edited `pacman.conf`.
- **AppImages** are searched, installed and offered from here alongside
  everything else — see [AppImages, end to end](#appimages-end-to-end)

### 4 · Firmware
- fwupd device inventory: which hardware supports firmware updates, current
  versions, on-demand LVFS release notes
- Pending firmware updates appear in the Updates tab and run in the firmware
  phase of Update All

### 5 · Log
- Persistent history of everything the plugin did: update runs, installs,
  uninstalls, restores/downgrades — entries expand to per-package details
  (old → new version, source, result)
- Searchable; entries are kept for 90 days

## AppImages, end to end

An AppImage is a file, not a package: nothing knows it exists, nothing tells
you when it changes, and deleting it leaves its menu entry behind. The whole
life of one is handled here, so it is managed software like anything else.

- **Find one**: searchable catalog of the appimage.github.io index (1400+
  apps), listed next to repo and Flathub results with a source choice when an
  app ships more than one way
- **Install one** from the app's own GitHub releases, from a URL, or from a
  file you already have. They land in `~/AppImages` — created on first install,
  the same folder Gearlever uses by default, and its own setting is honoured
  when it points elsewhere
- **Double-click a downloaded `.appimage`** and the window opens on that file,
  offering to install it —
  or to **replace the build already installed** when it recognises one, matched
  on the name inside the image rather than the version in the file name. A
  fresh download is never executable, which is exactly the case where
  double-clicking otherwise does nothing at all; the file is read without being
  modified. The association is on by default, claimed once and only when
  `.appimage` is going spare — another app already holding it was somebody's
  choice and is left alone. Settings → *Open .appimage files with this app*
  takes it back or hands it over at any time
- **It shows up like an app**: icon and desktop entry are extracted from the
  image, so it appears in your launcher with the right name and logo
- **Existing AppImages are adopted automatically** — the folder is scanned, and
  images installed before this plugin existed are managed from then on
- **Updates**: link a GitHub project to any AppImage and its releases become
  the update channel. Pending AppImage updates appear in the Updates tab and
  run in their own phase of Update All, with byte progress
- **Uninstall** takes the file, its desktop entry, its icon and its record

## Bar widget & popout

- Bar pill with the effective update count (held excluded);
  spinning refresh icon while checking, completed/planned counter during a
  run, restart icon when a reboot is recommended
- Compact popout: enriched update list, Update All, phase label and
  current item during a run. While a check runs, the Dank logo stays where it
  is and pulses — the same two rings the shell's own System Check page uses —
  instead of being replaced by a spinner
- Optional: hide the pill when up to date, click opens the window directly

## Languages

The UI ships in **English, Dutch, German, French, Spanish, Portuguese,
Italian, Polish, Swedish, Ukrainian, Russian, Hungarian, Japanese, Korean,
Vietnamese and Chinese (Simplified)** — sixteen languages. DMS has no per-plugin
i18n mechanism, so the plugin brings its own: the `Tr` singleton loads
`translations/<lang>.json` (keyed by the English source string) following the
DMS/system locale, falling back to the DMS catalog and then English. Add a
language by dropping a new `translations/<lang>.json` next to the others.

## Requirements

- A Fedora-based distribution — or an atomic Fedora, Debian/Ubuntu or Arch
  (all three experimental)
- DMS ≥ 1.5 with the `sysupdate` daemon capability
- `python3`, `python3-gobject` + libflatpak GIR
- `flatpak`, optionally `fwupd`
- Package-manager bindings for your distro:
  - Fedora: `python3-libdnf5` (**not** part of a default install)
  - Atomic Fedora: nothing extra — `rpm-ostree` is the image's own tool
  - Debian/Ubuntu: `python3-apt` (usually preinstalled)
  - Arch: `pyalpm`

Without those bindings no system package can be installed, updated or
removed; the plugin checks for them at startup and offers to install what
is missing.

Optional, for richer app information (names, icons, screenshots and
release notes for system packages): the AppStream catalog for your
distro — `appstream-data` on Fedora, `appstream` on Debian/Ubuntu,
`archlinux-appstream-data` on Arch. Without it the plugin falls back to
the package manager's own summaries and the icons in your desktop
entries, so apps still look like apps.

## Install

```bash
git clone https://github.com/vinceecniv/DankSoftwareDepot ~/.config/DankMaterialShell/plugins/dankSoftwareDepot
dms restart
```

Enable **Dank Software Depot** in DMS Settings → Plugins, then add the widget
to a DankBar layout.

To launch the window from the app launcher like a standalone app, let the app
place the entry itself: the Updates tab offers it once ("Add"), and
**Settings → Show in app launcher** switches it on or off at any time. Both
write a desktop entry and its icon into your own home directory — no root, and
removing the switch takes them away again.

The same by hand, if you would rather (the entry names the icon, so without the
second step the launcher shows a blank one):

```bash
sed "s|@OPEN@|$PWD/scripts/open.sh|" com.danklinux.dankSoftwareDepot.desktop \
  > ~/.local/share/applications/com.danklinux.dankSoftwareDepot.desktop
chmod +x scripts/open.sh
install -Dm644 assets/icons/dank-software-depot-dark.svg \
  ~/.local/share/icons/hicolor/scalable/apps/dank-software-depot.svg
install -Dm644 assets/icons/dank-software-depot-symbolic.svg \
  ~/.local/share/icons/hicolor/symbolic/apps/dank-software-depot-symbolic.svg
update-desktop-database ~/.local/share/applications
```

The entry runs `scripts/open.sh`, which calls the IPC below — so DMS must be
running; it opens the window in the shell rather than starting a second
process. The shim exists because a launcher gives a program a narrower `PATH`
than a terminal does, and `dms ipc` needs both `dms` and `qs` on it; and
because `dms ipc call` answers success even when it reached nobody. Either way
the entry used to do nothing at all, silently. Now it looks in the usual places
and, if it still cannot get through, says so in a notification.

An entry written by an older version of the plugin carries no
`X-DSD-Entry-Version` stamp and is rewritten once, automatically, the next time
the window opens — there is nothing to redo by hand.

### IPC

```bash
dms ipc call dankSoftwareDepot open      # open the window
dms ipc call dankSoftwareDepot toggle
dms ipc call dankSoftwareDepot tab 2     # open a specific tab (0-4)
dms ipc call dankSoftwareDepot check     # trigger an update check
dms ipc call dankSoftwareDepot openAppimage /path/to/App.AppImage
```

## Network and privacy

The plugin contains **no tracking of any kind**: no analytics, no telemetry, no
crash reporting, and no identifier that follows you. There is no server
belonging to this project — nothing is ever sent to its author.

One request happens without you asking for it: half a minute after the shell
starts, and once a day after that, the plugin fetches its own `plugin.json` and
`CHANGELOG.md` from GitHub to see whether a newer version exists. It is a plain
file fetch with no parameters and nothing identifying, and it is skipped
entirely when the plugin directory is a symlink (a development checkout).
Everything else below happens because you opened, checked or pressed
something.

It does talk to the network, because a software centre without a network is a
list of things you already have. Everything it contacts, and when:

| Where | What for | When |
|---|---|---|
| your configured repositories, Flatpak remotes, LVFS | the package work itself: metadata, downloads, firmware | checking and updating |
| `raw.githubusercontent.com` | this plugin's own `plugin.json` and `CHANGELOG.md`, to offer its update | 30 seconds after the shell starts, then daily; never on a symlinked install |
| `odrs.gnome.org` | star ratings and review texts (Open Desktop Ratings Service) | opening an app's details |
| `flathub.org/api/v2` | install counts, download size, sandbox permissions, verified status | opening a Flatpak app's details |
| the screenshot URLs in AppStream data | the screenshots themselves, cached locally for 30 days | opening an app's details |
| `appimage.github.io`, `api.github.com` | the AppImage catalogue and the releases of an AppImage's linked project | the Install tab and AppImage updates |
| `api.github.com` | for a package built from git, the notes of the release being installed or the commits between two snapshots — the repository comes from the package's own URL field | opening the details of such an update; answers cached a day, and a package not built from git never asks |
| `bodhi.fedoraproject.org` | which Fedora releases are current, for the release-upgrade notice | the upgrade check |
| `copr.fedorainfracloud.org` | which Coprs build a package matching your search, and for which Fedora | only when you press Search Copr; answers cached six hours |
| `mirrors.rpmfusion.org`, `dl.flathub.org`, `nightly.gnome.org`, `cdn.kde.org`, `registry.fedoraproject.org` | fetching a source you asked to add | only when you press Add in Software sources |

Two details worth stating plainly, because they are the only places where
anything about you leaves the machine:

- **Reading reviews** sends a `user_hash` that is the same constant for every
  installation (`sha1("dankSoftwareDepot")`). ODRS requires the field; this
  one identifies nobody.
- **Writing a review** is different, and is the only outgoing request that
  carries anything machine-specific. ODRS deduplicates and moderates by user,
  so the submission carries a hash of your username and `/etc/machine-id`,
  along with the display name you type. Leave that field empty and your login
  name is published instead — which is why the field says so before you press
  send. Nothing is submitted unless you write a review and press the button.

## Architecture

| Piece | Role |
|---|---|
| `UpdaterWidget.qml` | Bar pill, popout, IPC, reboot logic, settings |
| `UpdaterWindow.qml` | Tabbed window (Updates / Installed / Install / Firmware / Log) |
| `UpdateCard.qml` | Rich per-update card |
| `InstalledView.qml` | Installed software browser + actions |
| `InstallView.qml` | Storefront + cross-source software search & install |
| `FirmwareView.qml` | fwupd device inventory |
| `LogView.qml` | Action history browser |
| `AppDetailsDialog.qml` | Shared app-details popup (info, reviews, actions) |
| `AppimageOfferDialog.qml` | Installing an AppImage from a file or URL — the toolbar button and a double-clicked `.appimage` both land here |
| `PulseRings.qml` | The shell's System Check pulse, borrowed so a check can happen around the logo instead of over it |
| `UpdateEngine.qml` | Run orchestration (daemon dnf → libflatpak → fwupd → DMS packages), per-package progress from log lines and dnf-cache bytes |
| `MetadataStore.qml` | Async enrichment cache + held-state persistence |
| `ActionLog.qml` | Persistent action history (90-day retention) |
| `FirmwareService.qml` | fwupd update detection |
| `PhaseIndicator.qml` | Material phase stepper |
| `Tr.qml` | Plugin-local translation singleton |
| `scripts/enrich.py` | AppStream parsing, dnf fallbacks, holds detection, search index, featured storefront, ODRS ratings, upstream notes for git builds, caching, sanitizing |
| `scripts/rpm_helper.py` | libdnf5 transactions (install/remove/upgrade/downgrade) with exact byte progress (NDJSON events, see PROTOCOL.md) |
| `scripts/ostree_helper.py` | rpm-ostree counterpart of rpm_helper.py — experimental atomic-Fedora backend (layering, staged until reboot) |
| `scripts/apt_helper.py` | python-apt counterpart of rpm_helper.py — experimental Debian/Ubuntu transaction backend |
| `scripts/pacman_helper.py` | pyalpm counterpart of rpm_helper.py — experimental Arch transaction backend (official repos, no AUR) |
| `scripts/pkg_backend.py` | Per-distro metadata backend (search, sizes, inventory, holds, versions, changelogs); apt + pacman implemented, dnf stays in enrich.py. Also answers, for every distro, which packages own a launchable desktop entry |
| `scripts/check_translations.py` | Checks the 15 catalogs against the QML: identical key sets, every string the UI asks for, placeholders kept, keys nothing calls any more |
| `scripts/test_dep11.py` | Checks the DEP-11 and apt/pacman changelog paths against real-shaped data, runnable on any distro |
| `scripts/test_gitnotes.py` | Checks the upstream-notes path for git builds — snapshot versions, markdown reduction, the two forge answers — with the network stubbed |
| `scripts/flatpak_helper.py` | libflatpak transactions (updates & installs) with exact byte progress (NDJSON events) |
| `scripts/appimage.py` | AppImage catalog, install/replace/update/uninstall, GitHub update sources, adhoc folder scanning, inspecting a file before offering it, and the `.appimage` default-handler association (NDJSON events) |
| `scripts/repo_backend.py` | Software sources: reads the configured repositories and Flatpak remotes; enable/disable, Copr add/remove/search, RPM Fusion and Flathub (dnf family only; apt and pacman are listed read-only) |
| `scripts/action_log.py` | Action-log append/prune helper |
| `scripts/open.sh` | What the desktop entry runs: finds `dms` on a launcher's narrower PATH, opens the window or hands over a double-clicked AppImage, and turns a failed call into a notification instead of into silence |

Update detection, check interval and ignored packages remain managed by DMS
itself (Settings → System Updater); this plugin consumes that state.

All release-note/HTML content from external sources is reduced to an escaped
minimal markup subset before rendering.

## Development

This plugin is developed with [Claude Code](https://claude.com/claude-code)
and built with [Vito](https://vito.talk) — voice-driven development
([GitHub](https://github.com/vinceecniv/Vito)).

## License

MIT
