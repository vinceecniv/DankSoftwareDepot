import QtQuick
import qs.Common

// The heading of the section you are currently inside, held at the top of a
// list while its rows scroll past.
//
// Every list in this window groups its rows and puts a heading above each
// group, and every one of them loses that heading the moment you scroll into
// the group: sixteen system packages, four hundred apps in a storefront
// category, a day's worth of log entries. It matters more here than it used
// to, because the rows under a heading no longer repeat what it says.
//
// None of these lists use ListView's own sections — their models are flat
// arrays where a row either *is* a heading (Updates, Install) or *carries*
// one (Installed, Log) — so this is the heading drawn a second time, pinned,
// over the copy scrolling underneath it. Which is why it stays hidden until
// that copy has actually left the top of the view: two of them at once is
// worse than none at all.
//
// Used by giving it the view, its model, a way to recognise a heading and
// something to draw:
//
//     StickyHeader {
//         view: logList
//         rows: view.visibleEntries
//         headingOf: row => row.dayLabel || ""
//         barHeight: 26
//         content: Component { StyledText { text: sticky.heading } }
//     }
//
// `headingOf` returns "" for a row that starts no group; anything else is
// handed to the delegate as `heading`, so a list whose headings are more than
// a word can pass the whole row.
Loader {
    id: sticky

    property Item view: null
    property var rows: []
    property var headingOf: row => (row && row.sectionLabel) || ""
    property real barHeight: 32
    property Component content: null

    // The heading governing whatever is at the top of the viewport. Walking
    // backwards from the first visible row rather than tracking it forwards:
    // a list can be jumped to any position, and the row you land on has to be
    // able to answer which group it is in on its own.
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

    // A delegate that was never created is far enough off screen to count as
    // scrolled past; one that exists is compared against the top edge.
    readonly property bool needed: {
        if (headingIndex < 0 || view === null)
            return false;
        const own = view.itemAtIndex(headingIndex);
        return !own || own.y < view.contentY - 0.5;
    }

    // The next heading pushes this one out of the way rather than replacing
    // it underneath itself. That movement is what makes a pinned heading read
    // as part of the list instead of a lid on top of it.
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

    // Out of the flickable's content item and onto the view itself, so it
    // holds still while the rows go past. Done once the object exists rather
    // than as a binding on `parent`: anything declared inside a flickable is
    // appended to its content item *after* its own properties are applied, so
    // a parent set there is overwritten a moment later.
    Component.onCompleted: parent = view

    x: 0
    y: offset
    z: 3
    width: view ? view.width : 0
    height: barHeight
    active: needed && content !== null
    visible: active

    sourceComponent: Component {
        Item {
            Rectangle {
                anchors.fill: parent
                // The rows scroll underneath it, so it needs the window's own
                // surface behind it — which a heading sitting in the list can
                // do without.
                color: Theme.floatingWindowSurface !== undefined ? Theme.floatingWindowSurface : Theme.surfaceContainer
            }

            Loader {
                anchors.fill: parent
                sourceComponent: sticky.content
            }
        }
    }
}
