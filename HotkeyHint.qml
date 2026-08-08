import QtQuick
import qs.Common
import qs.Widgets

// A quiet key chip that sits at the right of a search field while that field
// is empty. Someone typing into one tab's search is exactly the person who
// might want to search everything at once — and an empty field is exactly
// when the clear button is not there to collide with.
Rectangle {
    id: hint

    property string label: "Ctrl+K"

    signal activated

    implicitWidth: hintText.implicitWidth + 12
    implicitHeight: 18
    radius: 4
    color: hintArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.16) : Theme.withAlpha(Theme.surfaceVariantText, 0.10)

    Behavior on color {
        ColorAnimation {
            duration: Theme.shortDuration
        }
    }

    StyledText {
        id: hintText
        anchors.centerIn: parent
        text: hint.label
        font.pixelSize: Theme.fontSizeSmall - 3
        font.weight: Font.Medium
        color: hintArea.containsMouse ? Theme.primary : Theme.surfaceVariantText
    }

    MouseArea {
        id: hintArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: hint.activated()
    }
}
