import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

// Keyboard-first overlay: one field that searches everything the window
// already knows — pending updates, installed software, the action log and the
// app's own commands — and hands off to the Install tab for anything that
// would need a repository search.
//
// The results are a fixed pool of hand-placed slots rather than a list with a
// delegate. Generated rows in this window never receive mouse events, proven
// by bisection against an identical hand-placed row; a palette shows a
// bounded number of results anyway, so the pool costs nothing.
Item {
    id: palette

    // [{group, icon, title, subtitle, colour}] — order decides grouping,
    // entries of the same group must be adjacent
    property var results: []
    property string query: ""
    property int current: 0
    readonly property int maxRows: 12

    signal accepted(int index)
    signal dismissed

    visible: false

    function open() {
        query = "";
        current = 0;
        visible = true;
        field.text = "";
        field.forceActiveFocus();
    }

    function close() {
        visible = false;
        dismissed();
    }

    function _shown() {
        return Math.min(results.length, maxRows);
    }

    function _move(delta) {
        const count = _shown();
        if (count === 0)
            return;
        current = (current + delta + count) % count;
    }

    onResultsChanged: {
        if (current >= _shown())
            current = Math.max(0, _shown() - 1);
    }

    // Navigation goes through the text field's own hooks. A TextInput claims
    // Up, Down and Return — via ShortcutOverride, precisely so shortcuts
    // cannot hijack typing — so neither an ancestor's Keys handler nor a
    // Shortcut ever sees them.
    Item {
        id: keyRelay

        Keys.onPressed: event => {
            switch (event.key) {
            case Qt.Key_Down:
                palette._move(1);
                event.accepted = true;
                break;
            case Qt.Key_Up:
                palette._move(-1);
                event.accepted = true;
                break;
            case Qt.Key_Escape:
                palette.close();
                event.accepted = true;
                break;
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)

        MouseArea {
            anchors.fill: parent
            onClicked: palette.close()
            onWheel: wheel => wheel.accepted = true
        }
    }

    Rectangle {
        id: sheet

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Math.round(parent.height * 0.12)
        width: Math.min(parent.width - Theme.spacingXL * 2, 620)
        height: header.height + resultColumn.height + emptyLabel.height + Theme.spacingM * 2 + Theme.spacingS
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        border.width: 1
        border.color: Theme.withAlpha(Theme.outline, 0.2)

        // A tap handler rather than a filling MouseArea: it keeps a click on
        // the sheet's own background from reaching the dismiss scrim without
        // standing between the rows and the mouse.
        TapHandler {
            gesturePolicy: TapHandler.ReleaseWithinBounds
        }

        DankTextField {
            id: header

            x: Theme.spacingM
            y: Theme.spacingM
            width: sheet.width - Theme.spacingM * 2
            placeholderText: Tr.t("Search everything…")
            leftIconName: "search"
            ignoreUpDownKeys: true
            keyForwardTargets: [keyRelay]
            // The palette's field is the only thing on a large empty sheet;
            // the default tones are pitched for a field among other content
            // and read as barely there here
            placeholderColor: Theme.surfaceVariantText
            normalBorderColor: Theme.withAlpha(Theme.outline, 0.45)
            onTextChanged: {
                palette.query = text;
                // A fresh query preselects its first result, so Enter always
                // means "the obvious one"
                palette.current = 0;
            }
            onAccepted: {
                if (palette.results.length > 0)
                    palette.accepted(palette.current);
            }
        }

        Column {
            id: resultColumn

            x: Theme.spacingM
            width: sheet.width - Theme.spacingM * 2
            anchors.top: header.bottom
            anchors.topMargin: Theme.spacingS
            spacing: 1

                PaletteRow {
                    width: resultColumn.width
                    index: 0
                    entry: 0 < palette.results.length ? palette.results[0] : null
                    selected: palette.current === 0
                    showGroup: entry !== null && (0 === 0 || palette.results[0 - 1].group !== entry.group)
                    onHovered: palette.current = 0
                    onActivated: palette.accepted(0)
                }

                PaletteRow {
                    width: resultColumn.width
                    index: 1
                    entry: 1 < palette.results.length ? palette.results[1] : null
                    selected: palette.current === 1
                    showGroup: entry !== null && (1 === 0 || palette.results[1 - 1].group !== entry.group)
                    onHovered: palette.current = 1
                    onActivated: palette.accepted(1)
                }

                PaletteRow {
                    width: resultColumn.width
                    index: 2
                    entry: 2 < palette.results.length ? palette.results[2] : null
                    selected: palette.current === 2
                    showGroup: entry !== null && (2 === 0 || palette.results[2 - 1].group !== entry.group)
                    onHovered: palette.current = 2
                    onActivated: palette.accepted(2)
                }

                PaletteRow {
                    width: resultColumn.width
                    index: 3
                    entry: 3 < palette.results.length ? palette.results[3] : null
                    selected: palette.current === 3
                    showGroup: entry !== null && (3 === 0 || palette.results[3 - 1].group !== entry.group)
                    onHovered: palette.current = 3
                    onActivated: palette.accepted(3)
                }

                PaletteRow {
                    width: resultColumn.width
                    index: 4
                    entry: 4 < palette.results.length ? palette.results[4] : null
                    selected: palette.current === 4
                    showGroup: entry !== null && (4 === 0 || palette.results[4 - 1].group !== entry.group)
                    onHovered: palette.current = 4
                    onActivated: palette.accepted(4)
                }

                PaletteRow {
                    width: resultColumn.width
                    index: 5
                    entry: 5 < palette.results.length ? palette.results[5] : null
                    selected: palette.current === 5
                    showGroup: entry !== null && (5 === 0 || palette.results[5 - 1].group !== entry.group)
                    onHovered: palette.current = 5
                    onActivated: palette.accepted(5)
                }

                PaletteRow {
                    width: resultColumn.width
                    index: 6
                    entry: 6 < palette.results.length ? palette.results[6] : null
                    selected: palette.current === 6
                    showGroup: entry !== null && (6 === 0 || palette.results[6 - 1].group !== entry.group)
                    onHovered: palette.current = 6
                    onActivated: palette.accepted(6)
                }

                PaletteRow {
                    width: resultColumn.width
                    index: 7
                    entry: 7 < palette.results.length ? palette.results[7] : null
                    selected: palette.current === 7
                    showGroup: entry !== null && (7 === 0 || palette.results[7 - 1].group !== entry.group)
                    onHovered: palette.current = 7
                    onActivated: palette.accepted(7)
                }

                PaletteRow {
                    width: resultColumn.width
                    index: 8
                    entry: 8 < palette.results.length ? palette.results[8] : null
                    selected: palette.current === 8
                    showGroup: entry !== null && (8 === 0 || palette.results[8 - 1].group !== entry.group)
                    onHovered: palette.current = 8
                    onActivated: palette.accepted(8)
                }

                PaletteRow {
                    width: resultColumn.width
                    index: 9
                    entry: 9 < palette.results.length ? palette.results[9] : null
                    selected: palette.current === 9
                    showGroup: entry !== null && (9 === 0 || palette.results[9 - 1].group !== entry.group)
                    onHovered: palette.current = 9
                    onActivated: palette.accepted(9)
                }

                PaletteRow {
                    width: resultColumn.width
                    index: 10
                    entry: 10 < palette.results.length ? palette.results[10] : null
                    selected: palette.current === 10
                    showGroup: entry !== null && (10 === 0 || palette.results[10 - 1].group !== entry.group)
                    onHovered: palette.current = 10
                    onActivated: palette.accepted(10)
                }

                PaletteRow {
                    width: resultColumn.width
                    index: 11
                    entry: 11 < palette.results.length ? palette.results[11] : null
                    selected: palette.current === 11
                    showGroup: entry !== null && (11 === 0 || palette.results[11 - 1].group !== entry.group)
                    onHovered: palette.current = 11
                    onActivated: palette.accepted(11)
                }
        }

        StyledText {
            id: emptyLabel

            x: Theme.spacingM
            width: sheet.width - Theme.spacingM * 2
            anchors.top: resultColumn.bottom
            height: visible ? implicitHeight + Theme.spacingS : 0
            visible: palette.results.length === 0
            horizontalAlignment: Text.AlignHCenter
            text: palette.query === "" ? Tr.t("Type to search updates, installed software, the log and commands") : Tr.t("Nothing matches \"%1\"").arg(palette.query)
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }
    }
}
