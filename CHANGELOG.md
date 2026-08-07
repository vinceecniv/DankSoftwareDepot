# Changelog

Release notes per version. The section for the latest version is shown
in-app when the plugin offers its own update.

## 0.3.0 — 2026-08-07

- **Programmatic dnf.** All rpm transactions (installs, removals,
  downgrades and the system pass of update runs) now go through a new
  libdnf5 helper — the library dnf5 itself uses — instead of scraping
  command output. Progress comes from real library callbacks: exact
  per-package download bytes, a steady aggregate transfer counter, and
  per-package rpm install progress. Failures carry the library's actual
  error message. The DMS daemon remains for update checks and the
  DankMaterialShell self-update pass (which must survive the shell
  reload).
- The helper event protocol is documented in PROTOCOL.md and is
  package-manager-agnostic by design — groundwork for possible
  apt (Debian) and pacman (Arch) backends later.
- Update runs that update DMS itself no longer lose their action-log
  entry to the shell reload: the entry is stashed beforehand and written
  at the next start, verified against the rpm database, with its
  original timestamp.
- Clicking the updates notification (or its Open button) opens the main
  window on the Updates tab.
- Update-run reliability: waits on a busy daemon are now time-capped and
  a lost backend selection triggers a re-check — a stuck "preparing"
  phase can no longer hang for minutes.
- Dashboard rearranged: system/status on top, installed/recently-updated
  below, equal heights, top-aligned content, larger card titles; the
  recently-updated card scrolls through the last 50 packages.
- Flatpak runtimes and extensions are hidden by default (still always
  updated; a footnote points to the setting).
- Confirm buttons on red fills pick black or white by the fill's
  lightness — readable in every theme.

## 0.2.3 — 2026-08-06

- **Delayed updates removed.** The maturity window kept fighting the
  package manager: updates had to release as complete source families,
  dependencies crossed family lines (gjs needing the still-delayed
  mozjs140), and every exception needed another workaround. Fedora's own
  update pipeline (Bodhi) already gates stable updates upstream, so the
  extra client-side window added little real protection while delaying
  bug and security fixes. Held packages and per-app version restore
  remain the honest tools for staying in control; stored delay settings
  and clocks are cleaned up automatically.
- Update runs verify against the rpm database when a pass ends: a pass
  that silently installed nothing can no longer report success — rows
  that never reached their target version fail visibly with a reason
- The run engine no longer interrupts a working dnf process: the retry
  nudge waits well past resolve time, backs off while daemon output
  streams, and never fires an upgrade into a running check (these
  collisions were killing transactions mid-resolve)
- Failed check errors render as a bounded, wrapped message instead of
  stretching the header off-screen
- Update notifications carry the plugin's own icon, following the
  light/dark theme
- Waiting texts animate: a brightness wave slides across the trailing
  dots, without the text ever changing width
- The reboot banner now says a **computer** restart is recommended —
  "restart" was ambiguous next to shell reloads
- Held packages stay listed during an update run

## 0.2.2 — 2026-08-06

- Six new UI languages: Spanish, Portuguese, Italian, Polish, Swedish and
  Chinese (Simplified) — ten languages in total
- Real per-package download progress for system packages: bars build up
  with actual bytes ("downloading · 37% · 6.7 MB / 18 MB") read live from
  the dnf cache, instead of sitting still and jumping to 100%
- Finished downloads read "downloaded" through the silent
  transaction-prepare wait instead of a stuck "downloading · 100%"
- Progress lines map to the right row in subpackage families
- The delayed-updates countdown no longer restarts after suspend/resume —
  first-seen clocks survive the shell rebuilding its bar
- Update notifications carry the plugin's own icon, following the
  light/dark theme

## 0.2.1 — 2026-08-05

- Update runs are far more reliable: a run right after a service restart
  first triggers a check instead of silently doing nothing, and daemon
  passes retry patiently (the final DMS pass no longer fails while the
  service is still busy)
- Failed updates show why (service error message or a clear retry hint),
  with a failure color that stays readable in light mode
- The misleading overall progress bar is gone — the phase stepper and
  per-package progress rows tell the real story; the bar pill shows
  completed/planned during a run
- Delayed updates mature and release as complete source families, so dnf
  can never skip half a family
- After a restart the restored update list is reconciled against what is
  actually installed, and a fresh check starts automatically
- Update All flips to Cancel immediately; "Loading repositories…" shows
  during the silent metadata phase
- Review form: reviewer-name field (remembered), clearer summary/body
  layout, live star hover; reviews disabled for AppImages

## 0.2.0 — 2026-08-05

- The plugin now updates itself: a banner announces new releases with their
  release notes and updates with one click (dismissible per version; also
  shown in the About popup)
- About popup behind the new info icon: version, supported sources, license
  and GitHub link
- Delayed updates: the countdown survives shell and computer restarts,
  ticks down properly and reads "released for install in …"
- The update list restores instantly after a restart from a persisted
  snapshot instead of staying empty until the next check
- Details popup opens ~5× faster: the description shows after ~1 second,
  screenshots/sizes/reviews stream in as they arrive
- Reviews: reviewer-name field (remembered), summary and body visually
  distinct, live star hover preview; disabled for AppImages (they have no
  shared ODRS identity to review against)
- Window reopens correctly after a compositor-side close (Super+Q)
- Minimum DMS version lowered to 1.5

## 0.1.0 — 2026-08-05

Initial public release.

- Updates tab with rich cards, release notes, held & delayed updates and live progress with ETA
- App store across Fedora repos, Flathub and the AppImage catalog, with ODRS ratings and reviews
- Installed-software management: uninstall, hold, downgrade, AppImage GitHub update sources
- Firmware updates (fwupd) and a persistent action log
- UI in English, Dutch, German and French
