pragma Singleton
import QtQuick
import Quickshell.Io

// The package-backend seam: every entry point that is specific to the
// system package manager, in one place. The transaction helpers speak the
// protocol in PROTOCOL.md; which one runs is decided by the detected
// distro family. The metadata layer (search, sizes, changelogs, holds,
// dashboard) is still dnf/Fedora-specific — see PROTOCOL.md's porting
// inventory.
Item {
    id: backend

    // "dnf" (Fedora/RHEL family, default), "apt" (Debian/Ubuntu family),
    // "pacman" (Arch family) or "ostree" (an atomic Fedora: Silverblue,
    // Kinoite, Bazzite, Bluefin — rpm packages, but no rpm transactions)
    property string backendId: "dnf"

    // An atomic system is not a mutable one with a read-only /usr. Nothing
    // installs into the running system; rpm-ostree writes the next boot, and
    // several things below are different because of it rather than despite it.
    readonly property bool atomic: backendId === "ostree"

    // Transaction helper implementing the NDJSON event protocol
    readonly property string packageHelper: Qt.resolvedUrl("scripts/" + (backendId === "apt" ? "apt_helper.py" : (backendId === "pacman" ? "pacman_helper.py" : (atomic ? "ostree_helper.py" : "rpm_helper.py")))).toString().replace("file://", "")

    // Command for a privileged helper transaction
    function helperCommand(action, specs) {
        return ["pkexec", "python3", packageHelper, action].concat(specs);
    }

    // The same install, preceded by adding the Copr the package lives in —
    // one transaction, so one password. Both Fedora helpers take it: layering
    // a Copr package on an atomic system is the same two steps.
    function coprInstallCommand(project, specs) {
        return ["pkexec", "python3", packageHelper, "install", "--copr", project].concat(specs);
    }

    // Which updates are security fixes. Only the dnf family ships updateinfo
    // in a form we can read locally; elsewhere the answer is "unknown", which
    // the UI shows as no chip rather than as a reassuring absence.
    readonly property bool hasAdvisories: backendId === "dnf"

    function advisoryCommand(names) {
        return ["python3", packageHelper, "advisories"].concat(names);
    }

    // The same transaction, resolved but not run: no root, no changes, so
    // the consequences can be shown before the password is asked for.
    function planCommand(action, specs) {
        return ["python3", packageHelper, "plan", action].concat(specs);
    }

    // ── Helper readiness ────────────────────────────────────────────────────
    // The helpers need their package manager's Python bindings, which are a
    // separate package on every distro and are not part of a default install
    // (a Fedora system has dnf5 without python3-libdnf5). Ask the helper
    // itself — unprivileged, no transaction — so a run can say what is
    // missing instead of reporting every package as mysteriously failed.

    // "" while unknown, "ok", or the helper's reason it cannot run
    property string packageHelperStatus: ""
    readonly property bool packageHelperReady: packageHelperStatus === "ok"
    readonly property bool packageHelperBroken: packageHelperStatus !== "" && packageHelperStatus !== "ok"
    readonly property string packageHelperError: packageHelperBroken ? packageHelperStatus : ""

    // The distro package providing what the helper imports, for the hint.
    // The atomic answer is the tool itself: that helper drives a command
    // line, which every image has, rather than bindings it might not.
    readonly property string packageHelperRequirement: backendId === "apt" ? "python3-apt" : (backendId === "pacman" ? "pyalpm" : (atomic ? "rpm-ostree" : "python3-libdnf5"))

    function checkPackageHelper() {
        if (selftestProcess.running)
            return;
        selftestProcess._reason = "";
        selftestProcess.command = ["python3", packageHelper, "selftest"];
        selftestProcess.running = true;
    }

    onBackendIdChanged: checkRequirements()
    Component.onCompleted: checkRequirements()

    function checkRequirements() {
        checkPackageHelper();
        checkAppstream();
    }

    Process {
        id: selftestProcess

        property string _reason: ""

        stdout: SplitParser {
            onRead: line => {
                let event;
                try {
                    event = JSON.parse(line);
                } catch (e) {
                    return;
                }
                if (event.event === "error" && event.message)
                    selftestProcess._reason = event.message;
            }
        }

        onExited: (exitCode, exitStatus) => {
            backend.packageHelperStatus = exitCode === 0 ? "ok" : (_reason || Tr.t("the package helper could not start"));
        }
    }

    // ── AppStream catalog ───────────────────────────────────────────────────
    // Names, icons, screenshots and release notes for system packages all
    // come from the distro's AppStream catalog, which is its own package and
    // is missing often enough to be worth saying out loud. Unlike the
    // bindings this only makes the app poorer, never broken — the list falls
    // back to package summaries and the icons in the desktop entries.

    // "" while unknown, "ok" or "missing"
    property string appstreamStatus: ""
    readonly property bool appstreamMissing: appstreamStatus === "missing"

    readonly property string appstreamRequirement: backendId === "apt" ? "appstream" : (backendId === "pacman" ? "archlinux-appstream-data" : "appstream-data")

    function checkAppstream() {
        if (catalogStatusProcess.running)
            return;
        catalogStatusProcess.command = ["python3", Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", ""), "--catalog-status"];
        catalogStatusProcess.running = true;
    }

    Process {
        id: catalogStatusProcess

        stdout: StdioCollector {
            onStreamFinished: {
                let count = -1;
                try {
                    count = (JSON.parse(text) || {}).catalogs;
                } catch (e) {
                }
                // An unreadable answer is not evidence of a missing catalog
                if (count >= 0)
                    backend.appstreamStatus = count > 0 ? "ok" : "missing";
            }
        }
    }

    // ── Missing requirements ────────────────────────────────────────────────
    // What the plugin needs from the distro and does not have. The window
    // renders one row per entry; `blocking` separates "nothing works" from
    // "less to show".
    readonly property var missingRequirements: {
        const missing = [];
        if (packageHelperBroken)
            missing.push({
                id: "helper",
                blocking: true,
                package: packageHelperRequirement,
                detail: packageHelperError
            });
        if (appstreamMissing)
            missing.push({
                id: "appstream",
                blocking: false,
                package: appstreamRequirement,
                detail: ""
            });
        return missing;
    }

    // ── Installing a missing requirement ────────────────────────────────────
    // Bootstrapping cannot go through the transaction helper — it may be the
    // very thing that is missing — so these installs run the package
    // manager's command line directly. The only place in the plugin that does.

    function _installWords(pkg) {
        if (backendId === "apt")
            return ["apt-get", "install", "-y", pkg];
        if (backendId === "pacman")
            return ["pacman", "-S", "--needed", "--noconfirm", pkg];
        // Layered, and in effect after the next boot — there is no other way
        // to add a package to an atomic system
        if (atomic)
            return ["rpm-ostree", "install", "--idempotent", pkg];
        return ["dnf", "install", "-y", pkg];
    }

    function installHintFor(pkg) {
        return "sudo " + _installWords(pkg).join(" ");
    }

    // id of the requirement being installed, "" when idle
    property string installingRequirement: ""
    // Why the last install failed, "" when there was none
    property string requirementInstallError: ""

    function installRequirement(id, pkg) {
        if (installingRequirement !== "")
            return;
        requirementInstallError = "";
        installingRequirement = id;
        installProcess._output = "";
        installProcess.command = ["pkexec"].concat(_installWords(pkg));
        installProcess.running = true;
    }

    Process {
        id: installProcess

        property string _output: ""

        stdout: SplitParser {
            onRead: line => {
                const trimmed = (line || "").trim();
                if (trimmed !== "")
                    installProcess._output = trimmed;
            }
        }

        stderr: StdioCollector {
            onStreamFinished: {
                const trimmed = (text || "").trim();
                if (trimmed !== "")
                    installProcess._output = trimmed;
            }
        }

        onExited: (exitCode, exitStatus) => {
            const which = backend.installingRequirement;
            backend.installingRequirement = "";
            if (exitCode !== 0)
                backend.requirementInstallError = exitCode === 126 || exitCode === 127 ? Tr.t("the authorisation was refused") : (_output || Tr.t("the installation failed"));
            // Either way the check, not the exit code, decides
            if (which === "appstream")
                backend.checkAppstream();
            else
                backend.checkPackageHelper();
        }
    }

    // Installed-version listing used for post-run verification; both
    // backends print "name<TAB>version" lines.
    function installedVersionsCommand(names) {
        if (backendId === "apt")
            return ["dpkg-query", "-W", "-f", "${Package}\\t${Version}\\n"].concat(names);
        if (backendId === "pacman")
            return ["sh", "-c", "LC_ALL=C pacman -Q " + names.join(" ") + " 2>/dev/null | sed 's/ /\\t/'"];
        return ["rpm", "-q", "--qf", "%{NAME}\\t%{EVR}\\n"].concat(names);
    }

    readonly property string metadataHelper: Qt.resolvedUrl("scripts/pkg_backend.py").toString().replace("file://", "")

    // Full installed inventory as "name<TAB>version<TAB>bytes<TAB>installtime"
    function installedTableCommand() {
        if (backendId === "apt" || backendId === "pacman")
            return ["python3", metadataHelper, "installed-table"];
        return ["sh", "-c", "rpm -qa --qf '%{NAME}\\t%{VERSION}-%{RELEASE}\\t%{SIZE}\\t%{INSTALLTIME}\\n' 2>/dev/null | sort"];
    }

    // What could be freed: packages nothing needs any more, and the cache
    function cleanupScanCommand() {
        return ["python3", metadataHelper, "cleanup-scan"];
    }

    // Emptying the download cache is a plain package-manager chore with no
    // transaction to report, so it does not go through the helper protocol
    function cleanCacheCommand() {
        if (backendId === "apt")
            return ["pkexec", "apt-get", "clean"];
        if (backendId === "pacman")
            return ["pkexec", "pacman", "-Scc", "--noconfirm"];
        // rpm-ostree keeps its own caches: -m the rpm-md metadata, -p a
        // deployment staged but not booted into
        if (atomic)
            return ["pkexec", "rpm-ostree", "cleanup", "-m"];
        return ["pkexec", "dnf", "clean", "packages"];
    }

    // Did the user ask for this package, and what would miss it if it went
    function provenanceCommand(name) {
        return ["python3", metadataHelper, "provenance", name];
    }

    // Installed packages that own a launchable desktop entry — the ones a
    // user installed to actually run. Distro-agnostic; the helper branches.
    function desktopOwnersCommand() {
        return ["python3", metadataHelper, "desktop-owners"];
    }

    // Shell fragment printing one installed package name per line (embedded
    // in compound sh commands)
    readonly property string installedNamesShellFragment: backendId === "apt" ? "dpkg-query -W -f '${Package}\\n' 2>/dev/null" : (backendId === "pacman" ? "pacman -Qq 2>/dev/null" : "rpm -qa --qf '%{NAME}\\n' 2>/dev/null")

    // Available versions for the previous-versions feature. dnf prints
    // plain ascending version lines; the apt path prints a JSON array
    // (newest first, installed flagged) — consumers branch on the shape.
    function availableVersionsCommand(name) {
        if (backendId === "apt" || backendId === "pacman")
            return ["python3", metadataHelper, "versions", name];
        // An atomic image has no dnf to ask, and no per-package downgrade to
        // offer even if it answered: going back is the previous deployment
        if (atomic)
            return ["true"];
        return ["sh", "-c", "LC_ALL=C dnf -Cq repoquery --qf '%{version}-%{release}\\n' " + name + " 2>/dev/null | sort -uV"];
    }

    // Packages whose update warrants the reboot recommendation
    readonly property var rebootPackagePattern: {
        // Every change is staged for the next boot here, so every change is
        // one the reboot notice is about
        if (atomic)
            return /./;
        if (backendId === "apt")
            return /^(linux-image|linux-firmware|systemd|libc6|dbus|mesa|grub|shim|intel-microcode|amd64-microcode|nvidia)/;
        if (backendId === "pacman")
            return /^(linux(-lts|-zen|-hardened)?$|linux-firmware|systemd|glibc|dbus|mesa|nvidia|amd-ucode|intel-ucode|grub)/;
        return /^(kernel|linux-firmware|systemd|glibc|dbus|mesa|amd-gpu-firmware|intel-gpu-firmware|nvidia|microcode_ctl|shim|grub2)/;
    }

    // Human label of the system package source ("Install from %1")
    readonly property string systemRepoLabel: backendId === "apt" ? "Debian" : (backendId === "pacman" ? "Arch" : (atomic ? "Fedora Atomic" : "Fedora"))

    // ── Software sources ────────────────────────────────────────────────────
    // Which repositories exist, and the few changes worth offering from a UI.
    // Reading is unprivileged; anything that writes to /etc goes through
    // pkexec, and the Flatpak user scope needs neither.
    readonly property string repoHelper: Qt.resolvedUrl("scripts/repo_backend.py").toString().replace("file://", "")

    function repoListCommand() {
        return ["python3", repoHelper, "list", backendId];
    }

    function repoAdminCommand(args) {
        return ["pkexec", "python3", repoHelper].concat(args);
    }

    function repoUserCommand(args) {
        return ["python3", repoHelper].concat(args);
    }

    // What Copr has built for this system, for software that is in no
    // repository the machine has configured yet. Unprivileged: it asks the
    // Copr hub, it changes nothing.
    function coprSearchCommand(query) {
        return ["python3", repoHelper, "copr-search", query];
    }

    // Copr builds per chroot, and the search asks for this machine's own —
    // fedora-44-x86_64. Only a Fedora (or something built on one: Nobara,
    // Bazzite, Ultramarine) has one. The rest of the dnf family are RHEL and
    // its rebuilds, which name Fedora in ID_LIKE without being it, and would
    // be offered a search that cannot answer.
    property bool fedoraFamily: false
    readonly property bool hasCopr: (backendId === "dnf" || atomic) && fedoraFamily

    // ── Launcher entry ──────────────────────────────────────────────────────
    // Enabling the plugin puts a widget in the bar; it cannot put an entry in
    // the application launcher, because that is a file in the user's data
    // directory and no installer ever runs. Both files ship with the plugin,
    // so the app can place them itself — a README step that has to be
    // repeated on every machine is a step that gets forgotten on most.

    // The plugin's own directory, wherever the shell loaded it from
    readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace("file://", "").replace(/\/$/, "")
    readonly property string launcherEntryName: "com.danklinux.dankSoftwareDepot.desktop"

    // Must match X-DSD-Entry-Version in the .desktop file
    readonly property string launcherEntryVersion: "2"

    property bool launcherEntryPresent: false
    // Until the first check answers, the UI should claim neither state
    property bool launcherEntryChecked: false
    property bool launcherEntryBusy: false
    property string launcherEntryError: ""
    // An entry written by an older version of the plugin. It is rewritten
    // without asking: the user already said yes to having one, and the one
    // they have calls `dms` by a name their launcher may not resolve.
    property bool _launcherEntryRepaired: false

    function checkLauncherEntry() {
        if (launcherCheckProcess.running)
            return;
        launcherCheckProcess._stamp = "";
        launcherCheckProcess.command = ["sh", "-c", "f=\"$HOME/.local/share/applications/" + launcherEntryName + "\"; test -f \"$f\" || exit 1; sed -n 's/^X-DSD-Entry-Version=//p' \"$f\" | head -1"];
        launcherCheckProcess.running = true;
    }

    // The icon is installed too: the entry names it, and without it the
    // launcher shows a blank tile next to a perfectly good name. Exec is
    // rewritten to the absolute path of scripts/open.sh — the entry used to
    // call `dms` by name, which a launcher looks up in the session PATH
    // rather than the one a terminal builds, and when it was not there,
    // clicking the entry did nothing whatsoever.
    readonly property string _entryInstallCommand: "set -e; src='" + pluginDir + "'; apps=\"$HOME/.local/share/applications\"; icons=\"$HOME/.local/share/icons/hicolor\"; mkdir -p \"$apps\"; chmod +x \"$src/scripts/open.sh\"; sed \"s|@OPEN@|$src/scripts/open.sh|\" \"$src/" + launcherEntryName + "\" > \"$apps/" + launcherEntryName + "\"; chmod 644 \"$apps/" + launcherEntryName + "\"; install -Dm644 \"$src/assets/icons/dank-software-depot-dark.svg\" \"$icons/scalable/apps/dank-software-depot.svg\"; install -Dm644 \"$src/assets/icons/dank-software-depot-symbolic.svg\" \"$icons/symbolic/apps/dank-software-depot-symbolic.svg\"; update-desktop-database \"$apps\" 2>/dev/null || true"

    function installLauncherEntry() {
        if (launcherEntryBusy)
            return;
        launcherEntryError = "";
        launcherEntryBusy = true;
        launcherProcess._output = "";
        launcherProcess.command = ["sh", "-c", _entryInstallCommand];
        launcherProcess.running = true;
    }

    function removeLauncherEntry() {
        if (launcherEntryBusy)
            return;
        launcherEntryError = "";
        launcherEntryBusy = true;
        launcherProcess._output = "";
        launcherProcess.command = ["sh", "-c", "apps=\"$HOME/.local/share/applications\"; icons=\"$HOME/.local/share/icons/hicolor\"; rm -f \"$apps/" + launcherEntryName + "\" \"$icons/scalable/apps/dank-software-depot.svg\" \"$icons/symbolic/apps/dank-software-depot-symbolic.svg\"; update-desktop-database \"$apps\" 2>/dev/null || true"];
        launcherProcess.running = true;
    }

    Process {
        id: launcherCheckProcess

        property string _stamp: ""

        stdout: StdioCollector {
            onStreamFinished: launcherCheckProcess._stamp = text.trim()
        }

        onExited: (exitCode, exitStatus) => {
            backend.launcherEntryPresent = exitCode === 0;
            backend.launcherEntryChecked = true;
            // An entry from before this version names `dms` directly and
            // declares no MIME types — it cannot open the window on a
            // machine whose launcher has a narrower PATH, and it can never
            // be the AppImage handler. Rewrite it once.
            if (exitCode === 0 && _stamp !== backend.launcherEntryVersion && !backend._launcherEntryRepaired) {
                backend._launcherEntryRepaired = true;
                backend.installLauncherEntry();
            }
        }
    }

    Process {
        id: launcherProcess

        property string _output: ""

        stderr: SplitParser {
            onRead: line => launcherProcess._output += (launcherProcess._output === "" ? "" : "\n") + line
        }

        onExited: (exitCode, exitStatus) => {
            backend.launcherEntryBusy = false;
            if (exitCode !== 0)
                backend.launcherEntryError = _output || Tr.t("the launcher entry could not be written");
            backend.checkLauncherEntry();
            backend.checkAppimageHandler();
        }
    }

    // ── Default handler for .appimage files ────────────────────────────────
    // Double-clicking an AppImage lands in this window, which then offers to
    // install it — or to replace the copy already installed. The association
    // is written into the user's own mimeapps.list and taken back out again;
    // it needs the desktop entry to exist, so switching it on writes that
    // too rather than failing on a file nobody told the user about.

    readonly property string appimageScript: pluginDir + "/scripts/appimage.py"

    property bool appimageHandlerDefault: false
    property bool appimageHandlerChecked: false
    property bool appimageHandlerBusy: false
    // Whoever holds the association when it is not us. Something else having
    // claimed .appimage — Gearlever, an archive manager — is a choice
    // somebody made, and the one-time claim below leaves it alone.
    property string appimageHandlerOther: ""

    function checkAppimageHandler() {
        if (handlerStatusProcess.running)
            return;
        handlerStatusProcess.command = ["python3", appimageScript, "--handler-status"];
        handlerStatusProcess.running = true;
    }

    function setAppimageHandler() {
        if (appimageHandlerBusy)
            return;
        appimageHandlerBusy = true;
        // The entry is (re)written in the same breath: being the default for
        // a file type means nothing without something for it to point at,
        // and an entry from an older version has no MimeType line at all
        handlerProcess.command = ["sh", "-c", _entryInstallCommand + "; python3 '" + appimageScript + "' --handler-set"];
        handlerProcess.running = true;
    }

    function clearAppimageHandler() {
        if (appimageHandlerBusy)
            return;
        appimageHandlerBusy = true;
        handlerProcess.command = ["python3", appimageScript, "--handler-clear"];
        handlerProcess.running = true;
    }

    Process {
        id: handlerStatusProcess

        stdout: StdioCollector {
            onStreamFinished: {
                let status = null;
                try {
                    status = JSON.parse(text);
                } catch (e) {
                    status = null;
                }
                backend.appimageHandlerDefault = status !== null && status.isDefault === true;
                const held = (status && status.defaults) ? (status.defaults["application/vnd.appimage"] || "") : "";
                backend.appimageHandlerOther = (held === "" || backend.appimageHandlerDefault) ? "" : held;
                backend.appimageHandlerChecked = true;
            }
        }

        onExited: (exitCode, exitStatus) => {
            // No output to parse (python missing, script unreadable): the
            // switch still has to stop saying "checking"
            backend.appimageHandlerChecked = true;
        }
    }

    Process {
        id: handlerProcess

        onExited: (exitCode, exitStatus) => {
            backend.appimageHandlerBusy = false;
            backend.checkAppimageHandler();
            backend.checkLauncherEntry();
        }
    }

    // ostree creates this file when the system booted from a deployment. It
    // is the one answer that does not depend on what the image calls itself:
    // Silverblue says ID=fedora, Bazzite says ID=bazzite, and an ordinary
    // Fedora that happens to have rpm-ostree installed is not atomic at all.
    property bool _ostreeBooted: false

    FileView {
        path: "/run/ostree-booted"

        onLoaded: {
            backend._ostreeBooted = true;
            if (backend.backendId === "dnf")
                backend.backendId = "ostree";
        }

        onLoadFailed: error => {
            backend._ostreeBooted = false;
        }
    }

    FileView {
        path: "/etc/os-release"

        onLoaded: {
            const os = text();
            if (/(^|\n)(ID|ID_LIKE)=.*(debian|ubuntu)/im.test(os))
                backend.backendId = "apt";
            else if (/(^|\n)(ID|ID_LIKE)=.*(arch|manjaro)/im.test(os))
                backend.backendId = "pacman";
            else if (backend._ostreeBooted)
                backend.backendId = "ostree";
            // RHEL and its rebuilds say ID_LIKE="rhel fedora", so naming
            // Fedora is not enough to be one
            backend.fedoraFamily = /(^|\n)(ID|ID_LIKE)=.*fedora/im.test(os) && !/(^|\n)(ID|ID_LIKE)=.*(rhel|centos)/im.test(os);
        }
    }
}
