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

    // "dnf" (Fedora/RHEL family, default) or "apt" (Debian/Ubuntu family)
    property string backendId: "dnf"

    // Transaction helper implementing the NDJSON event protocol
    readonly property string packageHelper: Qt.resolvedUrl("scripts/" + (backendId === "apt" ? "apt_helper.py" : "rpm_helper.py")).toString().replace("file://", "")

    // Command for a privileged helper transaction
    function helperCommand(action, specs) {
        return ["pkexec", "python3", packageHelper, action].concat(specs);
    }

    // Installed-version listing used for post-run verification; both
    // backends print "name<TAB>version" lines.
    function installedVersionsCommand(names) {
        if (backendId === "apt")
            return ["dpkg-query", "-W", "-f", "${Package}\\t${Version}\\n"].concat(names);
        return ["rpm", "-q", "--qf", "%{NAME}\\t%{EVR}\\n"].concat(names);
    }

    readonly property string metadataHelper: Qt.resolvedUrl("scripts/pkg_backend.py").toString().replace("file://", "")

    // Full installed inventory as "name<TAB>version<TAB>bytes<TAB>installtime"
    function installedTableCommand() {
        if (backendId === "apt")
            return ["python3", metadataHelper, "installed-table"];
        return ["sh", "-c", "rpm -qa --qf '%{NAME}\\t%{VERSION}-%{RELEASE}\\t%{SIZE}\\t%{INSTALLTIME}\\n' 2>/dev/null | sort"];
    }

    // Shell fragment printing one installed package name per line (embedded
    // in compound sh commands)
    readonly property string installedNamesShellFragment: backendId === "apt" ? "dpkg-query -W -f '${Package}\\n' 2>/dev/null" : "rpm -qa --qf '%{NAME}\\n' 2>/dev/null"

    // Available versions for the previous-versions feature. dnf prints
    // plain ascending version lines; the apt path prints a JSON array
    // (newest first, installed flagged) — consumers branch on the shape.
    function availableVersionsCommand(name) {
        if (backendId === "apt")
            return ["python3", metadataHelper, "versions", name];
        return ["sh", "-c", "LC_ALL=C dnf -Cq repoquery --qf '%{version}-%{release}\\n' " + name + " 2>/dev/null | sort -uV"];
    }

    // Packages whose update warrants the reboot recommendation
    readonly property var rebootPackagePattern: backendId === "apt" ? /^(linux-image|linux-firmware|systemd|libc6|dbus|mesa|grub|shim|intel-microcode|amd64-microcode|nvidia)/ : /^(kernel|linux-firmware|systemd|glibc|dbus|mesa|amd-gpu-firmware|intel-gpu-firmware|nvidia|microcode_ctl|shim|grub2)/

    // Human label of the system package source ("Install from %1")
    readonly property string systemRepoLabel: backendId === "apt" ? "Debian" : "Fedora"

    FileView {
        path: "/etc/os-release"

        onLoaded: {
            const os = text();
            if (/(^|\n)(ID|ID_LIKE)=.*(debian|ubuntu)/im.test(os))
                backend.backendId = "apt";
        }
    }
}
