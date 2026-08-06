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

    // Three individual dots; each runs the same brightness cycle with a
    // staggered start, so a wave slides across them left to right.
    Row {
        id: dots

        visible: root._dots
        spacing: 0

        Repeater {
            model: 3

            StyledText {
                id: dot

                required property int index

                text: "."
                color: root.color
                font.pixelSize: root.pixelSize
                font.weight: root.weight
                opacity: 0.25

                SequentialAnimation {
                    running: dots.visible
                    loops: Animation.Infinite

                    PauseAnimation {
                        duration: dot.index * 220
                    }

                    NumberAnimation {
                        target: dot
                        property: "opacity"
                        to: 1
                        duration: 260
                        easing.type: Easing.InOutSine
                    }

                    NumberAnimation {
                        target: dot
                        property: "opacity"
                        to: 0.25
                        duration: 420
                        easing.type: Easing.InOutSine
                    }

                    PauseAnimation {
                        duration: 660 - dot.index * 220
                    }
                }
            }
        }
    }
}
