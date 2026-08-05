# Changelog

Release notes per version. The section for the latest version is shown
in-app when the plugin offers its own update.

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
