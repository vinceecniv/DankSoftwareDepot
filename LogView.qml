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

    function _dayKey(ts) {
        const d = new Date(ts * 1000);
        return d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate();
    }

    function _dayLabel(ts) {
        const now = new Date();
        const d = new Date(ts * 1000);
        if (_dayKey(ts) === (now.getFullYear() + "-" + now.getMonth() + "-" + now.getDate()))
            return Tr.t("Today");
        const yesterday = new Date(now.getTime() - 86400000);
        if (_dayKey(ts) === (yesterday.getFullYear() + "-" + yesterday.getMonth() + "-" + yesterday.getDate()))
            return Tr.t("Yesterday");
        return d.toLocaleDateString(Qt.locale(), Locale.LongFormat);
    }

    readonly property var visibleEntries: {
        const all = (logger ? logger.entries : []) || [];
        const needle = searchText.trim().toLowerCase();
        const result = [];
        let lastDay = "";
        for (let i = all.length - 1; i >= 0; i--) {
            const entry = all[i];
            if (needle !== "") {
                const haystack = ((entry.title || "") + " " + (entry.items || []).map(it => it.name || "").join(" ")).toLowerCase();
                if (!Ui.matchesWords(haystack, needle))
                    continue;
            }
            // The first entry of each day carries its heading, so the list
            // reads as days rather than as a stack of rows
            const day = _dayKey(entry.ts || 0);
            const row = Object.assign({}, entry);
            row.dayLabel = day !== lastDay ? _dayLabel(entry.ts || 0) : "";
            lastDay = day;
            result.push(row);
        }
        return result;
    }

    // What this machine has been through lately: the log already knows, it
    // just never said it out loud.
    readonly property var activity: {
        const all = (logger ? logger.entries : []) || [];
        const cutoff = Date.now() / 1000 - 7 * 86400;
        let updated = 0;
        let installed = 0;
        let removed = 0;
        let runs = 0;
        for (const entry of all) {
            if ((entry.ts || 0) < cutoff)
                continue;
            const type = entry.type || "";
            if (type.indexOf("update") === 0) {
                runs++;
                for (const item of entry.items || []) {
                    if (item.status !== "error")
                        updated++;
                }
            } else if (type === "install") {
                installed += (entry.items || []).length;
            } else if (type === "uninstall") {
                removed += (entry.items || []).length;
            }
        }
        return {
            updated: updated,
            installed: installed,
            removed: removed,
            runs: runs
        };
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

        // ── The last seven days at a glance ─────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: view.searchText === "" && (view.activity.updated + view.activity.installed + view.activity.removed) > 0
            implicitHeight: activityRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.45)

            RowLayout {
                id: activityRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingL

                StyledText {
                    text: Tr.t("Last 7 days")
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.DemiBold
                    color: Theme.surfaceVariantText
                }

                Repeater {
                    model: [
                        {
                            value: view.activity.updated,
                            label: Tr.t("updated"),
                            colour: Theme.primary
                        },
                        {
                            value: view.activity.installed,
                            label: Tr.t("installed"),
                            colour: Theme.success
                        },
                        {
                            value: view.activity.removed,
                            label: Tr.t("removed"),
                            colour: Theme.surfaceVariantText
                        }
                    ]

                    delegate: RowLayout {
                        required property var modelData

                        visible: modelData.value > 0
                        spacing: 4

                        StyledText {
                            text: String(modelData.value)
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                            color: modelData.colour
                        }

                        StyledText {
                            text: modelData.label
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                Item {
                    Layout.fillWidth: true
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

            // A day heading, then the entry on a rail: the log holds a
            // sequence of events, and a stack of identical cards hides that.
            delegate: Column {
                id: entryWrap

                required property var modelData

                width: logList.width
                spacing: Theme.spacingXS

                Item {
                    width: parent.width
                    visible: (entryWrap.modelData.dayLabel || "") !== ""
                    height: visible ? dayHeading.implicitHeight + Theme.spacingS : 0

                    StyledText {
                        id: dayHeading
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: Theme.spacingXS
                        text: entryWrap.modelData.dayLabel || ""
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.surfaceVariantText
                    }
                }

                Item {
                    width: parent.width
                    implicitHeight: entryRow.implicitHeight

                    // The rail runs through the gap to the next entry too, so
                    // the days read as one thread rather than as loose cards
                    Rectangle {
                        x: 5
                        y: 0
                        width: 2
                        height: parent.height + Theme.spacingXS
                        color: Theme.withAlpha(Theme.outline, 0.35)
                    }

                    Rectangle {
                        x: 2
                        y: Theme.spacingM
                        width: 8
                        height: 8
                        radius: 4
                        color: view.colorFor(entryWrap.modelData.type || "")
                    }

                Rectangle {
                    id: entryRow

                    readonly property var modelData: entryWrap.modelData
                    readonly property string entryKey: String(modelData.ts) + "/" + (modelData.type || "")
                    readonly property bool expanded: view.expandedKeys[entryKey] === true
                    readonly property var entryItems: modelData.items || []

                    x: 18
                    width: parent.width - 18
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
