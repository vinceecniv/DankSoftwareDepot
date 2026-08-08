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

    // The same install, shown as a command for anyone who would rather run
    // it themselves
    readonly property string packageHelperInstallHint: backendId === "apt" ? "sudo apt install python3-apt" : (backendId === "pacman" ? "sudo pacman -S --needed pyalpm" : "sudo dnf install python3-libdnf5")

    // Bootstrapping the bindings cannot go through the helper that needs
    // them, so this one install runs the package manager's command line
    // directly — the only place in the plugin that does.
    readonly property var packageHelperInstallCommand: {
        if (backendId === "apt")
            return ["pkexec", "apt-get", "install", "-y", "python3-apt"];
        if (backendId === "pacman")
            return ["pkexec", "pacman", "-S", "--needed", "--noconfirm", "pyalpm"];
        return ["pkexec", "dnf", "install", "-y", "python3-libdnf5"];
    }

    property bool packageHelperInstalling: false
    // Why the last install attempt failed, "" when there was none
    property string packageHelperInstallError: ""

    function installPackageHelper() {
        if (packageHelperInstalling)
            return;
        packageHelperInstallError = "";
        packageHelperInstalling = true;
        installProcess._output = "";
        installProcess.command = packageHelperInstallCommand;
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
            backend.packageHelperInstalling = false;
            if (exitCode !== 0)
                backend.packageHelperInstallError = exitCode === 126 || exitCode === 127 ? Tr.t("the authorisation was refused") : (_output || Tr.t("the installation failed"));
            // Either way the selftest, not the exit code, decides
            backend.checkPackageHelper();
        }
    }

    function checkPackageHelper() {
        if (selftestProcess.running)
            return;
        selftestProcess._reason = "";
        selftestProcess.command = ["python3", packageHelper, "selftest"];
        selftestProcess.running = true;
    }

    onBackendIdChanged: checkPackageHelper()
    Component.onCompleted: checkPackageHelper()

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
