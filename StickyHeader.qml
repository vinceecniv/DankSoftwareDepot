import QtQuick
import qs.Common

Loader {
    id: sticky

    property Item view: null
    property var rows: []
    property var headingOf: row => (row && row.sectionLabel) || ""
    property real barHeight: 48
    property Component content: null

    readonly property int headingIndex: {
        if (view === null || rows.length === 0)
            return -1;
        const top = view.indexAt(view.width / 2, view.contentY + 2);
        if (top < 0)
            return -1;
        for (let i = Math.min(top, rows.length - 1); i >= 0; i--) {
            if (headingOf(rows[i]) !== "")
                return i;
        }
        return -1;
    }

    readonly property var heading: headingIndex >= 0 ? headingOf(rows[headingIndex]) : ""

    // In a categorized card layout, each delegate item contains the entire category card.
    // The sticky header should appear as soon as the top of this category card scrolls past the top (own.y < view.contentY).
    readonly property bool needed: {
        if (headingIndex < 0 || view === null)
            return false;
        const own = view.itemAtIndex(headingIndex);
        return !own || own.y < view.contentY - 0.5;
    }

    // When the next category card approaches, it pushes the sticky header up.
    readonly property real offset: {
        if (headingIndex < 0 || view === null)
            return 0;
        for (let i = headingIndex + 1; i < rows.length; i++) {
            if (headingOf(rows[i]) === "")
                continue;
            const item = view.itemAtIndex(i);
            if (!item)
                return 0;
            return Math.min(0, item.y - view.contentY - barHeight);
        }
        return 0;
    }

    // Re-parent out of flickable's contentItem onto view itself so it stays fixed at top
    Component.onCompleted: parent = view

    x: 0
    y: offset
    z: 20
    width: view ? view.width : 0
    height: barHeight
    active: needed && content !== null
    visible: active

    sourceComponent: Component {
        Item {
            // The rows scroll underneath it, so it needs the window's own
            // surface behind it — which a heading sitting in the list can do
            // without. Dropped, it stopped being a lid and became a window:
            // content was visible travelling past through the strip the
            // heading's own card does not cover.
            Rectangle {
                anchors.fill: parent
                color: Theme.floatingWindowSurface !== undefined ? Theme.floatingWindowSurface : Theme.cardSurface
            }

            Loader {
                anchors.fill: parent
                sourceComponent: sticky.content
            }
        }
    }
}
