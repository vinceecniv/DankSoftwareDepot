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

    // "dnf" (Fedora/RHEL family, default), "apt" (Debian/Ubuntu family)
    // or "pacman" (Arch family)
    property string backendId: "dnf"

    // Transaction helper implementing the NDJSON event protocol
    readonly property string packageHelper: Qt.resolvedUrl("scripts/" + (backendId === "apt" ? "apt_helper.py" : (backendId === "pacman" ? "pacman_helper.py" : "rpm_helper.py"))).toString().replace("file://", "")

    // Command for a privileged helper transaction
    function helperCommand(action, specs) {
        return ["pkexec", "python3", packageHelper, action].concat(specs);
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

    // The distro package providing what the helper imports, for the hint
    readonly property string packageHelperRequirement: backendId === "apt" ? "python3-apt" : (backendId === "pacman" ? "pyalpm" : "python3-libdnf5")

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
        return ["sh", "-c", "LC_ALL=C dnf -Cq repoquery --qf '%{version}-%{release}\\n' " + name + " 2>/dev/null | sort -uV"];
    }

    // Packages whose update warrants the reboot recommendation
    readonly property var rebootPackagePattern: {
        if (backendId === "apt")
            return /^(linux-image|linux-firmware|systemd|libc6|dbus|mesa|grub|shim|intel-microcode|amd64-microcode|nvidia)/;
        if (backendId === "pacman")
            return /^(linux(-lts|-zen|-hardened)?$|linux-firmware|systemd|glibc|dbus|mesa|nvidia|amd-ucode|intel-ucode|grub)/;
        return /^(kernel|linux-firmware|systemd|glibc|dbus|mesa|amd-gpu-firmware|intel-gpu-firmware|nvidia|microcode_ctl|shim|grub2)/;
    }

    // Human label of the system package source ("Install from %1")
    readonly property string systemRepoLabel: backendId === "apt" ? "Debian" : (backendId === "pacman" ? "Arch" : "Fedora")

    FileView {
        path: "/etc/os-release"

        onLoaded: {
            const os = text();
            if (/(^|\n)(ID|ID_LIKE)=.*(debian|ubuntu)/im.test(os))
                backend.backendId = "apt";
            else if (/(^|\n)(ID|ID_LIKE)=.*(arch|manjaro)/im.test(os))
                backend.backendId = "pacman";
        }
    }
}
