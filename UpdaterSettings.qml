import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    pluginId: "dankSoftwareDepot"

    ToggleSetting { id: s_hide; settingKey: "hideWhenUpToDate"; defaultValue: false; visible: false; height: 0 }
    ToggleSetting { id: s_runtimes; settingKey: "showRuntimes"; defaultValue: true; visible: false; height: 0 }
    ToggleSetting { id: s_firmware; settingKey: "includeFirmware"; defaultValue: true; visible: false; height: 0 }
    ToggleSetting { id: s_confirm; settingKey: "confirmBeforeUpdate"; defaultValue: false; visible: false; height: 0 }
    ToggleSetting { id: s_tint; settingKey: "tintAppIcons"; defaultValue: true; visible: false; height: 0 }
    ToggleSetting { id: s_pill; settingKey: "pillOpensWindow"; defaultValue: false; visible: false; height: 0 }
    SelectionSetting { id: s_auto; settingKey: "autoUpdateMode"; defaultValue: "notify"; visible: false; height: 0; options: [{label:"", value:""}] }

    // ── About & Plugin Info Card ───────────────────────────
    StyledRect {
        width: parent.width
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.65)
        border.width: 1
        border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.15)
        implicitHeight: aboutCol.implicitHeight + Theme.spacingM * 2

        ColumnLayout {
            id: aboutCol
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingM

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingM

                Rectangle {
                    Layout.preferredWidth: 44
                    Layout.preferredHeight: 44
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.primary, 0.10)
                    border.width: 1
                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18)

                    Image {
                        anchors.fill: parent
                        anchors.margins: 4
                        source: "icons/dankSoftwareDepot.svg"
                        sourceSize.width: 80
                        sourceSize.height: 80
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2

                    StyledText {
                        text: "Dank Software Depot"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }

                    StyledText {
                        text: Tr.t("Visual updater and software hub for DMS")
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }
                }
            }

            StyledText {
                Layout.fillWidth: true
                text: Tr.t("Visual updater built on the DMS system update service. Check interval and ignored packages are managed in Settings → System Updater.")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            Rectangle {
                id: openAppBtn
                Layout.preferredHeight: 34
                Layout.preferredWidth: openRow.implicitWidth + 24
                property bool isHovered: openMa.containsMouse

                radius: isHovered ? (height / 2) : Theme.cornerRadius
                Behavior on radius { NumberAnimation { duration: 350; easing.type: Easing.OutExpo } }

                color: isHovered ? Theme.withAlpha(Theme.primary, 0.25) : Theme.withAlpha(Theme.primary, 0.15)
                Behavior on color { ColorAnimation { duration: 150 } }
                border.width: 1
                border.color: isHovered ? Theme.primary : Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.3)
                Behavior on border.color { ColorAnimation { duration: 150 } }

                scale: openMa.pressed ? 0.94 : (isHovered ? 1.02 : 1.0)
                Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutBack } }

                DankRipple {
                    id: openRip
                    anchors.fill: parent
                    cornerRadius: parent.radius
                    rippleColor: Theme.primary
                }

                RowLayout {
                    id: openRow
                    anchors.centerIn: parent
                    spacing: 6

                    DankIcon {
                        name: "open_in_new"
                        size: 16
                        color: Theme.primary
                    }

                    StyledText {
                        text: Tr.t("Open Dank Software Depot")
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.primary
                    }
                }

                MouseArea {
                    id: openMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPressed: (m) => openRip.trigger(m.x, m.y)
                    onClicked: Quickshell.execDetached(["sh", Qt.resolvedUrl("scripts/open.sh").toString().replace("file://", "")])
                }
            }
        }
    }

    Column {
                                id: prefColumn
                                width: parent.width
                                spacing: 2
    
                                // 1. Hide when up to date (First)
                                Rectangle {
                                    width: parent.width
                                    height: row1.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: true
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)
                                    border.width: 1
                                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.10)
    
                                    RowLayout {
                                        id: row1
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DankIcon {
                                            name: "visibility_off"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Hide when up to date")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Hide the bar pill while there are no pending updates.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DankToggle {
                                            id: t1
                                            hideText: true
                                            checked: s_hide.value === true
                                            onToggled: checked => s_hide.value = checked
                                        }
                                    }
                                }
    
                                // 2. Show runtimes and extensions (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row2.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)
                                    border.width: 1
                                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.10)
    
                                    RowLayout {
                                        id: row2
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DankIcon {
                                            name: "extension"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Show runtimes and extensions")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("List Flatpak runtimes, locales and codec extensions. They are always included in Update All.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DankToggle {
                                            id: t2
                                            hideText: true
                                            checked: s_runtimes.value === true
                                            onToggled: checked => s_runtimes.value = checked
                                        }
                                    }
                                }
    
                                // 3. Include firmware updates (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row3.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)
                                    border.width: 1
                                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.10)
    
                                    RowLayout {
                                        id: row3
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DankIcon {
                                            name: "memory"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Include firmware updates")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Check for device firmware updates via fwupd (LVFS) and include them in Update All.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DankToggle {
                                            id: t3
                                            hideText: true
                                            checked: s_firmware.value === true
                                            onToggled: checked => s_firmware.value = checked
                                        }
                                    }
                                }
    
                                // 4. Confirm before updating (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row4.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)
                                    border.width: 1
                                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.10)
    
                                    RowLayout {
                                        id: row4
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DankIcon {
                                            name: "check_circle"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Confirm before updating")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Require a second click on Update All before the run starts.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DankToggle {
                                            id: t4
                                            hideText: true
                                            checked: s_confirm.value === true
                                            onToggled: checked => s_confirm.value = checked
                                        }
                                    }
                                }
    
                                // 5. Authorise with sudo (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row5.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)
                                    border.width: 1
                                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.10)
    
                                    RowLayout {
                                        id: row5
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DankIcon {
                                            name: "admin_panel_settings"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Authorise with sudo")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Run privileged commands through sudo instead of asking polkit, for systems where sudo has been configured to need no password. Falls back to the usual prompt whenever sudo would ask for one.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DankToggle {
                                            id: t5
                                            hideText: true
                                            checked: Backend.useSudo
                                            onToggled: checked => PluginService.savePluginData("dankSoftwareDepot", "useSudo", checked)
                                        }
                                    }
                                }
    
                                // 6. Tint app icons with the theme colour (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row6.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)
                                    border.width: 1
                                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.10)
    
                                    RowLayout {
                                        id: row6
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DankIcon {
                                            name: "palette"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Tint app icons with the theme colour")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Draw app icons in greyscale and colour them with the active DMS accent, instead of showing each app's own colours.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DankToggle {
                                            id: t6
                                            hideText: true
                                            checked: s_tint.value === true
                                            onToggled: checked => s_tint.value = checked
                                        }
                                    }
                                }
    
                                // 7. Show in app launcher (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row7.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)
                                    border.width: 1
                                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.10)
    
                                    RowLayout {
                                        id: row7
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DankIcon {
                                            name: "apps"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Show in app launcher")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Place a desktop entry so this window can be opened from the application launcher, like a standalone app.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DankToggle {
                                            id: t7
                                            hideText: true
                                            checked: Backend.launcherEntryPresent
                                            enabled: Backend.launcherEntryChecked && !Backend.launcherEntryBusy
                                            onToggled: checked => {
                                                if (checked)
                                                    Backend.installLauncherEntry();
                                                else
                                                    Backend.removeLauncherEntry();
                                                PluginService.savePluginData("dankSoftwareDepot", "launcherPromptDone", true);
                                            }
                                        }
                                    }
                                }
    
                                // 8. Open .appimage files with this app (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row8.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)
                                    border.width: 1
                                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.10)
    
                                    RowLayout {
                                        id: row8
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DankIcon {
                                            name: "insert_drive_file"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Open .appimage files with this app")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Double-clicking an AppImage opens this window, which offers to install it — or to replace the copy you already have. Adds the launcher entry if it is not there yet.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DankToggle {
                                            id: t8
                                            hideText: true
                                            checked: Backend.appimageHandlerDefault
                                            enabled: Backend.appimageHandlerChecked && !Backend.appimageHandlerBusy && !Backend.launcherEntryBusy
                                            onToggled: checked => {
                                                if (checked)
                                                    Backend.setAppimageHandler();
                                                else
                                                    Backend.clearAppimageHandler();
                                            }
                                        }
                                    }
                                }
    
                                // 9. Bar click opens window (Middle)
                                Rectangle {
                                    width: parent.width
                                    height: row9.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: false
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)
                                    border.width: 1
                                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.10)
    
                                    RowLayout {
                                        id: row9
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingM
    
                                        DankIcon {
                                            name: "open_in_browser"
                                            size: 20
                                            color: Theme.primary
                                        }
    
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
    
                                            StyledText {
                                                text: Tr.t("Bar click opens window")
                                                font.pixelSize: Theme.fontSizeMedium
                                                font.weight: Font.Medium
                                                color: Theme.surfaceText
                                            }
    
                                            StyledText {
                                                Layout.fillWidth: true
                                                text: Tr.t("Open this window instead of the compact popout when clicking the bar pill.")
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceVariantText
                                                wrapMode: Text.WordWrap
                                            }
                                        }
    
                                        DankToggle {
                                            id: t9
                                            hideText: true
                                            checked: s_pill.value === true
                                            onToggled: checked => s_pill.value = checked
                                        }
                                    }
                                }
    
                                // 10. Automatic updates (Last - Stacked layout)
                                Rectangle {
                                    width: parent.width
                                    height: autoCol.implicitHeight + Theme.spacingM * 2
                                    readonly property bool isFirst: false
                                    readonly property bool isLast: true
                                    readonly property real outerR: Theme.cornerRadius
                                    readonly property real innerR: 4
    
                                    topLeftRadius: isFirst ? outerR : innerR
                                    topRightRadius: isFirst ? outerR : innerR
                                    bottomLeftRadius: isLast ? outerR : innerR
                                    bottomRightRadius: isLast ? outerR : innerR
    
                                    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)
                                    border.width: 1
                                    border.color: Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.10)
    
                                    ColumnLayout {
                                        id: autoCol
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter
                                        anchors.leftMargin: Theme.spacingM
                                        anchors.rightMargin: Theme.spacingM
                                        spacing: Theme.spacingS
    
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: Theme.spacingM
    
                                            DankIcon {
                                                name: "sync"
                                                size: 20
                                                color: Theme.primary
                                            }
    
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 2
    
                                                StyledText {
                                                    text: Tr.t("Automatic updates")
                                                    font.pixelSize: Theme.fontSizeMedium
                                                    font.weight: Font.Medium
                                                    color: Theme.surfaceText
                                                }
    
                                                StyledText {
                                                    Layout.fillWidth: true
                                                    text: Tr.t("Notify when updates are found, and optionally install Flatpak updates automatically. System packages always ask first.")
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: Theme.surfaceVariantText
                                                    wrapMode: Text.WordWrap
                                                }
                                            }
                                        }
    
                                        DankDropdown {
                                            id: t10
                                            readonly property var autoMap: ({
                                                    "Off": "off",
                                                    "Notify only": "notify",
                                                    "Auto-install Flatpaks": "auto"
                                                })
    
                                            Layout.fillWidth: true
                                            compactMode: true
                                            dropdownWidth: parent.width
                                            options: Object.keys(autoMap).map(k => Tr.t(k))
                                            currentValue: {
                                                const mode = s_auto.value;
                                                for (const label in autoMap) {
                                                    if (autoMap[label] === mode)
                                                        return Tr.t(label);
                                                }
                                                return Tr.t("Off");
                                            }
                                            onValueChanged: value => {
                                                for (const label in autoMap) {
                                                    if (Tr.t(label) === value) {
                                                        s_auto.value = autoMap[label];
                                                        return;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
            }

