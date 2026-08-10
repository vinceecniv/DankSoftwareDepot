import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

// Rich update entry: logo, name, summary, version transition and a live
// progress bar during installation. Clicking the card asks the host to open
// the shared details popup (release notes, reviews, actions).
Rectangle {
    id: card

    required property var pkg          // daemon package: {name, repo, fromVersion, toVersion}
    property var info: null            // enrichment: {name, summary, homepage, icon, releases}
    property var itemState: null       // engine: {status, fraction, detail}
    property var store: null
    property bool showUpdateButton: false
    property bool engineBusy: false
    property bool held: false
    property string holdReason: ""
    property bool isIgnored: false
    property bool canHold: false
    // Verbatim tool output behind the short failure reason, revealed on request
    property string errorDetail: ""
    // {type, severity, ids} from updateinfo, null when the update carries no
    // advisory or the distro has none to give
    property var advisory: null

    readonly property bool isSecurity: advisory !== null && advisory.type === "security"

    // updateinfo grades its security advisories, and the grade is the part
    // that decides whether this waits until tonight. It was being fetched and
    // dropped: every fix read "Security", from a moderate library bump to a
    // critical hole in the browser you are reading this in.
    readonly property string severityLabel: {
        if (!isSecurity)
            return "";
        switch ((advisory.severity || "").toLowerCase()) {
        case "critical":
            return Tr.t("Critical");
        case "important":
            return Tr.t("Important");
        case "moderate":
            return Tr.t("Moderate");
        case "low":
            return Tr.t("Low");
        }
        return Tr.t("Security");
    }

    // Only the top two earn the full red. Below that it is still a security
    // fix, but shouting about all of them is how nobody hears any of them.
    readonly property bool isUrgent: isSecurity && ["critical", "important"].indexOf((advisory.severity || "").toLowerCase()) !== -1

    signal updateRequested
    signal holdToggleRequested
    signal detailsRequested

    readonly property string baseName: (pkg.name || "").replace(/\.(x86_64|i686|noarch|aarch64|armv7hl|ppc64le|s390x)$/, "")
    readonly property bool isFlatpak: pkg.repo === "flatpak"
    readonly property string prettyName: (info && info.name) ? info.name : baseName
    readonly property string summary: (info && info.summary) ? info.summary : ""
    readonly property string homepage: (info && info.homepage) ? info.homepage : ""
    readonly property string iconPath: (info && info.icon) ? info.icon : ""
    readonly property var newReleases: {
        if (!info || !info.releases)
            return [];
        const newer = info.releases.filter(r => r.newer && (r.notesHtml || r.version));
        return newer.slice(0, 5);
    }
    readonly property string toVersionDisplay: {
        if (pkg.toVersion)
            return pkg.toVersion;
        if (newReleases.length > 0 && newReleases[0].version)
            return newReleases[0].version;
        return "";
    }
    readonly property string status: itemState ? itemState.status : "pending"

    radius: Theme.cornerRadius
    color: Theme.surfaceContainerHigh
    opacity: held ? 0.65 : 1
    border.width: 1
    border.color: status === "error" ? Theme.withAlpha(Theme.error, 0.5) : Theme.withAlpha(Theme.outline, 0.12)
    clip: true

    implicitHeight: contentColumn.implicitHeight + Theme.spacingM * 2

    Behavior on implicitHeight {
        NumberAnimation {
            duration: Theme.mediumDuration
            easing.type: Theme.emphasizedEasing
        }
    }

    // Clicking the card opens the details popup (buttons sit on top)
    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: card.detailsRequested()
    }

    ColumnLayout {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Theme.spacingM
        spacing: Theme.spacingS

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingM

            // ── Logo ────────────────────────────────────────────────────────
            Rectangle {
                Layout.preferredWidth: 44
                Layout.preferredHeight: 44
                Layout.alignment: Qt.AlignTop
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Theme.primary, 0.08)

                Image {
                    id: logoImage
                    anchors.fill: parent
                    anchors.margins: card.iconPath.endsWith(".svg") ? 6 : 4
                    source: card.iconPath ? "file://" + card.iconPath : ""
                    sourceSize.width: 88
                    sourceSize.height: 88
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    visible: status === Image.Ready
                }

                DankIcon {
                    anchors.centerIn: parent
                    visible: logoImage.status !== Image.Ready
                    name: card.isFlatpak ? "apps" : "memory"
                    size: 24
                    color: Theme.primary
                }
            }

            // ── Name, summary, versions ─────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                StyledText {
                    Layout.fillWidth: true
                    text: card.prettyName
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: card.summary.length > 0
                    text: card.summary
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingXS
                    // Also shown without version info when there is status text
                    // to carry (hold reason, run status)
                    visible: (card.pkg.fromVersion || card.toVersionDisplay) !== "" || (card.held && card.holdReason !== "") || card.itemState !== null

                    StyledText {
                        visible: (card.pkg.fromVersion || "") !== ""
                        text: card.pkg.fromVersion || ""
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        elide: Text.ElideMiddle
                        Layout.maximumWidth: 200
                    }

                    DankIcon {
                        visible: (card.pkg.fromVersion || "") !== "" && card.toVersionDisplay !== ""
                        name: "arrow_forward"
                        size: 12
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        visible: card.toVersionDisplay !== ""
                        text: card.toVersionDisplay
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.primary
                        elide: Text.ElideMiddle
                        Layout.maximumWidth: 220
                    }

                    // Run status as text where an icon alone would be unclear
                    StyledText {
                        visible: card.itemState !== null && (card.status === "pending" || card.status === "done" || card.status === "error")
                        text: {
                            switch (card.status) {
                            case "pending":
                                return "· " + Tr.t("queued");
                            case "done":
                                return "· " + Tr.t("completed");
                            case "error":
                                return "· " + Tr.t("failed");
                            default:
                                return "";
                            }
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: card.status === "error" ? Ui.failColor : (card.status === "done" ? Theme.success : Theme.surfaceVariantText)
                    }

                    // Hold reason, e.g. "versionlock (via freerdp)"
                    StyledText {
                        visible: card.held && card.holdReason !== ""
                        text: "· " + card.holdReason
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.warning
                        elide: Text.ElideRight
                        Layout.maximumWidth: 220
                    }

                    Item {
                        Layout.fillWidth: true
                    }
                }
            }

            // ── Chips, actions and status ──────────────────────────────────
            // One cluster packed against the right edge: the chips and the
            // action slot share a row, so they line up with each other
            // instead of drifting apart across the card's right side. The
            // action slot keeps a fixed width whenever the card can show
            // something there, so buttons line up down the list.
            RowLayout {
                Layout.alignment: Qt.AlignTop
                spacing: Theme.spacingXS

                Rectangle {
                    visible: card.held
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: heldChipRow.implicitWidth + 14
                    Layout.preferredHeight: 18
                    radius: 9
                    color: Theme.withAlpha(Theme.warning, 0.18)

                    RowLayout {
                        id: heldChipRow
                        anchors.centerIn: parent
                        spacing: 3

                        DankIcon {
                            name: "lock"
                            size: 11
                            color: Theme.warning
                        }

                        StyledText {
                            text: Tr.t("Held")
                            font.pixelSize: Theme.fontSizeSmall - 2
                            font.weight: Font.Medium
                            color: Theme.warning
                        }
                    }
                }

                // Security first: the one distinction that changes whether
                // this can wait until tonight
                Rectangle {
                    visible: card.isSecurity
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: securityChipText.implicitWidth + 14
                    Layout.preferredHeight: 18
                    radius: 9
                    color: card.isUrgent ? Theme.withAlpha(Theme.error, 0.18) : Theme.withAlpha(Theme.warning, 0.18)

                    StyledText {
                        id: securityChipText
                        anchors.centerIn: parent
                        text: card.severityLabel
                        font.pixelSize: Theme.fontSizeSmall - 2
                        font.weight: Font.Medium
                        color: card.isUrgent ? Ui.failColor : Theme.warning
                    }
                }

                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: repoChipText.implicitWidth + 14
                    Layout.preferredHeight: 18
                    radius: 9
                    color: card.isFlatpak ? Theme.withAlpha(Theme.tertiary, 0.15) : Theme.withAlpha(Theme.secondary, 0.15)

                    StyledText {
                        id: repoChipText
                        anchors.centerIn: parent
                        text: card.isFlatpak ? "Flatpak" : Tr.t("System")
                        font.pixelSize: Theme.fontSizeSmall - 2
                        font.weight: Font.Medium
                        color: card.isFlatpak ? Theme.tertiary : Theme.secondary
                    }
                }

                Item {
                    // Collapses on cards that have neither a button nor a run
                    // status, so the chips stay flush against the edge
                    readonly property bool reserved: card.showUpdateButton || card.itemState !== null
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: reserved ? 28 : 0
                    Layout.preferredHeight: 28

                    DankActionButton {
                        anchors.centerIn: parent
                        visible: card.showUpdateButton && card.status === "pending" && !card.engineBusy && !card.isIgnored
                        buttonSize: 28
                        iconName: "download"
                        iconSize: 17
                        iconColor: Theme.primary
                        tooltipText: Tr.t("Update only this app")
                        onClicked: card.updateRequested()
                    }

                    DankIcon {
                        anchors.centerIn: parent
                        visible: card.status === "done"
                        name: "check_circle"
                        size: 20
                        color: Theme.success
                    }

                    DankIcon {
                        anchors.centerIn: parent
                        visible: card.status === "error"
                        name: "error"
                        size: 20
                        color: Theme.error
                    }
                }

            }
        }

        // ── Live progress ───────────────────────────────────────────────────
        ColumnLayout {
            Layout.fillWidth: true
            visible: card.status === "active"
            spacing: 2

            RowLayout {
                Layout.fillWidth: true

                StyledText {
                    Layout.fillWidth: true
                    text: card.itemState ? card.itemState.detail : ""
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 5
                radius: 2.5
                color: Theme.withAlpha(Theme.surfaceVariant, 0.4)

                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    radius: 2.5
                    color: Theme.primary
                    width: parent.width * (card.itemState ? Math.max(0.02, card.itemState.fraction) : 0)

                    Behavior on width {
                        NumberAnimation {
                            duration: 300
                            easing.type: Easing.OutCubic
                        }
                    }
                }
            }
        }

        // ── A hold sitting on top of a security fix ─────────────────────────
        // Holding a package back is a legitimate thing this app encourages,
        // right up until the update being held is the one that closes a hole.
        // Nothing said so: the "Held" chip and the "Security" chip sat side by
        // side on the same card and left the reader to draw the conclusion.
        RowLayout {
            Layout.fillWidth: true
            visible: card.held && card.isSecurity
            spacing: Theme.spacingXS

            DankIcon {
                Layout.alignment: Qt.AlignTop
                name: "warning"
                size: 14
                color: card.isUrgent ? Ui.failColor : Theme.warning
            }

            StyledText {
                Layout.fillWidth: true
                text: card.isUrgent ? Tr.t("You are holding back a security fix rated %1.").arg(card.severityLabel.toLowerCase()) : Tr.t("You are holding back a security fix.")
                font.pixelSize: Theme.fontSizeSmall - 1
                color: card.isUrgent ? Ui.failColor : Theme.warning
                wrapMode: Text.WordWrap
            }
        }

        // ── Error detail ────────────────────────────────────────────────────
        // The short reason is what the card says; the tool's own words are
        // one click away rather than on display, because they are long,
        // untranslated and only interesting when reporting a problem.
        ColumnLayout {
            Layout.fillWidth: true
            visible: card.status === "error" && card.itemState && (card.itemState.detail || "") !== ""
            spacing: 2

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingXS

                StyledText {
                    Layout.fillWidth: true
                    text: card.itemState ? card.itemState.detail : ""
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Ui.failColor
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }

                StyledText {
                    id: errorToggle

                    property bool expanded: false

                    visible: card.errorDetail !== ""
                    text: expanded ? Tr.t("Hide details") : Tr.t("Show details")
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.underline: toggleArea.containsMouse
                    color: Ui.failColor

                    MouseArea {
                        id: toggleArea
                        anchors.fill: parent
                        anchors.margins: -4
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: errorToggle.expanded = !errorToggle.expanded
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                visible: errorToggle.expanded && card.errorDetail !== ""
                implicitHeight: rawErrorText.implicitHeight + Theme.spacingS * 2
                radius: Theme.cornerRadius / 2
                color: Theme.withAlpha(Theme.surfaceVariant, 0.5)

                StyledText {
                    id: rawErrorText
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.margins: Theme.spacingS
                    text: card.errorDetail
                    font.family: Theme.monoFontFamily
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                    wrapMode: Text.Wrap
                }
            }
        }

    }
}
