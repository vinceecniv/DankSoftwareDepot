import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

// One result slot. Placed by hand rather than generated, because generated
// delegates in this window never receive the mouse — measured across a
// ListView, a plain ListView and a Repeater, while an identical hand-placed
// row worked every time. A palette shows a bounded number of results, so a
// fixed pool of slots costs nothing and sidesteps the question entirely.
Item {
    id: slot

    // Index into the palette's results; the row shows itself only when the
    // list actually reaches this far
    property int index: 0
    property var entry: null
    property bool selected: false

    signal activated
    signal hovered

    readonly property string group: entry ? (entry.group || "") : ""
    // A heading appears where the group changes, so the list reads as
    // sections without becoming separate lists
    property bool showGroup: false

    visible: entry !== null
    height: visible ? (showGroup ? 20 : 0) + 40 : 0

    StyledText {
        id: groupLabel

        anchors.left: parent.left
        anchors.top: parent.top
        anchors.leftMargin: Theme.spacingXS
        height: 20
        verticalAlignment: Text.AlignVCenter
        visible: slot.showGroup
        text: slot.group
        font.pixelSize: Theme.fontSizeSmall - 2
        font.weight: Font.DemiBold
        color: Theme.surfaceVariantText
    }

    Rectangle {
        id: body

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 40
        radius: Theme.cornerRadius / 2
        color: slot.selected ? Theme.withAlpha(Theme.primary, 0.28) : (rowArea.containsMouse ? Theme.withAlpha(Theme.surfaceVariantText, 0.10) : "transparent")

        Behavior on color {
            ColorAnimation {
                duration: Theme.shortDuration
            }
        }

        RowLayout {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.spacingS
            anchors.rightMargin: Theme.spacingS
            spacing: Theme.spacingS

            DankIcon {
                name: slot.entry ? (slot.entry.icon || "chevron_right") : "chevron_right"
                size: 16
                color: slot.entry && slot.entry.colour ? slot.entry.colour : Theme.surfaceVariantText
            }

            StyledText {
                text: slot.entry ? (slot.entry.title || "") : ""
                font.pixelSize: Theme.fontSizeSmall
                font.weight: slot.selected ? Font.DemiBold : Font.Normal
                color: slot.selected ? Theme.primary : Theme.surfaceText
                elide: Text.ElideRight
                Layout.maximumWidth: 300
            }

            StyledText {
                Layout.fillWidth: true
                text: slot.entry ? (slot.entry.subtitle || "") : ""
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
            }
        }

        MouseArea {
            id: rowArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            // Movement, not entry: a row that appears under a resting pointer
            // fires `entered` without the mouse having done anything, which
            // would hand the selection to wherever the cursor happened to be
            onPositionChanged: slot.hovered()
            onClicked: slot.activated()
        }
    }
}
