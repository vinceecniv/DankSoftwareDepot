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

    FileView {
        path: "/etc/os-release"

        onLoaded: {
            const os = text();
            if (/(^|\n)(ID|ID_LIKE)=.*(debian|ubuntu)/im.test(os))
                backend.backendId = "apt";
        }
    }
}
