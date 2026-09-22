import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell.Io
import qs.Common
import qs.Modals.FileBrowser
import qs.Widgets

// Installing an AppImage from a file, asked in one place.
Item {
    id: dialog

    property bool animActive: false
    readonly property bool showing: animActive || closeTimer.running

    Timer {
        id: closeTimer
        interval: 220
        repeat: false
    }

    Shortcut {
        sequence: "Escape"
        enabled: dialog.showing
        onActivated: dialog.close()
    }

    // Path or URL as typed, picked or handed over
    property string source: ""
    property var info: null            // inspection of a local file, or null
    property bool inspecting: false
    property bool failed: false
    property bool busy: false          // an install this dialog started

    // args for scripts/appimage.py, and the name to show while it runs
    signal installRequested(var args, string label)

    readonly property string scriptPath: Qt.resolvedUrl("scripts/appimage.py").toString().replace("file://", "")
    readonly property bool sourceIsUrl: /^https?:\/\//.test(source.trim())
    readonly property var installedMatch: (info && info.installed) ? info.installed : null

    function open() {
        source = "";
        info = null;
        failed = false;
        closeTimer.stop();
        animActive = true;
        sourceField.text = "";
        sourceField.forceActiveFocus();
    }

    function openWithFile(path) {
        source = path;
        sourceField.text = path;
        info = null;
        failed = false;
        closeTimer.stop();
        animActive = true;
        inspect();
    }

    function close() {
        if (!animActive)
            return;
        animActive = false;
        inspecting = false;
        closeTimer.restart();
    }

    function accept() {
        const target = source.trim();
        if (target === "" || inspecting || failed || busy)
            return;

        let label = "AppImage";
        if (info && info.name)
            label = info.name;
        else if (sourceIsUrl)
            label = target.split("/").pop().replace(/\.AppImage$/i, "") || "AppImage";

        // scripts/appimage.py takes its mode as a --flag, and replacing an
        // AppImage that is already installed is its own mode: an --install
        // over the top leaves the old one behind.
        if (installedMatch && installedMatch.id)
            dialog.installRequested(["--replace", installedMatch.id, target], label);
        else
            dialog.installRequested(["--install", target, (info && info.name) ? info.name : ""], label);
        dialog.close();
    }

    // Only a local file can be looked into; a URL is a download first and an
    // AppImage afterwards, so it is offered as it stands
    function inspect() {
        const path = source.trim();
        info = null;
        failed = false;
        if (path === "" || sourceIsUrl || inspectProc.running)
            return;
        inspecting = true;
        inspectProc.command = [Backend.python, scriptPath, "--inspect", path];
        inspectProc.running = true;
    }

    Timer {
        id: inspectDebounce
        interval: 350
        repeat: false
        onTriggered: dialog.inspect()
    }

    Process {
        id: inspectProc

        stdout: StdioCollector {
            onStreamFinished: {
                let result = null;
                try {
                    result = JSON.parse(text);
                } catch (e) {
                    result = null;
                }
                if (result && result.ok)
                    dialog.info = result;
                else
                    dialog.failed = true;
            }
        }

        onExited: (exitCode, exitStatus) => {
            dialog.inspecting = false;
            if (dialog.info === null)
                dialog.failed = true;
        }
    }

    Loader {
        id: pickerLoader
        active: false
        sourceComponent: Component {
            FileBrowserModal {
                browserTitle: Tr.t("Select an AppImage")
                fileExtensions: ["*.AppImage", "*.appimage", "*.*"]
                onFileSelected: path => {
                    dialog.source = path;
                    sourceField.text = path;
                    dialog.inspect();
                }
            }
        }
    }

    anchors.fill: parent
    visible: showing
    z: 9999

    Rectangle {
        id: dim
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        opacity: dialog.animActive ? 1.0 : 0.0
        Behavior on opacity {
            NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutQuad }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: dialog.close()
        }
    }

    StyledRect {
        id: appimageSheet
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.spacingXL * 2, 480)
        height: sheetColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius + 4
        color: Ui.cardSurface
        border.width: 1

        scale: dialog.animActive ? 1.0 : 0.94
        opacity: dialog.animActive ? 1.0 : 0.0
        Behavior on scale {
            NumberAnimation {
                duration: dialog.animActive ? 320 : 200
                easing.type: dialog.animActive ? Easing.OutBack : Easing.InQuad
                easing.overshoot: 1.15
            }
        }
        Behavior on opacity {
            NumberAnimation { duration: Theme.longDuration; easing.type: Easing.OutQuad }
        }

        MouseArea {
            anchors.fill: parent
            onWheel: wheel => wheel.accepted = true
        }

        ColumnLayout {
            id: sheetColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingM

                Rectangle {
                    width: 32
                    height: 32
                    radius: 10
                    color: Theme.withAlpha(Theme.primary, 0.15)
                    DankIcon {
                        anchors.centerIn: parent
                        name: "note_add"
                        size: 18
                        color: Theme.primary
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("Install an AppImage")
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                }

                DankActionButton {
                    buttonSize: 28
                    iconName: "close"
                    iconSize: 16
                    iconColor: Theme.surfaceVariantText
                    tooltipText: Tr.t("Dismiss")
                    onClicked: dialog.close()
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingS

                DankTextField {
                    id: sourceField
                    Layout.fillWidth: true
                    placeholderText: Tr.t("Path or URL of an .AppImage…")
                    FieldPlaceholder {
                        text: Tr.t("Path or URL of an .AppImage…")
                    }
                    showClearButton: true
                    onTextChanged: {
                        dialog.source = text;
                        dialog.info = null;
                        dialog.failed = false;
                        inspectDebounce.restart();
                    }
                    onAccepted: dialog.accept()
                }

                DankActionButton {
                    buttonSize: 34
                    iconName: "folder_open"
                    iconSize: 18
                    iconColor: Theme.primary
                    tooltipText: Tr.t("Choose an AppImage file")
                    onClicked: {
                        pickerLoader.active = true;
                        if (pickerLoader.item)
                            pickerLoader.item.open();
                    }
                }
            }

            // Info Card
            Rectangle {
                Layout.fillWidth: true
                visible: dialog.inspecting || dialog.info !== null || dialog.failed
                implicitHeight: infoRow.implicitHeight + Theme.spacingM * 2
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Theme.surface, 0.5)
                border.color: dialog.failed ? Theme.withAlpha(Theme.error, 0.3) : Theme.withAlpha(Theme.outline, 0.1)
                border.width: 1

                RowLayout {
                    id: infoRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Theme.spacingM
                    spacing: Theme.spacingM

                    Image {
                        id: appIcon
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        source: (dialog.info && dialog.info.icon) ? "file://" + dialog.info.icon : ""
                        sourceSize.width: 80
                        sourceSize.height: 80
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        visible: status === Image.Ready
                    }

                    Rectangle {
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        radius: 10
                        color: dialog.failed ? Theme.withAlpha(Theme.error, 0.15) : Theme.withAlpha(Theme.primary, 0.15)
                        visible: !appIcon.visible

                        DankIcon {
                            anchors.centerIn: parent
                            name: dialog.failed ? "error" : "deployed_code"
                            size: 22
                            color: dialog.failed ? Theme.error : Theme.primary
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 3

                        StyledText {
                            Layout.fillWidth: true
                            text: {
                                if (dialog.failed)
                                    return Tr.t("That file could not be read as an AppImage.");
                                if (dialog.inspecting || !dialog.info)
                                    return Tr.t("Reading the AppImage…");
                                const version = dialog.info.version || "";
                                return version !== "" ? (dialog.info.name || "") + " " + version : (dialog.info.name || "");
                            }
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.DemiBold
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }

                        StyledText {
                            Layout.fillWidth: true
                            visible: dialog.info !== null && !dialog.failed
                            text: {
                                if (!dialog.info)
                                    return "";
                                const size = dialog.formatBytes(dialog.info.sizeBytes);
                                const line = dialog.installedMatch ? Tr.t("You already have this one — replace it with this build?") : Tr.t("Install this AppImage into your AppImages folder?");
                                return size !== "" ? line + " · " + size : line;
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacingXS
                spacing: 0

                Item {
                    Layout.fillWidth: true
                }

                // Paired button group matching AppDetailsDialog:
                // Left button (Cancel): outer left rounded (Theme.cornerRadius), inner right flat (4)
                // Right button (Install/Replace): inner left flat (4), outer right rounded (Theme.cornerRadius)
                // On hover: all 4 corners expand dynamically to pill shape (height / 2)!
                Rectangle {
                    id: cancelBtn
                    width: cancelRow.implicitWidth + 24
                    height: 32
                    property bool isHovered: cancelMa.containsMouse

                    topLeftRadius: isHovered ? (height / 2) : Theme.cornerRadius
                    bottomLeftRadius: isHovered ? (height / 2) : Theme.cornerRadius
                    topRightRadius: isHovered ? (height / 2) : 4
                    bottomRightRadius: isHovered ? (height / 2) : 4

                    Behavior on topLeftRadius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                    Behavior on bottomLeftRadius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                    Behavior on topRightRadius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                    Behavior on bottomRightRadius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                    color: isHovered ? Theme.withAlpha(Ui.chipSurfaceNested, 0.95) : Theme.withAlpha(Ui.chipSurfaceNested, 0.6)
                    Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                    border.width: 1
                    border.color: isHovered ? Theme.primarySelected : Theme.primaryHover
                    Behavior on border.color { ColorAnimation { duration: Theme.mediumDuration } }

                    scale: cancelMa.pressed ? 0.94 : (isHovered ? 1.02 : 1.0)
                    Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }

                    DankRipple {
                        id: cancelRip
                        anchors.fill: parent
                        cornerRadius: parent.topLeftRadius
                        rippleColor: Theme.surfaceText
                    }

                    RowLayout {
                        id: cancelRow
                        anchors.centerIn: parent
                        spacing: 6

                        DankIcon {
                            name: "close"
                            size: 14
                            color: Theme.surfaceText
                        }

                        StyledText {
                            text: Tr.t("Cancel")
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }
                    }

                    MouseArea {
                        id: cancelMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onPressed: (m) => cancelRip.trigger(m.x, m.y)
                        onClicked: dialog.close()
                    }
                }

                Rectangle {
                    id: acceptBtn
                    readonly property bool btnEnabled: dialog.source.trim() !== "" && !dialog.inspecting && !dialog.failed && !dialog.busy
                    width: acceptRow.implicitWidth + 24
                    height: 32
                    property bool isHovered: acceptMa.containsMouse && btnEnabled

                    topLeftRadius: isHovered ? (height / 2) : 4
                    bottomLeftRadius: isHovered ? (height / 2) : 4
                    topRightRadius: isHovered ? (height / 2) : Theme.cornerRadius
                    bottomRightRadius: isHovered ? (height / 2) : Theme.cornerRadius

                    Behavior on topLeftRadius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                    Behavior on bottomLeftRadius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                    Behavior on topRightRadius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }
                    Behavior on bottomRightRadius { NumberAnimation { duration: Theme.extraLongDuration; easing.type: Easing.OutExpo } }

                    color: isHovered ? Theme.withAlpha(Theme.primary, 0.25) : Theme.withAlpha(Theme.primary, 0.15)
                    Behavior on color { ColorAnimation { duration: Theme.mediumDuration } }
                    border.width: 1
                    border.color: isHovered ? Theme.primary : Theme.primarySelected
                    Behavior on border.color { ColorAnimation { duration: Theme.mediumDuration } }

                    scale: acceptMa.pressed ? 0.94 : (isHovered ? 1.02 : 1.0)
                    opacity: btnEnabled ? 1.0 : 0.5
                    Behavior on scale { NumberAnimation { duration: Theme.mediumDuration; easing.type: Easing.OutBack } }
                    Behavior on opacity { NumberAnimation { duration: Theme.mediumDuration } }

                    DankRipple {
                        id: acceptRip
                        anchors.fill: parent
                        cornerRadius: parent.topRightRadius
                        rippleColor: Theme.primary
                    }

                    RowLayout {
                        id: acceptRow
                        anchors.centerIn: parent
                        spacing: 6

                        DankIcon {
                            name: dialog.installedMatch ? "sync" : "download"
                            size: 14
                            color: Theme.primary
                        }

                        StyledText {
                            text: dialog.installedMatch ? Tr.t("Replace") : Tr.t("Install")
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Theme.primary
                        }
                    }

                    MouseArea {
                        id: acceptMa
                        anchors.fill: parent
                        hoverEnabled: acceptBtn.btnEnabled
                        cursorShape: acceptBtn.btnEnabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onPressed: (m) => {
                            if (acceptBtn.btnEnabled)
                                acceptRip.trigger(m.x, m.y);
                        }
                        onClicked: {
                            if (acceptBtn.btnEnabled)
                                dialog.accept();
                        }
                    }
                }
            }
        }
    }

    function formatBytes(bytes) {
        if (!bytes || bytes <= 0)
            return "";
        if (bytes >= 1e9)
            return (bytes / 1e9).toFixed(1) + " GB";
        if (bytes >= 1e6)
            return Math.round(bytes / 1e6) + " MB";
        return Math.max(1, Math.round(bytes / 1e3)) + " kB";
    }
}
