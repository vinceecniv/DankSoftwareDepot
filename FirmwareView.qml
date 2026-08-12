import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

// Firmware inventory tab: all devices fwupd knows about, which ones support
// firmware updates, current versions, and release notes on demand.
Item {
    id: view

    property var firmware: null      // FirmwareService (optional)

    function focusSearch() {
        searchField.forceActiveFocus();
    }

    property var devices: []         // {deviceId, name, vendor, version, updatable, plugin}
    property bool loading: true
    property string searchText: ""
    property var releasesByDevice: ({})  // deviceId -> [{version, notesHtml}] | "loading"

    Component.onCompleted: {
        reload();
        Ui.steadyCursorFor(searchField);
        Ui.softenScrollbar(deviceList);
    }

    function reload() {
        loading = true;
        devicesProcess.running = true;
    }

    // Device-type icon from the fwupd name/plugin
    function deviceIcon(dev) {
        const hay = ((dev.name || "") + " " + (dev.plugin || "")).toLowerCase();
        if (hay.indexOf("fingerprint") !== -1 || hay.indexOf("goodix") !== -1 || hay.indexOf("synaptics_prometheus") !== -1)
            return "fingerprint";
        if (hay.indexOf("camera") !== -1 || hay.indexOf("webcam") !== -1)
            return "photo_camera";
        if (hay.indexOf("touchpad") !== -1 || hay.indexOf("trackpad") !== -1 || hay.indexOf("synaptics") !== -1 || hay.indexOf("elan") !== -1)
            return "touch_app";
        if (hay.indexOf("keyboard") !== -1)
            return "keyboard";
        if (hay.indexOf("mouse") !== -1 || hay.indexOf("unifying") !== -1 || hay.indexOf("receiver") !== -1 || hay.indexOf("logitech") !== -1)
            return "mouse";
        if (hay.indexOf("bluetooth") !== -1)
            return "bluetooth";
        if (hay.indexOf("wifi") !== -1 || hay.indexOf("wireless") !== -1 || hay.indexOf("wlan") !== -1 || hay.indexOf("network") !== -1 || hay.indexOf("ethernet") !== -1)
            return "wifi";
        if (hay.indexOf("nvme") !== -1 || hay.indexOf("ssd") !== -1 || hay.indexOf("scsi") !== -1 || hay.indexOf("disk") !== -1 || hay.indexOf("storage") !== -1 || hay.indexOf("card") !== -1 && hay.indexOf("gb") !== -1)
            return "hard_drive";
        if (hay.indexOf("sd card") !== -1 || hay.indexOf("mmc") !== -1)
            return "sd_card";
        if (hay.indexOf("battery") !== -1)
            return "battery_full";
        if (hay.indexOf("display") !== -1 || hay.indexOf("monitor") !== -1 || hay.indexOf("panel") !== -1 || hay.indexOf("edp") !== -1)
            return "monitor";
        if (hay.indexOf("audio") !== -1 || hay.indexOf("speaker") !== -1 || hay.indexOf("sound") !== -1)
            return "volume_up";
        if (hay.indexOf("tpm") !== -1 || hay.indexOf("bootguard") !== -1 || hay.indexOf(" ca ") !== -1 || hay.indexOf("secure") !== -1 || hay.indexOf("dbx") !== -1 || hay.indexOf("kek") !== -1 || hay.indexOf("uefi_db") !== -1 || hay.indexOf("uefi_pk") !== -1)
            return "security";
        if (hay.indexOf("thunderbolt") !== -1 || hay.indexOf("usb4") !== -1)
            return "bolt";
        if (hay.indexOf("dock") !== -1 || hay.indexOf("hub") !== -1 || hay.indexOf("usb") !== -1)
            return "usb";
        if (hay.indexOf("cpu") !== -1 || hay.indexOf("core") !== -1 || hay.indexOf("ryzen") !== -1 || hay.indexOf("processor") !== -1 || hay.indexOf("microcode") !== -1)
            return "memory";
        if (hay.indexOf("gpu") !== -1 || hay.indexOf("graphics") !== -1 || hay.indexOf("radeon") !== -1 || hay.indexOf("geforce") !== -1)
            return "smart_display";
        return "developer_board";
    }

    function _sanitize(text) {
        if (firmware)
            return firmware._sanitize(text);
        if (!text)
            return "";
        let t = text.replace(/<li>/gi, "\n• ").replace(/<\/(p|li|ul|ol)>/gi, "\n").replace(/<[^>]*>/g, "");
        t = t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        return t.split("\n").map(line => line.trim()).filter(line => line.length > 0).join("<br>");
    }

    readonly property var filteredDevices: {
        const needle = searchText.toLowerCase();
        const rows = devices.filter(dev => {
            if (!needle)
                return true;
            return Ui.matchesWords((dev.name + " " + dev.vendor).toLowerCase(), needle);
        });
        rows.sort((a, b) => {
            if (a.updatable !== b.updatable)
                return a.updatable ? -1 : 1;
            return a.name.localeCompare(b.name);
        });
        return rows;
    }

    readonly property int updatableCount: devices.filter(dev => dev.updatable).length

    function loadReleases(deviceId) {
        if (releasesByDevice[deviceId] !== undefined)
            return;
        const updated = Object.assign({}, releasesByDevice);
        updated[deviceId] = "loading";
        releasesByDevice = updated;
        releasesProcess._target = deviceId;
        releasesProcess.command = ["fwupdmgr", "get-releases", deviceId, "--json"];
        releasesProcess.running = true;
    }

    Process {
        id: devicesProcess
        command: ["fwupdmgr", "get-devices", "--json"]

        stdout: StdioCollector {
            onStreamFinished: {
                const found = [];
                try {
                    const data = JSON.parse(text);
                    for (const dev of data.Devices || []) {
                        if (!dev.Name)
                            continue;
                        const flags = dev.Flags || [];
                        found.push({
                            deviceId: dev.DeviceId || "",
                            name: dev.Name,
                            vendor: dev.Vendor || "",
                            version: dev.Version || "",
                            plugin: dev.Plugin || "",
                            updatable: flags.indexOf("updatable") !== -1
                        });
                    }
                } catch (e) {
                }
                view.devices = found;
                view.loading = false;
            }
        }
    }

    Process {
        id: releasesProcess

        property string _target: ""

        stdout: StdioCollector {
            onStreamFinished: {
                const releases = [];
                try {
                    const data = JSON.parse(text);
                    for (const rel of (data.Releases || []).slice(0, 4)) {
                        releases.push({
                            version: rel.Version || "",
                            notesHtml: view._sanitize(rel.Description || ""),
                            summary: rel.Summary || ""
                        });
                    }
                } catch (e) {
                }
                const updated = Object.assign({}, view.releasesByDevice);
                updated[releasesProcess._target] = releases;
                view.releasesByDevice = updated;
            }
        }

        onExited: (exitCode, exitStatus) => {
            // get-releases fails for devices without LVFS metadata
            if (exitCode !== 0 && view.releasesByDevice[releasesProcess._target] === "loading") {
                const updated = Object.assign({}, view.releasesByDevice);
                updated[releasesProcess._target] = [];
                view.releasesByDevice = updated;
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.spacingM

        // Informative banner when firmware updates are disabled in settings:
        // the inventory below still works, but updates are not checked or run.
        Rectangle {
            Layout.fillWidth: true
            visible: view.firmware === null
            implicitHeight: disabledRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.warning, 0.12)

            RowLayout {
                id: disabledRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                DankIcon {
                    name: "info"
                    size: 18
                    color: Theme.warning
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("Firmware updates are disabled in the plugin settings — this inventory is informational only; firmware is not checked or updated.")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                Item {
                    Layout.preferredWidth: firmwareEnableButton.width
                    Layout.preferredHeight: firmwareEnableButton.height

                    DankButton {
                        id: firmwareEnableButton
                        buttonHeight: 28
                        horizontalPadding: Theme.spacingM
                        text: Tr.t("Enable")
                        backgroundColor: Theme.buttonBg
                        textColor: Theme.buttonText
                        onClicked: PluginService.savePluginData("dankSoftwareDepot", "includeFirmware", true)
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingM

            DankTextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: Tr.t("Search devices…")
                leftIconName: "search"
                showClearButton: true
                onTextChanged: view.searchText = text
                Keys.onEscapePressed: event => {
                    if (text !== "") {
                        clear();
                    } else {
                        event.accepted = false;
                    }
                }
            }

        }

        StyledText {
            Layout.fillWidth: true
            visible: !view.loading
            text: Tr.t("%1 devices · %2 support firmware updates (fwupd/LVFS)").arg(view.devices.length).arg(view.updatableCount)
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
        }

        DankListView {
            id: deviceList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Theme.spacingXS
            model: view.filteredDevices
            visible: !view.loading

            delegate: Rectangle {
                id: deviceRow

                required property var modelData

                readonly property var releases: view.releasesByDevice[modelData.deviceId]
                property bool expanded: false

                width: deviceList.width
                implicitHeight: deviceContent.implicitHeight + Theme.spacingS * 2
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Theme.surfaceContainerHigh, modelData.updatable ? 0.8 : 0.35)
                opacity: modelData.updatable ? 1 : 0.75
                clip: true

                Behavior on implicitHeight {
                    NumberAnimation {
                        duration: Theme.shortDuration
                        easing.type: Theme.standardEasing
                    }
                }

                // Free row space toggles the release list (updatable devices)
                MouseArea {
                    anchors.fill: parent
                    enabled: deviceRow.modelData.updatable
                    cursorShape: deviceRow.modelData.updatable ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        deviceRow.expanded = !deviceRow.expanded;
                        if (deviceRow.expanded)
                            view.loadReleases(deviceRow.modelData.deviceId);
                    }
                }

                ColumnLayout {
                    id: deviceContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacingS
                    spacing: Theme.spacingS

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingM

                        DankIcon {
                            name: view.deviceIcon(deviceRow.modelData)
                            size: 22
                            color: deviceRow.modelData.updatable ? Theme.primary : Theme.surfaceVariantText
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            StyledText {
                                Layout.fillWidth: true
                                text: deviceRow.modelData.name
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                            }

                            StyledText {
                                Layout.fillWidth: true
                                visible: text !== ""
                                text: {
                                    const parts = [];
                                    if (deviceRow.modelData.vendor)
                                        parts.push(deviceRow.modelData.vendor);
                                    if (deviceRow.modelData.version)
                                        parts.push("firmware " + deviceRow.modelData.version);
                                    return parts.join(" · ");
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                elide: Text.ElideRight
                            }
                        }

                        Rectangle {
                            visible: deviceRow.modelData.updatable
                            Layout.preferredWidth: updatableChip.implicitWidth + 14
                            Layout.preferredHeight: 18
                            radius: 9
                            color: Theme.withAlpha(Theme.success, 0.15)

                            StyledText {
                                id: updatableChip
                                anchors.centerIn: parent
                                text: Tr.t("Updatable")
                                font.pixelSize: Theme.fontSizeSmall - 2
                                color: Theme.success
                            }
                        }

                        DankActionButton {
                            buttonSize: 26
                            iconName: deviceRow.expanded ? "expand_less" : "expand_more"
                            iconSize: 16
                            iconColor: Theme.surfaceVariantText
                            enabled: deviceRow.modelData.updatable
                            opacity: deviceRow.modelData.updatable ? 1 : 0
                            tooltipText: Tr.t("Firmware releases")
                            onClicked: {
                                deviceRow.expanded = !deviceRow.expanded;
                                if (deviceRow.expanded)
                                    view.loadReleases(deviceRow.modelData.deviceId);
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: deviceRow.expanded
                        spacing: Theme.spacingS

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 1
                            color: Theme.withAlpha(Theme.outline, 0.15)
                        }

                        StyledText {
                            visible: deviceRow.releases === "loading"
                            text: Tr.t("Loading firmware releases…")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            visible: Array.isArray(deviceRow.releases) && deviceRow.releases.length === 0
                            text: Tr.t("No firmware releases published on LVFS for this device.")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        Repeater {
                            model: Array.isArray(deviceRow.releases) ? deviceRow.releases : []

                            delegate: ColumnLayout {
                                id: releaseEntry

                                required property var modelData
                                required property int index

                                Layout.fillWidth: true
                                spacing: 2

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.spacingS

                                    Rectangle {
                                        Layout.preferredWidth: relVersion.implicitWidth + 14
                                        Layout.preferredHeight: 18
                                        radius: 9
                                        color: Theme.withAlpha(Theme.primary, 0.12)

                                        StyledText {
                                            id: relVersion
                                            anchors.centerIn: parent
                                            text: releaseEntry.modelData.version || "—"
                                            font.pixelSize: Theme.fontSizeSmall - 2
                                            font.weight: Font.Medium
                                            color: Theme.primary
                                        }
                                    }

                                    StyledText {
                                        visible: releaseEntry.index === 0 && releaseEntry.modelData.version === deviceRow.modelData.version
                                        text: Tr.t("installed")
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.success
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        visible: (releaseEntry.modelData.summary || "") !== ""
                                        text: releaseEntry.modelData.summary
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                    }
                                }

                                SelectableText {
                                    Layout.fillWidth: true
                                    visible: (releaseEntry.modelData.notesHtml || "") !== ""
                                    text: releaseEntry.modelData.notesHtml
                                    textFormat: Text.RichText
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceText
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                }
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: view.loading

            Column {
                anchors.centerIn: parent
                spacing: Theme.spacingM

                DankSpinner {
                    anchors.horizontalCenter: parent.horizontalCenter
                    size: 40
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Tr.t("Reading device list…")
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                }
            }
        }
    }
}
