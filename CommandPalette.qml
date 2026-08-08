import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

// Keyboard-first overlay: one field that searches everything the window
// already knows — pending updates, installed software, the action log and the
// app's own commands — and hands off to the Install tab for anything that
// would need a repository search.
//
// Deliberately dumb: the host computes `results` from `query` and performs
// whatever an entry means. This only renders and navigates, so the palette
// never has to learn about packages.
Item {
    id: palette

    // [{group, icon, title, subtitle, colour}] — order decides grouping,
    // entries of the same group must be adjacent
    property var results: []
    property string query: ""
    property int current: 0

    signal accepted(int index)
    signal dismissed

    visible: false
    focus: visible

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

    function _move(delta) {
        if (results.length === 0)
            return;
        current = (current + delta + results.length) % results.length;
        list.positionViewAtIndex(current, ListView.Contain);
    }

    onResultsChanged: {
        if (current >= results.length)
            current = Math.max(0, results.length - 1);
    }

    // Click anywhere outside to dismiss; the scrim also swallows clicks that
    // would otherwise land on the window behind it
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
        height: Math.min(paletteColumn.implicitHeight + Theme.spacingM * 2, parent.height * 0.7)
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        border.width: 1
        border.color: Theme.withAlpha(Theme.outline, 0.2)

        // Swallow clicks so they do not reach the dismiss scrim underneath
        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            id: paletteColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingS

            DankTextField {
                id: field
                Layout.fillWidth: true
                placeholderText: Tr.t("Search everything…")
                leftIconName: "search"
                onTextChanged: {
                    palette.query = text;
                    palette.current = 0;
                }

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
                    case Qt.Key_Return:
                    case Qt.Key_Enter:
                        if (palette.results.length > 0)
                            palette.accepted(palette.current);
                        event.accepted = true;
                        break;
                    case Qt.Key_Escape:
                        palette.close();
                        event.accepted = true;
                        break;
                    }
                }
            }

            DankListView {
                id: list
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredHeight: Math.min(contentHeight, 380)
                clip: true
                spacing: 1
                model: palette.results
                visible: palette.results.length > 0

                delegate: Rectangle {
                    id: row

                    required property var modelData
                    required property int index

                    // A group heading appears where the group changes, so the
                    // list stays one keyboard sequence rather than sections
                    readonly property bool startsGroup: index === 0 || palette.results[index - 1].group !== modelData.group

                    width: list.width
                    height: (startsGroup ? 20 : 0) + 40
                    color: "transparent"

                    StyledText {
                        visible: row.startsGroup
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.leftMargin: Theme.spacingXS
                        height: 20
                        verticalAlignment: Text.AlignVCenter
                        text: row.modelData.group
                        font.pixelSize: Theme.fontSizeSmall - 2
                        font.weight: Font.DemiBold
                        color: Theme.surfaceVariantText
                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 40
                        radius: Theme.cornerRadius / 2
                        color: palette.current === row.index ? Theme.withAlpha(Theme.primary, 0.14) : (rowHover.hovered ? Theme.withAlpha(Theme.surfaceVariantText, 0.08) : "transparent")

                        HoverHandler {
                            id: rowHover
                            onHoveredChanged: {
                                if (hovered)
                                    palette.current = row.index;
                            }
                        }

                        TapHandler {
                            onTapped: palette.accepted(row.index)
                        }

                        RowLayout {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Theme.spacingS
                            anchors.rightMargin: Theme.spacingS
                            spacing: Theme.spacingS

                            DankIcon {
                                name: row.modelData.icon || "chevron_right"
                                size: 16
                                color: row.modelData.colour || Theme.surfaceVariantText
                            }

                            StyledText {
                                text: row.modelData.title || ""
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                                Layout.maximumWidth: 300
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: row.modelData.subtitle || ""
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }

            StyledText {
                Layout.fillWidth: true
                Layout.topMargin: Theme.spacingS
                Layout.bottomMargin: Theme.spacingS
                visible: palette.results.length === 0
                horizontalAlignment: Text.AlignHCenter
                text: palette.query === "" ? Tr.t("Type to search updates, installed software, the log and commands") : Tr.t("Nothing matches \"%1\"").arg(palette.query)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }
        }
    }
}
