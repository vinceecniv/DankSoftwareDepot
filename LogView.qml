import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

// Log tab: chronological history of every action this plugin performed
// (update runs, installs, uninstalls, restores, firmware). Entries are
// collapsed by default and expand to show per-package details.
Item {
    id: view

    property var logger: null
    property string searchText: ""
    property var expandedKeys: ({})

    function focusSearch() {
        searchField.forceActiveFocus();
    }

    // Open the newest entry, for the jump from a finished run: the thing you
    // came to read should already be open when you arrive.
    function expandNewest() {
        const entries = (logger && logger.entries) || [];
        if (entries.length === 0)
            return;
        const newest = entries[entries.length - 1];
        const updated = Object.assign({}, expandedKeys);
        updated[String(newest.ts) + "/" + (newest.type || "")] = true;
        expandedKeys = updated;
        searchText = "";
        logList.positionViewAtBeginning();
    }

    function iconFor(type) {
        switch (type) {
        case "install":
            return "add_circle";
        case "uninstall":
            return "delete";
        case "downgrade":
            return "history";
        case "update-failed":
            return "error";
        case "update-cancelled":
            return "cancel";
        default:
            return "deployed_code_update";
        }
    }

    function colorFor(type) {
        switch (type) {
        case "update-failed":
            return Theme.error;
        case "update-cancelled":
            return Theme.surfaceVariantText;
        case "uninstall":
            return Theme.warning;
        default:
            return Theme.primary;
        }
    }

    function formatWhen(ts) {
        const date = new Date(ts * 1000);
        const now = new Date();
        const dayMs = 24 * 3600 * 1000;
        const time = Qt.formatTime(date, "hh:mm");
        if (date.toDateString() === now.toDateString())
            return Tr.t("Today %1").arg(time);
        if (date.toDateString() === new Date(now.getTime() - dayMs).toDateString())
            return Tr.t("Yesterday %1").arg(time);
        return Qt.formatDate(date, "d MMM yyyy") + " " + time;
    }

    readonly property var visibleEntries: {
        const all = (logger ? logger.entries : []) || [];
        const needle = searchText.trim().toLowerCase();
        const result = [];
        for (let i = all.length - 1; i >= 0; i--) {
            const entry = all[i];
            if (needle !== "") {
                const haystack = ((entry.title || "") + " " + (entry.items || []).map(it => it.name || "").join(" ")).toLowerCase();
                if (!Ui.matchesWords(haystack, needle))
                    continue;
            }
            result.push(entry);
        }
        return result;
    }

    Component.onCompleted: {
        Ui.steadyCursorFor(searchField);
        Ui.softenScrollbar(logList);
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.spacingM

        DankTextField {
            id: searchField
            Layout.fillWidth: true
            placeholderText: Tr.t("Search the action log…")
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

        DankListView {
            id: logList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Theme.spacingXS
            model: view.visibleEntries
            visible: view.visibleEntries.length > 0

            delegate: Rectangle {
                id: entryRow

                required property var modelData

                readonly property string entryKey: String(modelData.ts) + "/" + (modelData.type || "")
                readonly property bool expanded: view.expandedKeys[entryKey] === true
                readonly property var entryItems: modelData.items || []

                width: logList.width
                implicitHeight: entryColumn.implicitHeight + Theme.spacingS * 2
                radius: Theme.cornerRadius
                color: entryHover.hovered ? Theme.surfaceContainerHigh : Theme.withAlpha(Theme.surfaceContainerHigh, 0.45)

                HoverHandler {
                    id: entryHover
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: entryRow.entryItems.length > 0
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: {
                        const updated = Object.assign({}, view.expandedKeys);
                        updated[entryRow.entryKey] = !entryRow.expanded;
                        view.expandedKeys = updated;
                    }
                }

                ColumnLayout {
                    id: entryColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    spacing: Theme.spacingXS

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingM

                        DankIcon {
                            name: view.iconFor(entryRow.modelData.type)
                            size: 20
                            color: view.colorFor(entryRow.modelData.type)
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            StyledText {
                                Layout.fillWidth: true
                                text: entryRow.modelData.title || ""
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                            }

                            StyledText {
                                text: view.formatWhen(entryRow.modelData.ts || 0)
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }

                        Rectangle {
                            visible: entryRow.entryItems.length > 0
                            Layout.preferredWidth: countChip.implicitWidth + 14
                            Layout.preferredHeight: 20
                            radius: 10
                            color: Theme.withAlpha(Theme.primary, 0.12)

                            StyledText {
                                id: countChip
                                anchors.centerIn: parent
                                text: (entryRow.entryItems.length === 1 ? Tr.t("%1 item") : Tr.t("%1 items")).arg(entryRow.entryItems.length)
                                font.pixelSize: Theme.fontSizeSmall - 2
                                color: Theme.primary
                            }
                        }

                        DankIcon {
                            visible: entryRow.entryItems.length > 0
                            name: entryRow.expanded ? "expand_less" : "expand_more"
                            size: 18
                            color: Theme.surfaceVariantText
                        }
                    }

                    // Expanded details: one row per package
                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 32
                        visible: entryRow.expanded
                        spacing: 2

                        Repeater {
                            model: entryRow.expanded ? entryRow.entryItems : []

                            delegate: ColumnLayout {
                                id: itemRow

                                required property var modelData
                                // The tool's own words behind a failed row —
                                // kept out of sight until asked for
                                property bool showError: false
                                readonly property string rawError: modelData.error || ""

                                Layout.fillWidth: true
                                spacing: 1

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.spacingS

                                    DankIcon {
                                        name: itemRow.modelData.status === "error" ? "error" : "check_circle"
                                        size: 13
                                        color: itemRow.modelData.status === "error" ? Theme.error : Theme.success
                                    }

                                    StyledText {
                                        text: itemRow.modelData.name || ""
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                        Layout.maximumWidth: 260
                                    }

                                    StyledText {
                                        visible: (itemRow.modelData.from || "") !== "" || (itemRow.modelData.to || "") !== ""
                                        text: {
                                            if ((itemRow.modelData.from || "") !== "" && (itemRow.modelData.to || "") !== "")
                                                return itemRow.modelData.from + " → " + itemRow.modelData.to;
                                            return itemRow.modelData.to || itemRow.modelData.from || "";
                                        }
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideMiddle
                                        Layout.maximumWidth: 240
                                    }

                                    StyledText {
                                        visible: (itemRow.modelData.reason || "") !== ""
                                        text: "· " + (itemRow.modelData.reason || "")
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.error
                                        elide: Text.ElideRight
                                        Layout.maximumWidth: 260
                                    }

                                    Item {
                                        Layout.fillWidth: true
                                    }

                                    StyledText {
                                        visible: itemRow.rawError !== ""
                                        text: itemRow.showError ? Tr.t("Hide details") : Tr.t("Show details")
                                        font.pixelSize: Theme.fontSizeSmall - 2
                                        font.underline: rawToggleArea.containsMouse
                                        color: Theme.error

                                        MouseArea {
                                            id: rawToggleArea
                                            anchors.fill: parent
                                            anchors.margins: -4
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: itemRow.showError = !itemRow.showError
                                        }
                                    }

                                    StyledText {
                                        visible: (itemRow.modelData.source || "") !== ""
                                        text: Tr.t(itemRow.modelData.source || "")
                                        font.pixelSize: Theme.fontSizeSmall - 2
                                        color: Theme.surfaceVariantText
                                    }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 21
                                    Layout.bottomMargin: Theme.spacingXS
                                    visible: itemRow.showError && itemRow.rawError !== ""
                                    implicitHeight: rawErrorLabel.implicitHeight + Theme.spacingS * 2
                                    radius: Theme.cornerRadius / 2
                                    color: Theme.withAlpha(Theme.surfaceVariant, 0.5)

                                    StyledText {
                                        id: rawErrorLabel
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.margins: Theme.spacingS
                                        text: itemRow.rawError
                                        font.family: Theme.monoFontFamily
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.surfaceVariantText
                                        wrapMode: Text.Wrap
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Empty state
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: view.visibleEntries.length === 0

            Column {
                anchors.centerIn: parent
                spacing: Theme.spacingM

                DankIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: view.searchText.trim() !== "" ? "search_off" : "history"
                    size: 48
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: view.searchText.trim() !== "" ? Tr.t("No log entries match \"%1\"").arg(view.searchText.trim()) : Tr.t("No actions logged yet")
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: view.searchText.trim() === ""
                    text: Tr.t("Updates, installs and removals will appear here (kept for 90 days)")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.withAlpha(Theme.surfaceVariantText, 0.7)
                }
            }
        }
    }
}
