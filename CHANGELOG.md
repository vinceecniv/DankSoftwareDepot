# Changelog

Release notes per version. The section for the latest version is shown
in-app when the plugin offers its own update.

## 0.9.0 — 2026-08-13

- **One Install button, and a straight answer behind it.** An app carried
  by both Fedora and Flathub used to put a button for each in the row and
  leave you to know the difference. Now the row asks once and opens a
  picker: the sources side by side with the version, the download size,
  whether it is sandboxed and how many permissions it has, and who stands
  behind it — the distribution, a verified publisher, or one person on
  Copr. Under that, a paragraph on what each kind of packaging gives you
  and what it costs. A single source still installs with one click.
- **Which source you already have** is marked on the source itself. The
  chip at the top said "Installed" without saying which of the two it
  meant, which is the one thing worth knowing before touching anything.
- **Honest about what it cannot compare.** VLC is 188 kB as an rpm and 53
  MB as a Flatpak — Fedora splits the package, the Flatpak carries its
  own libraries, and neither number counts what it drags in; the popup
  says so rather than implying a comparison. Versions are compared on
  their leading digits only, since `3.0.23` and `3.0.23-10.fc44` are the
  same release, and on a tie nothing is marked newest.
- **App icons can follow the theme.** Off by default, under Plugin
  settings: icons are drawn in the active DMS accent instead of their own
  colours. Tuned separately for light and dark mode, because the effect
  maps an icon's own brightness onto the accent and that lands very
  differently on a light card than on a dark one. Packages with no icon
  of their own follow it too.
- **The Install tab stops showing what you already installed.** That is
  what the Installed tab is for. Searching still finds them, with the
  Installed marker — being told an app does not exist because you have it
  would be worse than showing the row.
- **The Reclaim space card no longer vanishes mid-use.** It offers two
  piles, and clearing the larger one used to drop the total under the
  threshold that made the card appear, taking the second button with it.
  Cleared rows now stay, ticked off, until you leave the window.
- **Review stars use the theme accent**, like the buttons already did.
- **Both settings panels offer the same settings.** The window's own
  panel and the plugin page in DMS settings had drifted apart; automatic
  updates and the launcher entry have joined the latter.

## 0.8.3 — 2026-08-13

- **The Install tab is something you can walk through now.** Every heading
  opens, and behind it is the whole section rather than the six apps that
  fitted on the storefront: Games is 892 apps here, Utilities 750. Chips
  at the top of a section say where else to go, rows arrive as you scroll,
  and typing inside a section searches all of it — not the part you have
  scrolled past. Sections are cut from the search index instead of being
  a second, shorter list sent alongside it, which is what makes "all of
  it" and "searchable in full" the same thing rather than two promises.
- **Thirteen sections instead of eight**, from Flathub's own top-level
  categories: Education, Science, Health & Fitness and Internet are new,
  and whatever fits nowhere lands in Other rather than being dropped. On
  this machine that last one holds 46 apps, 39 of which carry no category
  at all — until now they could be found by name and by nothing else.
- **Sorted by downloads.** That number did not exist in the app before;
  "popularity" meant review volume, which is a much smaller and different
  thing. Flathub's install figures for the last month now decide the
  order, refreshed daily. Two honest limits: only software Flathub
  carries has such a figure, so an rpm with no Flatpak sorts last with
  review count standing in; and the figures cover the top thousand, which
  makes absence "fewer than the smallest number here" rather than
  unknown. Reading them never waits on the network — the storefront takes
  what is cached and a refresh happens out of sight.
- **"Search Copr" exists again**, and sits under the results instead of
  above them, which is where "not here?" is a question you have just
  arrived at. It had been invisible since 0.8.0 — a wrapper added around
  the button to fix its width asked the button whether to be shown, and a
  parent asking that of its child has already decided the answer.
- **Two more buttons that had gone the same way**: "View in log" after a
  failed update, and "Save" on an AppImage's update source. Both were
  noted a fortnight ago as things that *could* latch and left alone;
  both had already latched, because both live somewhere that starts
  hidden.
- **Typing stays quick on a four-thousand-app catalog.** A query that
  grows is matched against what survived the previous letter rather than
  against everything, and the tab warms up shortly after the window opens
  instead of on the click that asks for it — that click is usually
  someone about to type.

## 0.8.2 — 2026-08-13

- **Release notes you can read, and now actually select.** This plugin's
  own notes were the smallest text in the app — 12px in the banner that
  offers the update, 11px in the About window — on the one banner that
  asks to be acted on. Both are 14px now. They were also made
  selectable last week and still could not be selected: they sit in a
  bounded scroll area, a drag inside one is a scroll, and a scroll and a
  selection are the same gesture until one of them claims the mouse. The
  viewport won every time. It no longer takes the drag, and the wheel
  and the scrollbar carry on as before.
- **A licence long enough to push the close button off the card.**
  Fedora hands out whole sentences as licence ids, and
  `LicenseRef-Callaway-Redistributable-no-modification-permitted` is a
  single unbreakable word: nothing to wrap on, so it ran past the edge
  of the details popup. Worse than the untidiness, the width it claimed
  was claimed by the column it sits in, which is followed in the header
  by the × — so the button left the card. The licence now takes the
  width that is left over instead of asking for its own, and breaks
  mid-word when a word does not fit.

## 0.8.1 — 2026-08-12

- **A run is over when the check says so.** Every run ends by asking the
  daemon to check again, and that check was doing its work behind a list
  that already said Completed — minutes of it, with only the counter in
  the header to show for it. Finished items now wait in a **Confirming**
  group, the stepper has a **Verify** step and pulses on it, and nothing
  claims the system is up to date until it is known. What makes that
  worth more than a nicer spinner: a package still offered as an update
  after its own transaction reported success did not take, and instead
  of quietly reappearing at some later check it is now marked on the
  card, with the reason, and counted among the failures.
- **The details popup opens straight away.** It was consulting the
  AppStream search index to decide whether a package is in the catalogs
  at all, and consulting that index means building it when the catalogs
  have moved — which they do when appstream-data comes down with an
  update. The bill therefore landed on whoever opened a popup first
  after updating: measured here, 13.7 seconds in front of a spinner. The
  index is now built out of sight, and the same popup paints in under a
  second.
- **Arch Linux news**, on the distribution that publishes it. Arch
  announces in prose, before the fact, that an update needs a hand — a
  key imported, a package replaced before the rest will resolve. A
  banner appears only when something unread has appeared, and the first
  fetch on a machine marks the backlog read rather than opening with
  eleven interruptions nobody missed. Items are kept rather than
  mirrored, so Ctrl+K → Arch Linux news still has the announcement that
  explains the state this machine is in, long after it scrolled off the
  feed.
- **Text worth copying can be copied.** The CVE numbers in an advisory,
  a changelog, the verbatim output behind a failed update, an app's name
  and its `old → new` version step: all readable, none of them
  selectable. They are now, along with release notes, descriptions and
  announcements. Not every label — the element that can be selected
  takes the mouse with it, and a card whose title was selectable would
  stop being a card you can click.
- **A licence is free text, not a vocabulary.** Vivaldi's package says
  its licence is "Multiple, see https://www.vivaldi.com/", and as the
  third item in a dot-separated line that read like an unfinished
  sentence. The licence now sits behind a mark that says licence, and
  the version step behind one of its own, so any value at all reads as
  what it is.
- **Gaps that were nobody's spacing.** The drive icon on the sizes line,
  and the trend icon on the Flathub install counts, sat half a row away
  from their own sentence: neither the icon nor the text asked for the
  leftover width, and a layout with no taker splits the slack evenly
  between its items.

## 0.8.0 — 2026-08-11

- **A GPG key is no longer reported as a package that changed behind your
  back.** rpm keeps every imported repository key as a pseudo-package
  called `gpg-pubkey`, install time and all, so adding a Copr or RPM
  Fusion made the log's "changed outside this app" card announce two
  strangers — in a card whose entire purpose is to be trusted when it
  does go off.
- **Four buttons stood outside their own margin.** DankButton sizes
  itself by writing `width`, which a layout does not read, so a row
  believed its buttons were nothing wide and put the last one past the
  edge. Reported on the AppImage dialog's Replace button; the same shape
  was then found and fixed for "View in log", "Search Copr" and the
  Save button of an AppImage's update source.
- **The pulsing badge stays sharp.** Its SVG was rasterised at exactly
  twice the drawn size, which the pulse then blew past by a tenth — the
  logo was softest at the peak of every breath. It now asks for what the
  peak needs, at your display's scale. The icon that stands in for the
  logo on hover gets the treatment the spinning bar icon got long ago:
  glyphs hinted to the pixel grid do not survive being scaled.

## 0.7.9 — 2026-08-11

Both fixes in this release come from reports by @kmf — thanks for the
screenshots and the follow-up, which is what made the causes findable.

- **The privileged helper no longer runs whatever `python3` means on
  `PATH`** (#3). The commands were built as `pkexec python3 …`, and pkexec
  resolves that name through `PATH` — so with Homebrew, pyenv or conda
  ahead of `/usr/bin`, the interpreter elevated to root was one the user
  can write to. The system interpreter is now resolved once at startup and
  named by absolute path everywhere, privileged and not.
- **Missing Flatpak bindings are reported before a run fails** (#2). The
  helper needs PyGObject *and* the Flatpak typelib, which are two
  packages, and on Debian and Ubuntu `gir1.2-flatpak-1.0` does not come
  with `flatpak`. The startup check now asks the Flatpak helper as well,
  and a missing binding appears in the requirements card with its own
  wording and an install button naming the packages for your
  distribution — `gir1.2-flatpak-1.0` and `python3-gi` on Debian,
  `python3-gobject-base` on Fedora, `python-gobject` on Arch.
- A requirement can name more than one package now; the install command
  passed it as a single argument, which would have looked for one package
  with a space in its name.

## 0.7.8 — 2026-08-10

- **The last year, on the dashboard.** A card that reads a year back out
  of the action log: how much went through here, across how many update
  runs and how often that works out at, the longest stretch it stayed
  quiet, the biggest single run, the busiest month, and the package you
  update more often than any other. It is counted from the log itself,
  so it says how far back that log actually reaches rather than
  presenting six weeks as a year — and it stays away entirely until
  there is a stretch worth looking back over.
- **The log is kept for two years** instead of ninety days, which is
  what gives the card something to read. About 40 kB a week of ordinary
  use, so a few megabytes over the two years.
- **Security fixes are graded.** The distro says whether a fix is
  critical, important, moderate or low, and that was being fetched and
  thrown away — every one of them read simply "Security". The chip now
  carries the grade, and only the top two are drawn in full red; if
  everything shouts, nothing is heard. The CVE numbers appear in the
  details popup, and the summary line says how many of the pending
  updates are security fixes.
- **A hold on top of a security fix now says so.** Holding a package
  back is a reasonable thing to do, right until the update being held is
  the one that closes a hole. The "Held" and "Security" chips used to
  sit side by side on the same card and leave you to notice; the card
  says it in words, and the summary line counts how many security fixes
  are being held back.
- **What changed without you.** The package database knows when every
  package last arrived, this log knows what this app did, and the
  difference is something else — a terminal, an automatic-update timer,
  another software centre. The Log tab says how many packages that is
  and on how many occasions, expanding to names and dates. Packages that
  came along as dependencies of something you did install count as
  yours, and nothing before the log's own first entry is counted at all,
  because there is nothing there to compare against.

## 0.7.7 — 2026-08-10

- **Double-click an AppImage and it opens here.** On by default, so a
  downloaded AppImage lands in this window instead of nowhere — a fresh
  download is not
  executable, so double-clicking it normally does nothing at all. The
  image is read before anything is offered, from a temporary copy so
  your file is left exactly as it was, and the question matches what it
  turns out to be: install this, or replace the build you already have.
  Which one it is comes from the name inside the image rather than the
  file name, because a download is called `Foo-1.2.3-x86_64.AppImage`
  and the app is called Foo. Installing from a file or URL and this both
  use the same dialog now, instead of a row wedged into the toolbar and
  a card above the results. The association is claimed once and only
  when `.appimage` is going spare — another app already holding it was
  somebody's choice and is left alone — and *Open .appimage files with
  this app* in settings takes it back or hands it over at any time.
- **The launcher entry did nothing when you clicked it.** It called
  `dms` by name, and a launcher hands a program the session's `PATH`,
  not the wider one a terminal builds — and `dms ipc` needs `qs` on it
  as well. Worse, `dms ipc call` exits successfully even when it reached
  nobody, so nothing anywhere said so. The entry now runs a small shim
  that looks in the usual places, treats any answer as the failure it
  is, and puts the reason in a notification. An entry from an older
  version is rewritten by itself the next time the window opens; there
  is nothing to redo by hand.
- **A package that finished installing said so at once, with all the
  others.** Each package reports its own completion and that was thrown
  away, so a run of two hundred kept every row under "In progress" with
  its progress bar full until the verification pass at the end moved
  them all together. Rows now move to Completed when their own install
  finishes, and the verification still has the last word.
- **The date beside a release heading was barely readable in dark
  mode.** The update banner rendered its headings once and baked that
  moment's colours into them, while the text around them kept following
  the theme — so switching to dark left the date a light-mode grey on a
  dark card. The notes are derived now, and follow the theme like
  everything else.
- **A check pulses around the logo instead of spinning over it.** The
  Dank penguin used to be replaced by a rotating arrow for the seconds
  you were most likely looking at it. It stays, and the two rings from
  the shell's own System Check page pulse around it.

## 0.7.6 — 2026-08-10

- **Packages built from git now have release notes too.** A package from
  a `*-git` Copr, or an AUR `-git` build, carries a commit count and a
  short hash where a release number would be — so AppStream has no
  release to describe and the rpm changelog records only the rebuild.
  The details popup was emptiest for exactly the packages that change
  most. It now asks the upstream repository, which the package itself
  names in its URL field. Updating to a tagged release shows that
  release's published notes, plus any release skipped on the way there
  if the version being replaced was a release as well. Updating from one
  build of a branch to another shows the commits in between instead,
  newest first, without the merge commits that name the same changes
  twice. There is a line to the release or comparison page for the rest.
- **What upstream wrote is still not allowed to be markup.** Release
  bodies go through the same reduction as AppStream notes and a little
  further: embedded HTML is dropped rather than displayed as its own
  source, tables are left out where there is one column to draw them in,
  GitHub's `> [!NOTE]` is named instead of quoted, and links keep their
  words and lose their target. Notes running to several screens are cut
  at a block boundary, never mid-sentence.
- **A package that is not built from git never reaches the network.**
  The version decides that before any request is made, so this costs
  nothing on ordinary updates. Answers are kept for a day; a failed
  lookup is not kept, because a moment without network should not mean a
  day without notes.

## 0.7.5 — 2026-08-10

- **Copr is searchable from the Install tab.** A package built in Copr is
  invisible to dnf until its project is enabled, so it could never turn
  up in a search — you had to know the Copr to find the package that
  would have told you about it. There is now a "Search Copr" button
  under the search field: one deliberate press, because it asks the Copr
  hub rather than this machine. Results are listed apart, under the name
  of the individual who builds them, and only from projects that build
  for this Fedora and architecture. Installing one adds its repository
  as part of the same transaction, so it asks for a password once
  instead of twice, and the "Installed" chip goes to the project the
  package actually came from — five Coprs can build the same name.
- **"Chroot not found in the given Copr project" now says what it
  means.** Adding a Copr that has no build for your Fedora answered with
  dnf's download progress, that sentence, and a screenful of EPEL chroot
  names, cut off mid-list. It says "This Copr has no builds for Fedora
  44 (x86_64)" instead, and the progress lines no longer arrive as the
  first line of an error.
- **Atomic Fedora is supported, experimentally.** Silverblue, Kinoite,
  Bazzite and Bluefin were being handed to libdnf5, which cannot write
  `/usr`. They are their own backend now, driven through `rpm-ostree`:
  installing layers a package, removing unlayers one, and an update is
  the whole deployment rather than a choice of packages. Nothing takes
  effect until the next boot, so a finished transaction says "takes
  effect after reboot" and raises the reboot notice instead of claiming
  the package is in use. Removing something that came with the image is
  refused with the reason. Software sources work there too — the
  repository list, the switches and adding a Copr no longer need dnf to
  be installed, which also fixes the sources list on a Fedora without
  `python3-libdnf5`.

## 0.7.0 — 2026-08-10

- **The update notice now covers every version you skipped.** It showed
  the newest release's notes and stopped there, so two versions behind
  meant one version's notes — the other's fixes stayed invisible. It now
  gathers every section newer than the installed version and says how
  many releases that is.
- **Those notes are read as text, not printed as a file.** CHANGELOG.md
  is hard wrapped for a terminal, so the banner drew short lines while
  having twice the width to give, and `**bold**` stood as four asterisks.
  Continuations are rejoined, bold, code and links become what they mean,
  and each version heading carries its number in the accent colour. The
  notes sit in a bounded, scrollable box — several releases do not fit a
  banner, and cutting them off hides the very fixes that were skipped.
  The About popup shows them as well.
- **A new plugin version announces itself**, once per version, the same
  way new packages do — the banner was only seen by someone who happened
  to open the window. Respects the "Automatic updates: off" setting.
- **The dashboard's headings lead where they summarise**: "Installed
  software" and "Recently updated" are links to their tabs, with a hover
  underline and a chevron.
- **The three support links now also sit in About**, stacked and left
  aligned there, three across on the dashboard.

## 0.6.9 — 2026-08-10

- **A package name in the log leads to the package.** Hover a name in an
  expanded log entry and it underlines; click it and the same details
  popup the tabs use opens, changelog included. The log is where you
  notice a version you did not expect, and reading up on it no longer
  means finding the package again by hand. Entries now record what a
  package is called as well as what it is displayed as; older entries
  still work where the name is a package name.
- **A "Network and privacy" section in the README**, listing every
  outgoing connection the plugin makes and when. There is no tracking of
  any kind and no server belonging to this project, but there is more
  traffic than "updates and a version check": ratings and reviews from
  ODRS, Flathub's app data, screenshots from AppStream URLs, the AppImage
  catalogue. Two details are stated plainly — reading reviews sends a
  constant hash that identifies nobody, and submitting one is the single
  request carrying anything machine-specific.
- **The review form says what happens if you leave the name empty**:
  your login name is published. It used to be a silent fallback.
- **A translation checker** (`scripts/check_translations.py`): identical
  key sets across the fifteen catalogs, every string the UI asks for,
  placeholders kept in each translation, and keys nothing calls any more.
  It found the details popup printing a raw source id — "fedora: 12 MB
  download" next to translated text in every language — and ten dead keys.
- A long version no longer wraps onto a second line in the log while the
  row still has room to its right.

## 0.6.8 — 2026-08-10

- **"python3-libdnf5 is missing" was sometimes simply wrong** (#3). On a
  Fedora 44 machine where the package was installed, every system update
  failed on a binding the app said was absent. The helpers are started as
  `python3 <script>`, which is whatever PATH means in the shell's process
  — a pyenv shim, a uv or conda environment, an activated virtualenv —
  and the bindings are installed into the system interpreter and nowhere
  else. A helper that cannot import its binding now hands the command to
  a system interpreter that can, outside that environment. All five
  bindings are covered: libdnf5, python-apt, pyalpm, PyGObject and
  PyYAML.
- **A Flatpak run could die before its first word.** PyGObject's import
  in the flatpak helper was not guarded at all, so on a wrong interpreter
  the process ended before any event: the run reported that everything
  failed and could say nothing about why. On every distribution, not only
  on Fedora.
- **A failure that is counted is now a failure that is shown** (#2). A
  Flatpak transaction touches refs the pending list never mentioned —
  extensions, themes, drivers, runtimes pulled along. When one of those
  failed, the counter went up and the reason was dropped for want of a
  row, so a run could end in "1 failed" with every line it showed in
  green and nothing to read anywhere. Such a failure now gets a row, with
  the ref's name and the transaction's own words. The same hole is closed
  where a whole installation's transaction fails, where the helper exits
  non-zero, and where a system dependency the resolver pulled in fails.
- When a binding still cannot be loaded, the card names the interpreter
  that could not load it and no longer asserts that the package is
  missing — a diagnosis that cannot be contradicted is worse than none.

## 0.6.7 — 2026-08-09

- Tab hover is one sliding highlight that follows the pointer and fades
  where it is — visited tabs no longer keep a leftover glow
- When an update run starts, the list jumps to the top where the
  in-progress group is, also for a user who had scrolled down

## 0.6.6 — 2026-08-09

- Updates from Copr repositories no longer fail with a silent
  "nothing to do": the update check refreshes repository metadata, but
  the transaction resolved against the cached view — up to 48 hours old
  for Coprs — so a freshly offered build could be invisible to the very
  run that was supposed to install it. The rpm helper now refreshes
  metadata before every transaction, the same way the check does.
- A run that genuinely resolves to nothing is reported as such per
  package, instead of as "the package helper could not start".

## 0.6.5 — 2026-08-08

- **Software sources, as a panel rather than as a wiki page.** The Install
  tab's header button (or Ctrl+K → Software sources) shows what this
  machine is configured with and offers the changes that are safe to
  express as a button:
  - **RPM Fusion when it is missing**, both flavours in one step — most
    of nonfree builds on free, so adding nonfree alone is half an
    installation.
  - **The well-known Flatpak remotes as buttons** instead of as
    addresses to look up: Flathub, Flathub Beta, Fedora Flatpaks, GNOME
    and KDE nightly. What you already have says so instead of offering
    itself again. Anything else goes in by `.flatpakrepo` address.
  - **The configured repositories with switches**, and Copr add and
    remove. Debug, source and testing repositories are folded away —
    they are two thirds of the list on a normal Fedora.
  Switching off a repository the distribution is made of asks twice, as
  does any removal. Writing a repository definition by hand stays a text
  editor's job. Changes to `/etc` go through pkexec; Flatpak remotes are
  added for you alone and ask for nothing. Every change that succeeds is
  logged; every one that fails keeps the tool's own words. Only the dnf
  family can be changed from here: apt and pacman sources are listed
  read-only, because an apt source is a file plus a signing key and a
  pacman repo lives in a single hand-edited `pacman.conf`.
- The command palette hands its query to **Installed and Log** as well as
  to Install, so the first few matches are no longer the only way onward.
  Its direct log results are gone: activating one opened the newest entry
  rather than the one that was clicked.
- **The palette opens empty and takes the keyboard.** It came back with
  the previous query still in it, the old row still selected, and the
  first keystrokes still going to the window behind it — one dead
  reference behind all three, silent because QML errors raised in a
  plugin file never reach the journal.
- **Opening the app when it is already open brings it to you** instead of
  appearing to do nothing behind another window (niri and Hyprland are
  asked directly; elsewhere the window re-maps). The same fix revealed
  that the three-minute timer returning an idle window to the Updates tab
  had never run, for the same reason.
- **The app can put itself in your launcher**, and does it from the
  Updates tab with a close button that is remembered, or from Settings at
  any time. Both write the entry *and* its icon — the documented manual
  step never mentioned the icon, which is a launcher item with a blank
  tile.
- Fix: the duration forecast built "usually about 5 min here" by deleting
  the word "left" from a translated phrase, which only works in languages
  that put that word last.

## 0.6.0 — 2026-08-08

- **A command palette on Ctrl+K.** One field over everything the window
  already holds — pending updates, installed software and the app's own
  commands — filtered as you type, with no process to wait for. Arrows
  move, Enter acts, Escape leaves. It deliberately does not search the
  repositories: that needs a process and a cache the Install tab already
  owns, so the last results hand the query to Installed, Install or Log
  instead of growing a second search engine here. Reachable from a
  magnifier in the header, which carries the shortcut in its tooltip.
- **Show what Update All would do, before the click.** A strip above the
  list states the resolver's own answer: how many packages the
  transaction really touches, how much arrives, what it costs or frees on
  disk, how many were pulled in as dependencies nobody selected, and — in
  warning colour — anything that would be removed. It comes from the same
  `plan` event the run consumes, fetched without root, so the preview
  cannot drift from the transaction it describes.
- **Say what a removal takes with it, before it takes it.** Removing one
  package can remove others, and that used to happen in silence: only
  packages you picked ever got a row, so anything the resolver decided to
  remove left no trace. The details popup now names them. `plan` became a
  prefix on any action rather than an action of its own, which is what
  makes an unprivileged preview possible at all.
- **Not every update is equally urgent, and the list now says so.**
  Fedora ships updateinfo next to its packages — which update closes a
  security hole, which fixes a bug, and the CVE behind it. Read from the
  local cache, so it costs no root and no network. Only the dnf family
  publishes this in a locally readable form; elsewhere it shows as no
  chip rather than as a reassuring absence of danger.
- **Why is this on my system, answered.** Did you ask for this package or
  did it arrive as somebody's dependency, and what would miss it if it
  went — one line in the details popup, from facts every package manager
  keeps behind flags nobody remembers.
- **Reclaim space: the two piles nobody looks at** — packages pulled in
  for something since removed, and the download cache of files already
  installed, each with its measured size and its own button. The card
  stays hidden below 50 MB, where the offer would be noise.
- **How long this usually takes here, measured rather than guessed.**
  Every run reports its own duration and size and the last ten are kept;
  the forecast is the median seconds per package, so one run that hit a
  slow mirror does not set the expectation. It stays silent until this
  machine has shown at least two runs.
- **The log becomes a timeline** — a heading per day, a dot per event on
  a rail that runs between them, and above it what the log always knew
  and never said: how many packages were updated, installed and removed
  in the last seven days.
- **The app can put itself in your launcher.** Enabling a plugin cannot
  write a desktop entry, so until now the window was reachable from the
  bar and nowhere else unless you found the README step and repeated it
  on every machine. The Updates tab offers it once, with a close button
  that is remembered, and Settings keeps the switch permanently — on
  places the entry and its icon in your own home directory, off takes
  them away. No password, nothing outside your home.
- **Opening the app when it is already open now brings it to you**
  instead of appearing to do nothing behind another window. A Wayland
  window cannot raise itself, so the compositor is asked (niri, Hyprland,
  and a re-map elsewhere).
- **AppImages install into `~/AppImages`** whether or not Gearlever is
  there, created on first install. The old chain used it only if it
  already existed and otherwise fell back to `~/Applications`, which
  quietly split installs across two folders. Gearlever's own setting
  still wins where it points elsewhere, and existing `~/Applications`
  installs keep being listed and updated in place.
- Fixes: the cache row measured repository metadata rather than package
  files, and offered to free something `clean packages` never touches —
  and then wrote "Emptied the package cache" for runs that emptied
  nothing, because the command exits 0 with nothing to clean. Cleanups
  are now logged by what they actually freed. The three-minute timer that
  returns an idle window to the Updates tab read a window property that
  does not exist, so it had never run. Colours written into a JS model
  are strings, and blending one silently produced an invalid colour —
  which draws as nothing.
- Three quiet support chips under the dashboard cards: the plugin
  registry entry, the repository, and Vito — the last drawn as its own
  five bars, which take the brand gradient on hover.

## 0.5.1 — 2026-08-08

- **Six more languages: Ukrainian, Russian, Hungarian, Japanese, Korean
  and Vietnamese** — sixteen in total. Chosen by measuring the shared
  DankMaterialShell catalogs rather than guessing: these all sit between
  88% and 97% translated, above several languages this plugin already
  shipped. Arabic and Hebrew score highest of all but are still missing,
  because the layout has no right-to-left handling and shipping the text
  without it would be half a job.
- **No Firmware tab when firmware updates are switched off** in the
  plugin settings — a tab for something you turned off is a dead end.
- The main tabs have a visible hover state, and the spinning refresh
  icons no longer look ragged while they turn: they were drawn with
  pixel-grid hinting, which does not survive rotation.
- On the dashboard the footer no longer reserves room for an Update All
  button that is not there, so the cards get the space instead of
  scrolling early.
- Two quiet links under the dashboard cards, to the plugin registry entry
  and the repository.

## 0.5.0 — 2026-08-08

- **A missing package-manager binding no longer looks like hundreds of
  failed packages.** `python3-libdnf5` is not part of a default Fedora
  install, and without it the rpm helper died on its import before its
  first event — so an update run marked every system package as failed
  within seconds, for no stated reason. The helpers now report a missing
  binding through the event protocol, the plugin asks them at startup
  (`selftest`) and shows a card naming the package, with a button that
  installs it and the command for anyone who would rather do it in a
  terminal. A run that cannot start says so once instead of blaming each
  package.
- The same card reports a **missing AppStream catalog**
  (`appstream-data`, `appstream`, `archlinux-appstream-data`), which is
  what gives system packages their real names, icons and release notes
  and is just as easy to be without. That one is a note rather than an
  error: the plugin falls back to package summaries and desktop-entry
  icons, so apps still look like apps.
- **The final DankMaterialShell pass stays inside its own scope.** That
  pass runs through the update daemon, whose upgrade command means
  "everything pending" — so after a failed system pass it quietly
  installed those packages too: minutes without visible progress, and
  packages that ended up installed while the log recorded them as
  failed. The pass now carries an ignore list of everything it is not
  responsible for.
- Failed rows carry the tool's own words. The card shows the short
  reason and offers **Show details** for the verbatim output; the action
  log keeps both, so a failure can still be reported after the fact.
- **A failure outlives the run panel.** A package that failed is still a
  pending update, so it comes back in the list — and now it brings its
  reason with it, restored after the shell reload that a DankMaterialShell
  pass causes. The verdict is dropped as soon as the package stops being
  pending, so a stale failure can never haunt a package that has since
  been updated. The result panel also links straight to its own entry in
  the log, and its "%1 updated · %2 failed" summary now actually appears
  after a failed run — it was written for a phase that run never reaches.
- The action log is reconciled with the system: a package that failed
  before the shell pass but did arrive is recorded as updated, and a run
  torn down by a shell reload no longer leaves a stray "0 packages
  updated" entry.
- Update cards pack their chips, buttons and status icons into one
  cluster against the right edge, aligned with each other.
- **During a run the list groups by what is happening**, not by what kind
  of package it is: what is being downloaded or installed right now sits
  at the top, then what is still waiting, then what this round already
  finished — collapsed, because a long run finishes far more packages
  than it works on at once. Failures sort to the top of the finished
  group. Every section header carries an icon and a count, so "how many
  are still waiting" is answerable at a glance.
- A fresh install starts at **Notify only** instead of Off — finding
  updates and saying nothing helps nobody. An explicit Off is kept.
- **Installed** shows the programs you use above the packages that hold
  them up, in two named groups. A package counts as an application when
  it owns a desktop entry the launcher would show — which also gives an
  icon and a name to packages AppStream never heard of (COPR builds,
  third-party repos), so Nautilus and Remmina look like themselves again.
- **The last two Debian/Arch metadata gaps are closed.** Package
  changelogs come from `/usr/share/doc` on apt and `pacman -Qc` on Arch,
  read locally rather than over the network, and the AppStream catalog is
  read from DEP-11 YAML on the Debian family (apt's own lists and the
  appstream cache) and from the legacy XML path Arch's
  `archlinux-appstream-data` still uses. DEP-11 release notes go through
  the same markup reduction as every other external source.

## 0.4.0 — 2026-08-07

- **Experimental Debian/Ubuntu and Arch support.** The plugin now detects
  the distro family and switches its whole package layer: transactions
  run through python-apt or pyalpm (same live byte-progress as on
  Fedora), and search, package info, update sizes, installed inventory,
  holds and the dashboard all have apt and pacman implementations.
  **Experimental means experimental**: everything is container-tested
  (real installs, removals and upgrades on Debian trixie and Arch) but
  not yet validated on real desktop installs — these systems show a
  banner with a "Report an issue" button, and PROTOCOL.md tracks the
  known gaps (package changelogs, AppStream catalog paths, update-check
  daemon behaviour). Fedora code paths are untouched.
- Arch specifics: official repositories only — AUR transactions are
  deliberately out of scope (the interactive PKGBUILD review exists for
  safety); AUR/foreign packages do appear read-only as their own count
  on the dashboard. Version restore is unavailable (pacman repositories
  keep no history).
- The reboot recommendation, install labels, search placeholders and
  post-run verification all follow the detected backend.

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
