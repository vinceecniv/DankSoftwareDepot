pragma Singleton
import QtQuick

// The package-backend seam: every entry point that is specific to the
// system package manager, in one place. A Debian/Arch port swaps these
// values (and ships a helper speaking the protocol in PROTOCOL.md);
// the QML call sites stay unchanged.
Item {
    // Transaction helper implementing the NDJSON event protocol
    readonly property string packageHelper: Qt.resolvedUrl("scripts/rpm_helper.py").toString().replace("file://", "")

    // Command prefix for a privileged helper transaction
    function helperCommand(action, specs) {
        return ["pkexec", "python3", packageHelper, action].concat(specs);
    }
}
