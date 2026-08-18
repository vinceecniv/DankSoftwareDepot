import QtQuick
import qs.Common

// The two rings DMS breathes on its own System Check page while it works
// (Modals/Greeter/GreeterDoctorPage.qml). Borrowed here so a check in the
// depot reads the same as a check anywhere else in the shell — and so the
// logo can stay on screen while it runs, which a spinner never allowed.
//
// Place it behind the thing that pulses, filling the same box, and bind
// that thing's scale to `breath`:
//
//     PulseRings { anchors.fill: parent; running: service.isChecking }
//     Image { scale: pulse.breath }
Item {
    id: pulse

    property bool running: false
    // The rings grow to 1.5× their own size, so at 0.66 of the box the
    // widest moment lands just inside it and nothing bleeds into the text
    readonly property real ringSize: Math.round(Math.min(width, height) * 0.66)

    // Gentle in-and-out for whatever sits in the middle. Back to 1 the
    // moment it stops: an animator leaves its property wherever it was.
    property real breath: 1

    onRunningChanged: {
        if (!running)
            breath = 1;
    }

    Rectangle {
        anchors.centerIn: parent
        width: pulse.ringSize
        height: pulse.ringSize
        radius: width / 2
        color: "transparent"
        border.width: Math.round(Theme.spacingXS * 0.75)
        border.color: Theme.primary
        opacity: 0
        visible: pulse.running

        OpacityAnimator on opacity {
            running: pulse.running
            loops: Animation.Infinite
            from: 0.8
            to: 0
            duration: 1500
            easing.type: Easing.OutQuad
        }

        ScaleAnimator on scale {
            running: pulse.running
            loops: Animation.Infinite
            from: 0.5
            to: 1.5
            duration: 1500
            easing.type: Easing.OutQuad
        }
    }

    // The inner ring runs the same clock at a smaller radius, which is what
    // makes one pulse look like a wave rather than a circle changing size.
    // It used to be drawn in the secondary colour, which made the wave read as
    // two things chasing each other rather than one moving outwards. Same
    // colour as the outer ring now; the depth comes from it being fainter,
    // which is the difference that says "further back" rather than "other".
    Rectangle {
        anchors.centerIn: parent
        width: pulse.ringSize
        height: pulse.ringSize
        radius: width / 2
        color: "transparent"
        border.width: Math.round(Theme.spacingXS * 0.75)
        border.color: Theme.primary
        opacity: 0
        visible: pulse.running

        OpacityAnimator on opacity {
            running: pulse.running
            loops: Animation.Infinite
            from: 0.5
            to: 0
            duration: 1500
            easing.type: Easing.OutQuad
        }

        ScaleAnimator on scale {
            running: pulse.running
            loops: Animation.Infinite
            from: 0.3
            to: 1.3
            duration: 1500
            easing.type: Easing.OutQuad
        }
    }

    SequentialAnimation on breath {
        running: pulse.running
        loops: Animation.Infinite

        NumberAnimation {
            from: 1
            to: 1.1
            duration: 750
            easing.type: Easing.InOutQuad
        }

        NumberAnimation {
            from: 1.1
            to: 1
            duration: 750
            easing.type: Easing.InOutQuad
        }
    }
}
