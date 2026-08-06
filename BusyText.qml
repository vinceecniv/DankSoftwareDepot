import QtQuick
import qs.Common
import qs.Widgets

// StyledText drop-in for waiting states: when the text ends in "…" the
// ellipsis pulses smoothly to transparent and back — a quiet busy signal
// that never changes the text width. Texts without a trailing ellipsis
// render as plain static labels.
Row {
    id: root

    property string text: ""
    property color color: Theme.surfaceText
    property int pixelSize: Theme.fontSizeMedium
    property int weight: Font.Normal

    readonly property bool _dots: text.length > 0 && text[text.length - 1] === "…"

    spacing: 0

    StyledText {
        id: body

        text: root._dots ? root.text.slice(0, -1) : root.text
        color: root.color
        font.pixelSize: root.pixelSize
        font.weight: root.weight
    }

    StyledText {
        id: dots

        visible: root._dots
        text: "…"
        color: root.color
        font.pixelSize: root.pixelSize
        font.weight: root.weight

        SequentialAnimation on opacity {
            running: dots.visible
            loops: Animation.Infinite

            NumberAnimation {
                from: 1
                to: 0.1
                duration: 700
                easing.type: Easing.InOutSine
            }

            NumberAnimation {
                from: 0.1
                to: 1
                duration: 700
                easing.type: Easing.InOutSine
            }
        }
    }
}
