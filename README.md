# <picture><source media="(prefers-color-scheme: dark)" srcset="assets/icons/dank-software-depot-dark.svg"><img src="assets/icons/dank-software-depot-light.svg" alt="" width="42"></picture> Dank Software Depot

[![Release](https://img.shields.io/github/v/release/vinceecniv/DankSoftwareDepot?label=release&color=6750A4)](https://github.com/vinceecniv/DankSoftwareDepot/releases)
[![Checks](https://github.com/vinceecniv/DankSoftwareDepot/actions/workflows/checks.yml/badge.svg)](https://github.com/vinceecniv/DankSoftwareDepot/actions/workflows/checks.yml)
[![License](https://img.shields.io/badge/license-MIT-informational)](LICENSE)
![Status](https://img.shields.io/badge/status-beta-orange)
![DMS](https://img.shields.io/badge/DMS-%E2%89%A5%201.5-6750A4)
[![Languages](https://img.shields.io/badge/languages-16-6750A4)](#languages)

**Manages** ![System packages](https://img.shields.io/badge/system%20packages-dnf%20%C2%B7%20apt%20%C2%B7%20pacman%20%C2%B7%20rpm--ostree-4A4458)
![Flatpak](https://img.shields.io/badge/Flatpak-4A4458)
![AppImage](https://img.shields.io/badge/AppImage-4A4458)
![Firmware](https://img.shields.io/badge/firmware-fwupd%20%C2%B7%20LVFS-4A4458)
![DMS plugins](https://img.shields.io/badge/DMS%20plugins-4A4458)
![Homebrew](https://img.shields.io/badge/Homebrew-4A4458)

A full software & updates center plugin for
[DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell):
everything the built-in updater does, plus app logos, release notes, reviews,
honest per-package progress, an app store, [full AppImage
management](#appimages-end-to-end), firmware support and an action log — and no
terminal output anywhere.

Six kinds of software, managed the same way: system packages, Flatpaks,
AppImages, firmware, the DMS plugins running in the shell around it, and
Homebrew formulae where brew is installed. It can also [search
Copr](#3--install) for packages no configured repository carries, and be [the
app that opens a downloaded `.appimage`](#appimages-end-to-end).

![The Updates tab: pending updates as cards, graded by severity, with a size
and removal summary above Update All](screenshot.png)

Built on the DMS system update service: the `dms` daemon does update detection,
and polkit prompts appear through the DMS agent.

## Status

**Beta** — actively developed, things may move around. Feedback and issues are
welcome.

**Fedora-based distros first** (Fedora, Nobara, RHEL/CentOS): libdnf5 and
Fedora AppStream metadata. **Debian/Ubuntu and Arch are experimental** —
transactions, search, sizes, inventory, holds, changelogs and the AppStream
catalog are implemented but not yet validated on real desktop installs; AUR is
out of scope. **Atomic Fedora** (Silverblue, Kinoite, Bazzite, Bluefin) is
experimental too: driven through `rpm-ostree`, so installing layers a package
and everything lands in the *next* boot, and removing something that came with
the image is refused with a reason. The app says so in a banner on these
distros and warns on unsupported ones. Flatpak, AppImage and firmware support
are distro-agnostic. [PROTOCOL.md](PROTOCOL.md) has the full table of
differences.

## The five tabs

### 1 · Updates

- Rich update cards: logo, name, summary, `old → new`, homepage, expandable
  release notes (AppStream, with the rpm changelog as fallback), per-app update
  button
- Sections — Applications / System / Runtimes / Firmware / Homebrew / DMS
  plugins / Held — each with a hover **Update these** button, and a chip on the
  rows whose heading does not already say where they came from
- Section headings stay put while you scroll, in all four lists
- **Held packages**: dnf versionlock/excludepkgs detected automatically, plus
  your own holds via the lock button — never counted, never updated, releasable
  any time. A hold sitting on top of a security fix says so on the card
- **Security advisories** from the distro's updateinfo, read locally with no
  network: graded critical / important / moderate / low, with CVE numbers in
  the details popup and a count in the summary — including how many are held
  back
- **Packages built from git** (a `*-git` Copr, an AUR `-git` build) have no
  distro release to describe, so their notes come from the upstream forge: the
  release being installed, or the commits between two snapshots
- During a run the list regroups into **In progress**, **Waiting** and
  **Completed**, each row with its own progress bar built from real bytes
  (libflatpak events, libdnf5 callbacks). The stepper follows the work rather
  than the running order, so a run that starts fetching Flatpaks steps *back*
  to Downloading instead of standing on Installing
- A package that fails keeps its reason on its card — including after the shell
  reload a DMS update causes — with the tool's verbatim output one click away
  under **Show details**
- **DMS updates run last**: they live-reload the shell, so they go in a final
  daemon pass that completes even if the shell reloads mid-way
- **Arch Linux news** on the distribution that publishes it, since Arch
  announces in prose, ahead of time, that an update needs a hand. The banner
  appears only for something unread, the first fetch marks the backlog read
  rather than opening with eleven interruptions, and items are kept so the
  archive (Ctrl+K) still explains the state a machine is in
- **Homebrew formulae** on a machine that has brew: their own section, counted
  in the pill, upgraded in their own phase, with no privileges at all. Brew
  reports no machine-readable progress, so a formula goes from active to done;
  a pinned formula is left alone, and the index is refreshed at most every six
  hours
- **DMS plugins** are the fifth kind of software, listed and updated one at a
  time in their own phase. This plugin excludes itself and offers its own
  update from its own release notes instead. Installing and browsing plugins
  stays in DMS, one button away
- Reboot recommendation (kernel/systemd/glibc/firmware) with a confirm-restart
  button, persisted per boot; end-of-life Flatpak detection; a notice when a
  newer Fedora release is out
- **Automatic updates**: off / notify only / auto-install Flatpaks
- Up-to-date dashboard: installed-software counts per source, system info,
  recently updated packages, **reclaimable space** (packages nothing needs any
  more, and the download cache) and **the last year** read back out of the
  action log — how much went through here, the longest quiet stretch, the
  biggest run, the package you update most

| ![A run in progress: phase stepper, downloaded bytes, and a progress bar per package](screenshots/update-in-progress.png) | ![The up-to-date dashboard with installed-software counts, system info and recently updated packages](screenshots/updates-dashboard.png) |
|---|---|
| **A run in progress.** The list regroups around what is happening, and every row carries its own byte-accurate progress bar. | **Nothing to do.** Counts per source, system information, what was updated recently — and the reboot banner when one is recommended. |

### 2 · Installed

- All Flatpak apps, system packages and AppImages in one list: live search,
  source filter, sorting (name / largest / recently updated) with sizes
- **Applications first, supporting packages after** — anything owning a desktop
  entry your launcher would show, which is also where packages outside
  AppStream get their icon and name
- **Homebrew formulae** and **DMS plugins** have their own groups, the plugins
  read from the manifests on disk, with a details popup showing what a plugin
  has instead of what a package has: author, category, scope, location,
  declared permissions
- Details popup per app: description, screenshots, star ratings and review
  texts (ODRS), release notes, homepage, sandbox permissions — and you can
  write a review yourself
- **Where it comes from**: the same side-by-side comparison the Install tab
  offers, with the one you actually have marked as installed
- Actions: uninstall (with confirm), hold, open, and restore a previous version
  (Flatpak via commit history, rpm via `dnf downgrade` where the repos still
  carry one)
- Link a GitHub project to any AppImage and its releases become the update
  channel
- Live progress on every mutation: phase text and a bar, not terminal output

| ![The Installed tab: search, source filters, applications grouped before supporting packages](screenshots/installed-library.png) | ![The details popup for VLC with screenshots, description, sandbox permissions and reviews](screenshots/app-details.png) |
|---|---|
| **Everything installed, in one list.** Flatpaks, system packages and AppImages together, applications first. | **The details popup**, shared with the Install tab: screenshots, permissions, install counts and ODRS reviews. |

### 3 · Install

- **A storefront you can walk through** before you search: thirteen sections
  from Flathub's own categories, most-downloaded first. Every heading opens
  onto the whole section rather than the handful that fitted on the shelf —
  Games is nearly 900 apps — rows arrive as you scroll, and typing narrows the
  section instead of leaving it. Anything matching no category lands in *Other*
  rather than being dropped
- Sections are cut from the same index the search uses, which is what makes
  "all of it" and "searchable in full" one property instead of two promises
- **Ordered by downloads**, from Flathub's installs-per-month figures fetched
  once a day; software with no such figure sorts last with review volume
  standing in. Reading never waits on the network
- Live search across the system repos and Flathub, plus a package-name fallback
  so plain CLI packages (`playerctl`) are found too, with chips above the
  results to narrow to one kind
- **One Install button, and a straight answer behind it.** An app carried by
  both the distribution and Flathub opens a picker: the sources side by side
  with version, download size, whether it is sandboxed and how many permissions
  it has, and who stands behind it — plus what each kind of packaging gives you
  and what it costs. A single source still installs with one click. The picker
  is honest about what it cannot compare: sizes exclude what a package drags
  in, and versions from two packagers are compared on leading digits only
- **Search Copr** for software no configured repository has — one deliberate
  press at the end of the results, since nothing in Copr can turn up in a local
  search. Results are listed apart, under the name of the person who builds
  them, and only from projects building for this Fedora and architecture.
  Installing one adds its repository in the same transaction, so it asks for a
  password once
- **Search Homebrew** where brew is installed, through brew's own copy of the
  index. Formulae that cannot run on Linux are listed greyed with the reason
  rather than dropped, because "this exists, but not for you" is an answer
- **Software sources** behind the header button (or Ctrl+K): repositories with
  enable/disable switches, Flatpak remotes, one-click RPM Fusion and Flathub,
  and Copr add/remove. Debug, source and testing repositories are folded away;
  switching off a repository the distribution is made of asks twice. Only the
  dnf family can be changed here — apt and pacman sources are read-only
- ODRS star ratings, live install progress (repositories → download x/y →
  install), a button that opens DMS's own plugin screen, and
  [AppImages](#appimages-end-to-end) offered alongside everything else

| ![The Install tab storefront: popular apps by category with ratings and a source button per app](screenshots/install-storefront.png) | ![The Software sources dialog with Flatpak remotes, well-known sources to add, and repository switches](screenshots/software-sources.png) |
|---|---|
| **The storefront** before you type anything: sections by category, most-downloaded first, each heading opening onto the whole section. | **Software sources.** Flatpak remotes, one-click Flathub and RPM Fusion, and the configured repositories with debug and source ones folded away. |

### 4 · Firmware

fwupd device inventory: which hardware supports firmware updates, current
versions, on-demand LVFS release notes. Pending firmware updates appear in the
Updates tab and run in the firmware phase of Update All.

![The Firmware tab: fwupd devices with vendor, current firmware version and an updatable
chip](screenshots/firmware-devices.png)

### 5 · Log

- Persistent history of everything the plugin did — runs, installs, removals,
  restores, holds — expanding to per-package detail (old → new, source, result)
- **A row that never finished says so**: a clock, not a tick. A DMS update
  reloads the shell mid-run, which is exactly how a run ends without writing
  its last lines; when a later check finds the package did land, the entry
  heals itself
- **What this log cannot account for**: the package database knows when every
  package arrived, this log knows what the plugin did, and the difference is
  somebody else — a terminal, an automatic-update timer, another software
  centre. A line says how many and on how many occasions, expanding to names
  and dates. System packages only
- **The log follows the interface language**: entries record what happened as a
  key and its numbers rather than as a finished sentence
- Searchable, kept for two years — a window that throws away last winter cannot
  answer anything about a year

| ![The Log tab: a timeline of update runs, installs and removals, with a notice about packages changed outside the app](screenshots/log-history.png) | ![A changelog popup listing the CVEs a Chromium update closes](screenshots/security-changelog.png) |
|---|---|
| **What happened, and when.** Grouped by day, with the packages that changed outside this app called out separately. | **What an entry closes.** Release notes and rpm changelogs, CVE numbers included, read from what is already on the machine. |

## AppImages, end to end

An AppImage is a file, not a package: nothing knows it exists, nothing tells
you when it changes, and deleting it leaves its menu entry behind. The whole
life of one is handled here.

- **Find one** in a searchable catalog of the appimage.github.io index (1400+
  apps), listed next to repo and Flathub results
- **Install one** from the app's own GitHub releases, from a URL, or from a
  file you already have. They land in `~/AppImages` — the same folder Gearlever
  uses, and its setting is honoured when it points elsewhere
- **Double-click a downloaded `.appimage`** and the window opens on that file,
  offering to install it, or to replace the build already installed — matched
  on the name inside the image rather than the version in the file name, and
  read without being modified, since a fresh download is never executable. The
  association is claimed once and only when `.appimage` is going spare;
  Settings hands it back at any time
- **It shows up like an app**: icon and desktop entry are extracted from the
  image
- **Existing AppImages are adopted automatically** — images installed before
  this plugin existed are managed from then on
- **Updates** come from a linked GitHub project, appear in the Updates tab and
  run in their own phase with byte progress
- **Uninstall** takes the file, its desktop entry, its icon and its record

![Double-clicking an .appimage opens this dialog, which recognises the build already installed
and offers to replace it](screenshots/appimage-install.png)

## Bar widget & popout

- Bar pill with the effective update count (held excluded), a spinning icon
  while checking, a completed/planned counter during a run, a restart icon when
  a reboot is recommended
- Compact popout: enriched update list, Update All, phase label and current
  item. While a check runs the Dank logo stays where it is and pulses — the
  same two rings the shell's System Check page uses
- Optional: hide the pill when up to date, or have a click open the window
  directly

## Settings & command palette

Everything the plugin decides for itself is in one dialog behind the gear;
everything it can do is one **Ctrl+K** away. Check interval and ignored
packages stay with DMS, and the dialog links straight to them. The same
switches appear on the plugin's page in DMS Settings → Plugins, so whichever
one you find first is the whole set.

Two worth knowing about:

- **App icons in the theme colour.** Off by default — an app's icon is its own
  identity — but some palettes make a wall of unrelated logos look like
  confetti, and this draws them in the active DMS accent instead, tuned
  separately for light and dark.
- **Authorise with sudo.** Off by default, and only useful where sudo needs no
  password. Privileged commands normally go through `pkexec`, which asks
  polkit; a `NOPASSWD` line is a rule in sudoers, which is why such a machine
  is asked anyway. With this on they run under `sudo -n`, which never prompts —
  and falls back to the polkit prompt whenever sudo would ask, so narrow
  sudoers rules or no sudo at all end up where they started. DMS's own packages
  and firmware keep their own polkit actions either way.

| ![The plugin settings dialog with switches for the bar pill, firmware, the launcher entry and the .appimage association](screenshots/plugin-settings.png) | ![The command palette listing tabs, check for updates, software sources and settings](screenshots/command-palette.png) |
|---|---|
| **Plugin settings.** What the pill shows, whether firmware joins Update All, the launcher entry, themed app icons, and who opens `.appimage` files. | **Ctrl+K.** Every tab, the actions around them, and the two dialogs — without going looking for a button. |

## Languages

English, Dutch, German, French, Spanish, Portuguese, Italian, Polish, Swedish,
Ukrainian, Russian, Hungarian, Japanese, Korean, Vietnamese and Chinese
(Simplified) — sixteen. DMS has no per-plugin i18n mechanism, so the plugin
brings its own: `translations/<lang>.json`, keyed by the English source string,
following the DMS/system locale and falling back to the DMS catalog and then
English. Add a language by dropping a file next to the others.

## Requirements

- A Fedora-based distribution — or an atomic Fedora, Debian/Ubuntu or Arch
  (all three experimental)
- DMS ≥ 1.5 with the `sysupdate` daemon capability
- `python3` and `flatpak`, optionally `fwupd`, optionally Homebrew
- Package-manager bindings for your distro:
  - Fedora: `python3-libdnf5` (**not** part of a default install)
  - Atomic Fedora: nothing extra — `rpm-ostree` is the image's own tool
  - Debian/Ubuntu: `python3-apt` (usually preinstalled)
  - Arch: `pyalpm`
- Flatpak bindings — PyGObject *and* the Flatpak typelib, which are two
  packages:
  - Fedora: `python3-gobject-base` (the typelib comes with `flatpak-libs`)
  - Debian/Ubuntu: `python3-gi` **and** `gir1.2-flatpak-1.0`, which `flatpak`
    does not pull in
  - Arch: `python-gobject`

Without the package-manager bindings no system package can be installed,
updated or removed; without the Flatpak ones no Flatpak can. The plugin checks
both at startup and offers to install what is missing, naming the packages for
your distribution.

Optional, for richer app information: the AppStream catalog for your distro —
`appstream-data` on Fedora, `appstream` on Debian/Ubuntu,
`archlinux-appstream-data` on Arch. Without it the plugin falls back to package
summaries and the icons in your desktop entries, so apps still look like apps.

## Install

```bash
git clone https://github.com/vinceecniv/DankSoftwareDepot ~/.config/DankMaterialShell/plugins/dankSoftwareDepot
dms restart
```

Enable **Dank Software Depot** in DMS Settings → Plugins, then add the widget
to a DankBar layout.

To launch the window from the app launcher like a standalone app, let the app
place the entry itself: the Updates tab offers it once, and **Settings → Show
in app launcher** switches it on or off at any time. Both write a desktop entry
and its icon into your home directory — no root, and switching it off takes
them away again. The entry runs `scripts/open.sh`, which calls the IPC below,
so DMS must be running; it opens the window in the shell rather than starting a
second process.

<details>
<summary>The same by hand</summary>

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

The icon step is not optional: the entry names an icon, and without it the
launcher shows a blank one. An entry written by an older version of the plugin
is rewritten once, automatically, the next time the window opens.

</details>

### IPC

```bash
dms ipc call dankSoftwareDepot open      # open the window
dms ipc call dankSoftwareDepot toggle
dms ipc call dankSoftwareDepot tab 2     # a specific tab (0-4)
dms ipc call dankSoftwareDepot check     # trigger an update check
dms ipc call dankSoftwareDepot updateAll
dms ipc call dankSoftwareDepot updateFlatpakOne org.example.App
dms ipc call dankSoftwareDepot openAppimage /path/to/App.AppImage
```

## Network and privacy

The plugin contains **no tracking of any kind**: no analytics, no telemetry, no
crash reporting, no identifier that follows you. There is no server belonging
to this project — nothing is ever sent to its author.

One request happens without you asking: half a minute after the shell starts,
and once a day after that, the plugin fetches its own `plugin.json` and
`CHANGELOG.md` from GitHub to see whether a newer version exists. Plain file
fetches, nothing identifying, skipped entirely on a development checkout.
Everything else below happens because you opened, checked or pressed something.

| Where | What for | When |
|---|---|---|
| your configured repositories, Flatpak remotes, LVFS | the package work itself: metadata, downloads, firmware | checking and updating |
| `raw.githubusercontent.com` | this plugin's own `plugin.json` and `CHANGELOG.md`, to offer its update | 30 seconds after the shell starts, then daily; never on a symlinked install |
| `odrs.gnome.org` | star ratings and review texts (Open Desktop Ratings Service) | opening an app's details |
| `flathub.org/api/v2` | install counts, download size, sandbox permissions, verified status | opening a Flatpak app's details |
| `flathub.org/api/v2` | installs over the last month for the thousand most-installed apps, which is what orders the storefront | once a day, when the Install tab is loaded |
| the screenshot URLs in AppStream data | the screenshots themselves, cached locally for 30 days | opening an app's details |
| `appimage.github.io`, `api.github.com` | the AppImage catalogue and the releases of an AppImage's linked project | the Install tab and AppImage updates |
| `api.github.com` | for a package built from git, the notes of the release being installed or the commits between two snapshots | opening the details of such an update; cached a day, and a package not built from git never asks |
| `bodhi.fedoraproject.org` | which Fedora releases are current, for the release-upgrade notice | the upgrade check |
| `formulae.brew.sh`, `github.com`, `ghcr.io` | Homebrew's own traffic, run by brew rather than by this plugin | only where brew is installed — the index at most every six hours, bottles only during an update you started |
| `archlinux.org` | the Arch news feed | on Arch only, at most every six hours while the window is open |
| `copr.fedorainfracloud.org` | which Coprs build a package matching your search, and for which Fedora | only when you press Search Copr; cached six hours |
| `mirrors.rpmfusion.org`, `dl.flathub.org`, `nightly.gnome.org`, `cdn.kde.org`, `registry.fedoraproject.org` | fetching a source you asked to add | only when you press Add in Software sources |

Two details worth stating plainly, because they are the only places where
anything about you leaves the machine:

- **Reading reviews** sends a `user_hash` that is the same constant for every
  installation (`sha1("dankSoftwareDepot")`). ODRS requires the field; this one
  identifies nobody.
- **Writing a review** is the only outgoing request carrying anything
  machine-specific. ODRS deduplicates and moderates by user, so the submission
  carries a hash of your username and `/etc/machine-id`, along with the display
  name you type — leave that empty and your login name is published instead,
  which is why the field says so before you press send. Nothing is submitted
  unless you write a review and press the button.

## If you use it

Two links, and they cost nothing:

- **[Upvote it in the DMS plugin
  directory](https://github.com/AvengeMedia/dms-plugin-registry/issues/720)** —
  a 👍 on the registry issue. That reaction count is how the directory knows
  which plugins people actually run.
- **[Star the repository](https://github.com/vinceecniv/DankSoftwareDepot)** —
  if it is doing its job on your machine.

Bug reports and feature requests are welcome as
[issues](https://github.com/vinceecniv/DankSoftwareDepot/issues) — the
templates ask for the distribution and the versions, because with four package
managers behind this thing that is usually what decides where the fault is.

## Development

Architecture, the helper protocol, the checks, and how to record an update run
and play it back: [DEVELOPMENT.md](DEVELOPMENT.md) and
[PROTOCOL.md](PROTOCOL.md).

## License

MIT — see [LICENSE](LICENSE).
