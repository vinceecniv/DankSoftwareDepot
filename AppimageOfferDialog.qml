import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Common
import qs.Modals.FileBrowser
import qs.Widgets

// Installing an AppImage from a file, asked in one place.
//
// There are two ways in — the button in the toolbar, and double-clicking a
// .appimage in the file manager — and they used to look like two different
// features: a row wedged in between the search field and the results, and a
// card above them. One dialog serves both. It opens empty from the toolbar
// and already filled from the file manager, which is the only difference
// between them worth keeping.
//
// The file is read before anything is offered, because the question is not
// the same for a new app as for a newer build of one that is already here.
// The reading never touches the file: an AppImage has to be executable to
// list its own contents, and a fresh download is not.
Item {
    id: dialog

    property bool showing: false
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
        showing = true;
        sourceField.text = "";
        sourceField.forceActiveFocus();
    }

    function openWithFile(path) {
        source = path;
        sourceField.text = path;
        info = null;
        failed = false;
        showing = true;
        inspect();
    }

    function close() {
        showing = false;
        inspecting = false;
    }

    // Only a local file can be looked into; a URL is a download first and an
    // AppImage afterwards, so it is offered as it stands
    function inspect() {
        const path = source.trim();
        info = null;
        failed = false;
        if (path === "" || sourceIsUrl || inspectProcess.running)
            return;
        inspecting = true;
        inspectProcess.command = ["python3", scriptPath, "--inspect", path];
        inspectProcess.running = true;
    }

    function accept() {
        const path = source.trim();
        if (path === "")
            return;
        const label = (info && info.name) ? info.name : path.split("/").pop().replace(/\.appimage$/i, "");
        if (installedMatch && installedMatch.id)
            installRequested(["--replace", installedMatch.id, path], label);
        else
            installRequested(["--install", path, (info && info.name) ? info.name : ""], label);
        close();
    }

    Process {
        id: inspectProcess

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

    // Typing a path by hand deserves the same answer as dropping one in,
    // once the typing stops
    Timer {
        id: inspectDebounce
        interval: 400
        onTriggered: dialog.inspect()
    }

    Loader {
        id: pickerLoader
        active: false

        sourceComponent: FileBrowserModal {
            browserTitle: Tr.t("Choose an AppImage file")
            browserIcon: "note_add"
            browserType: "generic"
            fileExtensions: ["*.AppImage", "*.appimage"]

            onFileSelected: path => {
                const clean = path.replace("file://", "");
                dialog.source = clean;
                sourceField.text = clean;
                dialog.inspect();
            }
        }
    }

    anchors.fill: parent
    visible: showing
    z: 120

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)

        MouseArea {
            anchors.fill: parent
            onClicked: dialog.close()
            onWheel: wheel => wheel.accepted = true
        }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.spacingXL * 2, 520)
        height: sheetColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        border.width: 1
        border.color: Theme.withAlpha(Theme.outline, 0.2)

        MouseArea {
            anchors.fill: parent
            onWheel: wheel => wheel.accepted = true
        }

        Keys.onEscapePressed: dialog.close()

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

                DankIcon {
                    name: "note_add"
                    size: 22
                    color: Theme.primary
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
                    buttonSize: 32
                    iconName: "folder_open"
                    iconSize: 17
                    iconColor: Theme.surfaceText
                    tooltipText: Tr.t("Choose an AppImage file")
                    onClicked: {
                        pickerLoader.active = true;
                        if (pickerLoader.item)
                            pickerLoader.item.open();
                    }
                }
            }

            // What the file turned out to be. A URL says nothing until it is
            // downloaded, so it gets no panel rather than an empty one.
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingM
                visible: dialog.inspecting || dialog.info !== null || dialog.failed

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

                DankIcon {
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    visible: !appIcon.visible
                    name: dialog.failed ? "error" : "deployed_code"
                    size: 32
                    color: dialog.failed ? Theme.error : Theme.primary
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

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

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacingXS
                spacing: Theme.spacingS

                Item {
                    Layout.fillWidth: true
                }

                DankButton {
                    buttonHeight: 32
                    horizontalPadding: Theme.spacingM
                    text: Tr.t("Cancel")
                    backgroundColor: Theme.withAlpha(Theme.surfaceVariantText, 0.12)
                    textColor: Theme.surfaceText
                    onClicked: dialog.close()
                }

                DankButton {
                    buttonHeight: 32
                    horizontalPadding: Theme.spacingM
                    iconName: dialog.installedMatch ? "sync" : "download"
                    iconSize: 14
                    text: dialog.installedMatch ? Tr.t("Replace") : Tr.t("Install")
                    backgroundColor: Theme.primary
                    textColor: Theme.primaryText
                    enabled: dialog.source.trim() !== "" && !dialog.inspecting && !dialog.failed && !dialog.busy
                    onClicked: dialog.accept()
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
