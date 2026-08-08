pragma Singleton
import QtQuick
import qs.Common

// Small UI helpers shared across the plugin views.
Item {
    id: ui

    // Failure color that stays readable everywhere: some palettes leave
    // Theme.error on the light M3 tone in light mode, which washes out to
    // an unreadable salmon on light surfaces.
    readonly property color failColor: (Theme.isLightMode && Theme.error.hslLightness > 0.55) ? Qt.darker(Theme.error, 1.8) : Theme.error

    // Text color with guaranteed contrast on a colored fill: the theme has
    // no on-error tone, and Theme.primaryText can land on the same side of
    // the lightness scale as Theme.error.
    //
    // Judged on perceived luminance rather than HSL lightness: a saturated
    // purple or red sits high on the lightness scale while still reading as
    // dark, and black text on it is barely legible. 0.179 is where white and
    // black give the same contrast ratio.
    function onColor(bg) {
        const channel = c => c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
        const luminance = 0.2126 * channel(bg.r) + 0.7152 * channel(bg.g) + 0.0722 * channel(bg.b);
        return luminance > 0.179 ? Qt.rgba(0, 0, 0, 0.87) : "#FFFFFF";
    }

    // Linear blend between two colours, for gradients that have to be built
    // out of separate items rather than a single fill.
    function mix(from, to, t) {
        const k = Math.max(0, Math.min(1, t));
        return Qt.rgba(from.r + (to.r - from.r) * k, from.g + (to.g - from.g) * k, from.b + (to.b - from.b) * k, from.a + (to.a - from.a) * k);
    }

    // Search-field caret: hidden while the field is empty (focus is already
    // visible through the field border); once text is entered a normally
    // blinking caret appears. Custom cursorDelegates don't blink by
    // themselves, so the delegate runs its own blink cycle.
    Component {
        id: steadyCursor

        Rectangle {
            width: 2
            color: Theme.primary
            visible: parent !== null && (parent.text || "") !== ""

            SequentialAnimation on opacity {
                running: visible
                loops: Animation.Infinite

                PropertyAction {
                    value: 1
                }

                PauseAnimation {
                    duration: 550
                }

                PropertyAction {
                    value: 0
                }

                PauseAnimation {
                    duration: 550
                }
            }
        }
    }

    // Make a DankListView/DankFlickable scrollbar semi-transparent. The bar
    // is attached as a child of the view; duck-type it and re-bind its
    // handle opacity.
    function softenScrollbar(view) {
        const kids = view.children || [];
        for (let i = 0; i < kids.length; i++) {
            const child = kids[i];
            if (child && child.contentItem !== undefined && child.policy !== undefined && child.minimumSize !== undefined) {
                const bar = child;
                bar.contentItem.opacity = Qt.binding(() => bar.pressed ? 0.85 : 0.5);
                return;
            }
        }
    }

    // AND-search: every whitespace-separated word must occur somewhere in the
    // haystack, order-independent.
    function matchesWords(haystack, query) {
        const words = query.toLowerCase().split(/\s+/);
        for (const word of words) {
            if (word !== "" && haystack.indexOf(word) === -1)
                return false;
        }
        return true;
    }

    // Apply the caret behaviour to the TextInput inside a DankTextField
    function steadyCursorFor(fieldRoot) {
        const stack = [fieldRoot];
        while (stack.length > 0) {
            const item = stack.pop();
            if (!item)
                continue;
            if (item.cursorDelegate !== undefined && item.cursorPosition !== undefined) {
                item.cursorDelegate = steadyCursor;
                return;
            }
            const kids = item.children || [];
            for (let i = 0; i < kids.length; i++)
                stack.push(kids[i]);
        }
    }
}
