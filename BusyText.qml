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

    // Three individual dots with a phase-shifted brightness wave sliding
    // across them left to right.
    Row {
        id: dots

        visible: root._dots
        spacing: 0

        property real phase: 0

        NumberAnimation on phase {
            running: dots.visible
            loops: Animation.Infinite
            from: 0
            to: 2 * Math.PI
            duration: 1500
        }

        Repeater {
            model: 3

            StyledText {
                required property int index

                text: "."
                color: root.color
                font.pixelSize: root.pixelSize
                font.weight: root.weight
                opacity: 0.25 + 0.75 * Math.max(0, Math.sin(dots.phase - index * 1.1))
            }
        }
    }
}
