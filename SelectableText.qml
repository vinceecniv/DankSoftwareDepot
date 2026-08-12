import QtQuick
import qs.Common

// StyledText that can be selected and copied.
//
// Qt's Text element cannot be selected at all — not a styling choice, the
// element has no selection to offer — and DMS's StyledText is a Text. The
// element that can is TextEdit, so this is one in read-only clothing, wearing
// the same font, size, weight and colour so a block does not announce itself
// as a different kind of thing by being copyable.
//
// This is deliberately not what every label in the plugin is made of. A
// TextEdit takes the mouse, so a card whose title was selectable would stop
// being a card you can click, and rows here expand, open and toggle on exactly
// that click. It is for the blocks worth copying out of the app: release
// notes and their CVE numbers, the verbatim output behind a failure, a
// changelog, an announcement, a description.
TextEdit {
    id: root

    readOnly: true
    selectByMouse: true
    selectByKeyboard: true
    // Losing the selection the moment focus moves is what a label would do;
    // keeping it is what a document does, and this is closer to a document
    persistentSelection: true

    color: Theme.surfaceText
    font.family: Theme.fontFamily
    font.pixelSize: Theme.fontSizeSmall
    font.weight: Theme.fontWeight
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap

    // Ctrl+C is the point of the exercise; without this the shortcut belongs
    // to whatever is listening further up
    Keys.onPressed: event => {
        if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier)) {
            root.copy();
            event.accepted = true;
        } else if (event.key === Qt.Key_A && (event.modifiers & Qt.ControlModifier)) {
            root.selectAll();
            event.accepted = true;
        } else if (event.key === Qt.Key_Escape) {
            // These live inside dialogs that close on Escape. Having clicked
            // into a line of text is not a reason for that to stop working,
            // so the selection goes and the key carries on upward.
            root.deselect();
            event.accepted = false;
        }
    }

    // A text cursor over selectable text, so it is discoverable without
    // anyone having to try dragging over a label first
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.NoButton
        cursorShape: Qt.IBeamCursor
    }
}
