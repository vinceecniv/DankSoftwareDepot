import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

// Shared app-details popup used by the Updates, Installed and Install tabs.
// Shows everything that is known about an app: description, screenshots,
// sizes, release notes / changelog, ODRS review texts — plus the actions the
// hosting tab provides (install, update, hold, restore, uninstall).
//
// The host calls open(appData) with:
//   {id, name, summary, iconPath, homepage, rating, held, holdReason,
//    versionLabel, origin, isFlatpak, sources: [{source, kind, ref}]}
// and binds the extra-content/action properties below. Description,
// screenshots, sizes, reviews and rating are fetched here via
// `enrich.py --appinfo` (cached daily).
Item {
    id: dialog

    property var app: null
    readonly property bool showing: app !== null
    readonly property var appData: app || ({})
    property var info: ({})
    property bool loading: false

    // Extra content supplied by the host
    property var releases: []            // [{version, date, notesHtml, newer}]
    property string releasesTitle: Tr.t("Release notes")
    property string changelog: ""        // rpm changelog text
    property bool changelogLoading: false
    // Upstream notes for a package built from git, where the distro has none
    // to give: either the release being installed, or the commits between two
    // snapshots of the branch. See MetadataStore.fetchGitNotes().
    property var gitReleases: []         // [{version, date, notesHtml}]
    property bool gitNotesLoading: false
    property string gitNotesKind: ""     // "release" | "commits" | ""
    property string gitNotesUrl: ""      // release or compare page upstream
    property int gitNotesMore: 0         // commits or blocks left unshown
    property int gitNotesCommits: 0
    // {type, severity, ids} from updateinfo. The CVE numbers were being
    // fetched with the rest and thrown away; this is the one place with room
    // to print them, and the one place someone would look them up from.
    property var advisory: null
    property var previousVersions: []    // [{label, payload}]
    property bool versionsLoading: false
    property bool noOlderVersions: false

    // Actions
    property bool busy: false
    property string busyDetail: ""   // live progress line shown next to the spinner
    property real busyFraction: 0    // 0..1 estimate; > 0 swaps the spinner for a progress bar
    property bool installedChipVisible: false
    property bool showInstallButtons: false
    property bool showUpdateButton: false
    property bool showHoldToggle: false
    property bool showUninstall: false
    // Packages the resolver says would go with this one. Empty until the
    // unprivileged plan comes back, and empty for anything that takes
    // nothing with it.
    property var alsoRemoves: []
    // {userInstalled, requiredBy, requiredByCount} — why this package is here
    property var provenance: null

    signal installRequested(var source)
    signal updateRequested()
    signal holdToggleRequested()
    signal uninstallRequested()
    signal restoreRequested(var payload)
    signal opened()

    // AppImage update source: a GitHub project whose releases feed updates.
    // The host binds the current repo and performs the save.
    property bool showUpdateSource: false
    property string updateSourceRepo: ""       // "owner/repo" or ""
    property string updateSourceStatus: ""     // "" | saving | done | error:<msg>
    signal updateSourceSaveRequested(string link)

    // The name a source goes by, not the id it is keyed on: the sizes line
    // read "fedora: 12 MB download" in every language, next to a translated
    // sentence. The install button below has always used the kind for this.
    function sourceLabel(entry) {
        if (entry.kind === "flatpak")
            return "Flathub";
        if (entry.kind === "appimage")
            return "AppImage";
        if (entry.kind === "dnf")
            return Backend.systemRepoLabel;
        const source = entry.source || "";
        return source.charAt(0).toUpperCase() + source.slice(1);
    }

    readonly property string updateSourceUrl: updateSourceRepo !== "" ? "https://github.com/" + updateSourceRepo : ""

    property string _confirmUninstall: ""

    readonly property string scriptPath: Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", "")

    function open(appData) {
        app = appData;
        info = {};
        _confirmUninstall = "";
        reviewsShown = 5;
        reviewFormOpen = false;
        reviewStatus = "";
        reviewStars = 5;
        permsExpanded = false;
        updateSourceStatus = "";
        if ((appData.sources || []).some(s => s.kind === "flatpak" || s.kind === "dnf")) {
            loading = true;
            infoProcess.command = [Backend.python, scriptPath, "--appinfo", JSON.stringify({
                id: appData.id,
                sources: appData.sources || []
            })];
            infoProcess.running = true;
        } else {
            loading = false;
        }
        opened();
    }

    function close() {
        app = null;
        info = {};
        _confirmUninstall = "";
        lightboxIndex = -1;
        reviewsShown = 5;
    }

    // Reviews are revealed incrementally while scrolling toward the bottom
    property int reviewsShown: 5

    // Launch button (installed flatpaks / AppImages). openCommand overrides
    // the default `flatpak run <id>`.
    property bool showOpenButton: false
    property var openCommand: []

    // ── Write-a-review state ────────────────────────────────────────────────
    property bool reviewFormOpen: false
    property int reviewStars: 5
    property string reviewStatus: ""   // "" | sending | done | error:<msg>

    // Reviews live on ODRS, keyed by the AppStream/package id. AppImages only
    // have a plugin-local id (no shared identity anyone else could look up),
    // so reading and writing reviews is disabled for them.
    readonly property bool reviewable: (appData.sources || []).some(s => s.kind === "flatpak" || s.kind === "dnf")

    // Prefill the reviewer name from the remembered value, falling back to
    // the login name (which the backend would otherwise use anyway)
    onReviewFormOpenChanged: {
        if (reviewFormOpen && reviewNameField.text.trim() === "")
            reviewNameField.text = PluginService.loadPluginData("dankSoftwareDepot", "reviewerName", Quickshell.env("USER") || "");
    }

    function submitReview(summaryText, bodyText, displayName) {
        reviewStatus = "sending";
        if (displayName !== "")
            PluginService.savePluginData("dankSoftwareDepot", "reviewerName", displayName);
        reviewProcess.command = [Backend.python, scriptPath, "--submit-review", JSON.stringify({
            app_id: appData.id,
            rating: reviewStars,
            summary: summaryText,
            description: bodyText,
            user_display: displayName,
            version: appData.versionLabel || "unknown"
        })];
        reviewProcess.running = true;
    }

    Process {
        id: reviewProcess

        stdout: StdioCollector {
            onStreamFinished: {
                let ok = false;
                let error = "";
                try {
                    const result = JSON.parse(text);
                    ok = result.ok === true;
                    error = result.error || "";
                } catch (e) {
                    error = "parse";
                }
                dialog.reviewStatus = ok ? "done" : ("error:" + error);
                if (ok)
                    dialog.reviewFormOpen = false;
            }
        }
    }

    // Sandbox permission token → readable label
    function permLabel(token) {
        switch (token) {
        case "network":
            return Tr.t("Network");
        case "ipc":
            return "IPC";
        case "x11":
        case "fallback-x11":
            return "X11";
        case "wayland":
            return "Wayland";
        case "pulseaudio":
            return Tr.t("Audio");
        case "pcsc":
            return "PC/SC";
        case "cups":
            return Tr.t("Printing");
        case "ssh-auth":
            return "SSH";
        case "session-bus":
        case "dbus-talk":
            return Tr.t("D-Bus services");
        case "system-dbus":
            return Tr.t("System D-Bus");
        case "devices:all":
            return Tr.t("All devices");
        case "devices":
            return Tr.t("Device access");
        }
        if (token.indexOf("fs:") === 0) {
            const fs = token.substring(3);
            if (fs === "host" || fs === "host:ro")
                return Tr.t("Full file access");
            if (fs.indexOf("home") === 0)
                return Tr.t("Home folder");
            if (fs.indexOf("xdg-download") === 0)
                return Tr.t("Downloads folder");
            if (fs.indexOf("xdg-documents") === 0)
                return Tr.t("Documents folder");
            if (fs.indexOf("xdg-pictures") === 0)
                return Tr.t("Pictures folder");
            if (fs.indexOf("xdg-music") === 0)
                return Tr.t("Music folder");
            if (fs.indexOf("xdg-videos") === 0)
                return Tr.t("Videos folder");
            return fs;
        }
        return token;
    }

    // Risky permissions first, filesystem paths last; the list is collapsed
    // to one row's worth of chips until expanded
    readonly property var permissionTokens: {
        const tokens = ((info.flathub && info.flathub.permissions) ? info.flathub.permissions : []).filter(tok => tok !== "ipc");
        const rank = tok => {
            if (tok === "devices:all" || tok === "fs:host" || tok === "fs:host:ro")
                return 0;
            if (tok === "network")
                return 1;
            if (tok.indexOf("fs:") === 0)
                return 4;
            if (tok === "dbus-talk" || tok === "system-dbus")
                return 3;
            return 2;
        };
        return tokens.slice().sort((a, b) => rank(a) - rank(b));
    }
    property bool permsExpanded: false
    readonly property int permsCollapsedCount: 8
    readonly property var visiblePermissionTokens: permsExpanded ? permissionTokens : permissionTokens.slice(0, permsCollapsedCount)

    // ── Screenshot lightbox state ────────────────────────────────────────────
    property int lightboxIndex: -1
    readonly property bool lightboxOpen: lightboxIndex >= 0
    readonly property var screenshotUrls: (info.screenshots && info.screenshots.length > 0) ? info.screenshots : (appData.screenshots || [])

    function screenshotSource(value) {
        return value.startsWith("/") ? "file://" + value : value;
    }

    function lightboxStep(delta) {
        if (screenshotUrls.length === 0)
            return;
        lightboxIndex = (lightboxIndex + delta + screenshotUrls.length) % screenshotUrls.length;
    }

    readonly property var effectiveRating: appData.rating || info.rating || null

    // SPDX expressions can be endless AND/OR chains — show the first license
    // with a counter for the rest
    function shortLicense(license) {
        const parts = (license || "").split(/\s+(?:AND|OR)\s+/i).filter(p => p !== "");
        if (parts.length <= 1)
            return license || "";
        return parts[0].replace(/^\(+|\)+$/g, "") + " +" + (parts.length - 1);
    }

    function formatCount(n) {
        if (n >= 1000000)
            return (n / 1000000).toFixed(1) + "M";
        if (n >= 10000)
            return Math.round(n / 1000) + "k";
        if (n >= 1000)
            return (n / 1000).toFixed(1) + "k";
        return String(n);
    }

    Process {
        id: infoProcess

        // NDJSON: the local part ({"partial": true}) arrives first so the
        // description shows immediately; the network extras (screenshots,
        // sizes, reviews) merge in when the second line lands.
        stdout: SplitParser {
            onRead: line => {
                let data = null;
                try {
                    data = JSON.parse(line);
                } catch (e) {
                    return;
                }
                delete data.partial;
                dialog.info = Object.assign({}, dialog.info, data);
                dialog.loading = false;
            }
        }

        onExited: (exitCode, exitStatus) => {
            dialog.loading = false;
        }
    }

    Timer {
        id: confirmTimer
        interval: 5000
        onTriggered: dialog._confirmUninstall = ""
    }

    anchors.fill: parent
    visible: showing
    z: 100

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)

        MouseArea {
            anchors.fill: parent
            onClicked: dialog.close()
            // Consume wheel events so content behind the popup never scrolls
            onWheel: wheel => wheel.accepted = true
        }
    }

    onShowingChanged: {
        if (showing)
            dialogFocus.forceActiveFocus();
    }

    Item {
        id: dialogFocus

        Keys.onEscapePressed: {
            if (dialog.lightboxOpen)
                dialog.lightboxIndex = -1;
            else
                dialog.close();
        }
        Keys.onLeftPressed: {
            if (dialog.lightboxOpen)
                dialog.lightboxStep(-1);
        }
        Keys.onRightPressed: {
            if (dialog.lightboxOpen)
                dialog.lightboxStep(1);
        }
    }

    // ── Screenshot lightbox (above the card) ────────────────────────────────
    Rectangle {
        anchors.fill: parent
        visible: dialog.lightboxOpen
        color: Qt.rgba(0, 0, 0, 0.85)
        z: 10

        MouseArea {
            anchors.fill: parent
            onClicked: dialog.lightboxIndex = -1
            onWheel: wheel => wheel.accepted = true
        }

        Image {
            id: lightboxImage
            anchors.centerIn: parent
            width: parent.width - 110
            height: parent.height - 90
            source: dialog.lightboxOpen ? dialog.screenshotSource(dialog.screenshotUrls[dialog.lightboxIndex]) : ""
            fillMode: Image.PreserveAspectFit
            asynchronous: true

            MouseArea {
                anchors.fill: parent
            }
        }

        DankSpinner {
            anchors.centerIn: parent
            visible: lightboxImage.status === Image.Loading
            size: 40
        }

        DankActionButton {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Theme.spacingM
            buttonSize: 36
            iconName: "close"
            iconSize: 20
            iconColor: "white"
            onClicked: dialog.lightboxIndex = -1
        }

        DankActionButton {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.spacingS
            visible: dialog.screenshotUrls.length > 1
            buttonSize: 40
            iconName: "chevron_left"
            iconSize: 26
            iconColor: "white"
            onClicked: dialog.lightboxStep(-1)
        }

        DankActionButton {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.rightMargin: Theme.spacingS
            visible: dialog.screenshotUrls.length > 1
            buttonSize: 40
            iconName: "chevron_right"
            iconSize: 26
            iconColor: "white"
            onClicked: dialog.lightboxStep(1)
        }

        StyledText {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottomMargin: Theme.spacingM
            visible: dialog.screenshotUrls.length > 1
            text: (dialog.lightboxIndex + 1) + " / " + dialog.screenshotUrls.length
            font.pixelSize: Theme.fontSizeSmall
            color: "white"
        }
    }

    Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(680, dialog.width - Theme.spacingL * 2)
        height: Math.min(dialog.height - Theme.spacingL * 2, 640)
        radius: Theme.cornerRadius
        color: Theme.surfaceContainer
        border.width: 1
        border.color: Theme.withAlpha(Theme.surfaceVariantText, 0.25)

        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            // ── Header ──────────────────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingM

                Item {
                    Layout.preferredWidth: 48
                    Layout.preferredHeight: 48

                    Image {
                        id: dialogLogo
                        anchors.fill: parent
                        source: dialog.appData.iconPath ? (dialog.appData.iconPath.indexOf("http") === 0 ? dialog.appData.iconPath : "file://" + dialog.appData.iconPath) : ""
                        sourceSize.width: 96
                        sourceSize.height: 96
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        visible: status === Image.Ready
                    }

                    DankIcon {
                        anchors.centerIn: parent
                        visible: dialogLogo.status !== Image.Ready
                        name: dialog.appData.isFlatpak === false ? "memory" : "apps"
                        size: 30
                        color: Theme.surfaceVariantText
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingS

                        // The package name is the string most worth copying in
                        // this window — into a search box, a bug report, a
                        // command. It wraps rather than elides now, because
                        // the element that can be selected has no ellipsis and
                        // a name cut short with no mark saying so is worse
                        // than a name on two lines.
                        SelectableText {
                            text: dialog.appData.name || ""
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            wrapMode: Text.WordWrap
                            Layout.maximumWidth: 360
                        }

                        // Flathub-verified developer
                        DankIcon {
                            visible: dialog.info.flathub !== undefined && dialog.info.flathub !== null && dialog.info.flathub.verified === true
                            name: "verified"
                            filled: true
                            size: 16
                            color: Theme.primary
                        }

                        Rectangle {
                            visible: (dialog.appData.origin || "") !== ""
                            Layout.preferredWidth: originChip.implicitWidth + 14
                            Layout.preferredHeight: 18
                            radius: 9
                            color: dialog.appData.isFlatpak !== false ? Theme.withAlpha(Theme.tertiary, 0.15) : Theme.withAlpha(Theme.secondary, 0.15)

                            StyledText {
                                id: originChip
                                anchors.centerIn: parent
                                text: dialog.appData.origin || ""
                                font.pixelSize: Theme.fontSizeSmall - 2
                                color: dialog.appData.isFlatpak !== false ? Theme.tertiary : Theme.secondary
                            }
                        }

                        Rectangle {
                            visible: dialog.appData.held === true
                            Layout.preferredWidth: heldChip.implicitWidth + 12
                            Layout.preferredHeight: 16
                            radius: 8
                            color: Theme.withAlpha(Theme.warning, 0.18)

                            StyledText {
                                id: heldChip
                                anchors.centerIn: parent
                                text: Tr.t("Held")
                                font.pixelSize: Theme.fontSizeSmall - 2
                                color: Theme.warning
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                        }
                    }

                    // Version · developer, then the license behind its own
                    // icon. A licence field is free text, not a vocabulary:
                    // next to the SPDX ids sit full names ("GNU General Public
                    // License v3.0") and whole sentences from third-party
                    // vendors ("Multiple, see https://www.vivaldi.com/"). As
                    // the third item in a dot-separated line those read like a
                    // continuation of the sentence before them; behind a mark
                    // that says "licence", any of them reads as one.
                    RowLayout {
                        id: identityRow

                        // Computed here rather than read back off the children:
                        // an item's `visible` is false whenever its parent's
                        // is, so a row asking its children whether to be shown
                        // answers itself and latches shut.
                        readonly property string identityLine: {
                            const parts = [];
                            if (dialog.appData.versionLabel)
                                parts.push(dialog.appData.versionLabel);
                            if (dialog.info.developer)
                                parts.push(dialog.info.developer);
                            return parts.join(" · ");
                        }
                        readonly property string licenseLine: dialog.info.license ? dialog.shortLicense(dialog.info.license) : ""

                        Layout.fillWidth: true
                        spacing: Theme.spacingXS
                        visible: identityLine !== "" || licenseLine !== ""

                        // Version step and developer: the other half of what
                        // gets pasted somewhere. Both halves of this row share
                        // the width and wrap, since neither can elide any more
                        // — which is also why the developer stays in the same
                        // text as the version rather than getting a mark of
                        // its own. A third free-standing segment would need a
                        // third share of the width, and the row would pull
                        // itself apart into evenly spaced columns.
                        DankIcon {
                            visible: identityRow.identityLine !== ""
                            name: "tag"
                            size: 13
                            color: Theme.surfaceVariantText
                        }

                        // The leftover width goes to the last item, not this
                        // one: whoever takes it pushes everything after it
                        // along, and the licence was ending up adrift in the
                        // middle of the row. It can still shrink and wrap when
                        // the row is genuinely too narrow.
                        SelectableText {
                            id: identityText

                            Layout.minimumWidth: 0
                            visible: identityRow.identityLine !== ""
                            text: identityRow.identityLine
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }

                        DankIcon {
                            id: licenseIcon

                            visible: identityRow.licenseLine !== ""
                            name: "license"
                            size: 13
                            color: Theme.surfaceVariantText
                        }

                        SelectableText {
                            id: licenseText

                            Layout.minimumWidth: 0
                            visible: identityRow.licenseLine !== ""
                            text: identityRow.licenseLine
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }

                        // Somebody has to want the leftover width, or the
                        // layout hands each item an equal share of it. A
                        // package with no licence to show would otherwise put
                        // the gap back, in a row that no longer has anything
                        // on its right to blame.
                        Item {
                            Layout.fillWidth: true
                        }
                    }

                    RowLayout {
                        visible: !!dialog.effectiveRating
                        spacing: 1

                        Repeater {
                            model: 5

                            delegate: DankIcon {
                                required property int index

                                readonly property bool lit: dialog.effectiveRating && (index + 0.25 <= dialog.effectiveRating.stars)

                                name: "star"
                                filled: lit
                                size: 13
                                color: lit ? Theme.warning : Theme.withAlpha(Theme.surfaceVariantText, 0.5)
                            }
                        }

                        StyledText {
                            text: dialog.effectiveRating ? Tr.t("%1 (%2 ratings)").arg(dialog.effectiveRating.stars).arg(dialog.effectiveRating.count) : ""
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                DankActionButton {
                    Layout.alignment: Qt.AlignTop
                    buttonSize: 30
                    iconName: "close"
                    iconSize: 18
                    iconColor: Theme.surfaceVariantText
                    onClicked: dialog.close()
                }
            }

            // ── Scrollable body (DankFlickable: same wheel feel as the lists)
            DankFlickable {
                id: body
                Component.onCompleted: Ui.softenScrollbar(body)
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentHeight: bodyColumn.height

                // Reveal more reviews when the bottom is (almost) reached
                onContentYChanged: {
                    if (contentHeight - (contentY + height) < 220 && dialog.reviewsShown < (dialog.info.reviews || []).length)
                        dialog.reviewsShown += 5;
                }

                Column {
                    id: bodyColumn
                    width: body.width
                    spacing: Theme.spacingM

                    Item {
                        width: parent.width
                        height: 80
                        visible: dialog.loading

                        DankSpinner {
                            anchors.centerIn: parent
                            size: 32
                        }
                    }

                    // Screenshots
                    Flickable {
                        width: parent.width
                        height: 190
                        visible: (dialog.info.screenshots || []).length > 0
                        contentWidth: shotsRow.width
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        Row {
                            id: shotsRow
                            spacing: Theme.spacingS

                            Repeater {
                                model: dialog.screenshotUrls

                                delegate: Rectangle {
                                    required property var modelData
                                    required property int index

                                    width: 320
                                    height: 190
                                    radius: Theme.cornerRadius
                                    color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.6)

                                    Image {
                                        anchors.fill: parent
                                        anchors.margins: 4
                                        source: dialog.screenshotSource(modelData)
                                        fillMode: Image.PreserveAspectFit
                                        asynchronous: true
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: dialog.lightboxIndex = index
                                    }
                                }
                            }
                        }
                    }

    // Description: appstream enrichment first, then the catalog-provided
                    // sanitized HTML (e.g. AppImage feed), then the plain summary
                    readonly property string effectiveDescription: (dialog.info.descriptionHtml || "") !== "" ? dialog.info.descriptionHtml : (dialog.appData.descriptionHtml || "")

                    SelectableText {
                        width: parent.width
                        visible: bodyColumn.effectiveDescription !== ""
                        text: bodyColumn.effectiveDescription
                        textFormat: Text.RichText
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceText
                    }

                    StyledText {
                        width: parent.width
                        visible: !dialog.loading && bodyColumn.effectiveDescription === "" && (dialog.appData.summary || "") !== ""
                        text: dialog.appData.summary || ""
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceText
                    }

                    // Held reason
                    StyledText {
                        width: parent.width
                        visible: (dialog.appData.holdReason || "") !== ""
                        text: Tr.t("Held: %1").arg(dialog.appData.holdReason)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.warning
                        wrapMode: Text.WordWrap
                    }

                    // Sizes per source
                    Column {
                        width: parent.width
                        spacing: 2
                        visible: (dialog.info.sizes || []).length > 0

                        Repeater {
                            model: dialog.info.sizes || []

                            delegate: RowLayout {
                                required property var modelData

                                width: parent.width
                                spacing: Theme.spacingS

                                DankIcon {
                                    name: "hard_drive"
                                    size: 14
                                    color: Theme.surfaceVariantText
                                }

                                // Without this the row has nothing that wants
                                // the leftover width, and a layout with no
                                // taker splits it evenly between its items —
                                // which put half a row's worth of nothing
                                // between the drive icon and its own sentence
                                StyledText {
                                    Layout.fillWidth: true
                                    text: {
                                        const parts = [];
                                        if (modelData.download)
                                            parts.push(Tr.t("%1 download").arg(modelData.download));
                                        if (modelData.installed)
                                            parts.push(Tr.t("%1 installed").arg(modelData.installed));
                                        return dialog.sourceLabel(modelData) + ": " + parts.join(" · ");
                                    }
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }
                    }

                    // AppImage update source (GitHub releases)
                    StyledText {
                        visible: dialog.showUpdateSource
                        text: Tr.t("Update source")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS
                        visible: dialog.showUpdateSource

                        StyledText {
                            width: parent.width
                            text: Tr.t("Link a GitHub project to get updates from its releases.")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }

                        RowLayout {
                            width: parent.width
                            spacing: Theme.spacingS

                            DankTextField {
                                id: repoField
                                Layout.fillWidth: true
                                placeholderText: "https://github.com/owner/project"

                                Connections {
                                    target: dialog

                                    function onOpened() {
                                        repoField.text = dialog.updateSourceUrl;
                                    }
                                }
                            }

                            DankSpinner {
                                visible: dialog.updateSourceStatus === "saving"
                                size: 18
                            }

                            // Wrapper Item: DankButton sizes itself through `width`, which a layout does not read
                            Item {
                                Layout.preferredWidth: updateSourceSaveButton.width
                                Layout.preferredHeight: updateSourceSaveButton.height
                                visible: updateSourceSaveButton.visible

                                DankButton {
                                    id: updateSourceSaveButton
                                    buttonHeight: 28
                                    horizontalPadding: Theme.spacingM
                                    iconName: "save"
                                    iconSize: 13
                                    text: Tr.t("Save")
                                    backgroundColor: Theme.buttonBg
                                    textColor: Theme.buttonText
                                    enabled: dialog.updateSourceStatus !== "saving" && repoField.text.trim() !== dialog.updateSourceUrl
                                    onClicked: dialog.updateSourceSaveRequested(repoField.text.trim())
                                }
                            }
                        }

                        StyledText {
                            width: parent.width
                            visible: dialog.updateSourceStatus === "done"
                            text: Tr.t("Update source saved.")
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.success
                        }

                        StyledText {
                            width: parent.width
                            visible: dialog.updateSourceStatus.indexOf("error:") === 0
                            text: Tr.t("Could not set update source: %1").arg(dialog.updateSourceStatus.substring(6))
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.error
                            wrapMode: Text.WordWrap
                        }
                    }

                    // Sandbox permissions (directly in the popup, as compact chips)
                    StyledText {
                        visible: dialog.permissionTokens.length > 0
                        text: Tr.t("Permissions")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }

                    Flow {
                        width: parent.width
                        spacing: Theme.spacingXS
                        visible: dialog.permissionTokens.length > 0

                        Repeater {
                            model: dialog.visiblePermissionTokens

                            delegate: Rectangle {
                                required property var modelData

                                width: permChipRow.implicitWidth + 14
                                height: 22
                                radius: 11
                                color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.8)

                                RowLayout {
                                    id: permChipRow
                                    anchors.centerIn: parent
                                    spacing: 4

                                    DankIcon {
                                        name: modelData === "network" ? "public" : (modelData.indexOf("fs:") === 0 ? "folder" : (modelData.indexOf("devices") === 0 ? "usb" : "shield"))
                                        size: 12
                                        color: (modelData === "devices:all" || modelData === "fs:host") ? Theme.warning : Theme.surfaceVariantText
                                    }

                                    StyledText {
                                        text: dialog.permLabel(modelData)
                                        font.pixelSize: Theme.fontSizeSmall - 2
                                        color: Theme.surfaceText
                                    }
                                }
                            }
                        }

                        // Expand / collapse chip
                        Rectangle {
                            visible: dialog.permissionTokens.length > dialog.permsCollapsedCount
                            width: permToggleRow.implicitWidth + 14
                            height: 22
                            radius: 11
                            color: Theme.withAlpha(Theme.primary, 0.12)

                            RowLayout {
                                id: permToggleRow
                                anchors.centerIn: parent
                                spacing: 4

                                DankIcon {
                                    name: dialog.permsExpanded ? "expand_less" : "expand_more"
                                    size: 12
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: dialog.permsExpanded ? Tr.t("Show fewer") : ("+" + (dialog.permissionTokens.length - dialog.permsCollapsedCount))
                                    font.pixelSize: Theme.fontSizeSmall - 2
                                    color: Theme.primary
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: dialog.permsExpanded = !dialog.permsExpanded
                            }
                        }
                    }

                    // Flathub install statistics
                    RowLayout {
                        width: parent.width
                        spacing: Theme.spacingS
                        visible: !!dialog.info.installStats

                        DankIcon {
                            name: "trending_up"
                            size: 14
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            Layout.fillWidth: true
                            text: {
                                const stats = dialog.info.installStats || {};
                                const parts = [];
                                if (stats.month !== undefined)
                                    parts.push(Tr.t("%1 installs last month").arg(dialog.formatCount(stats.month)));
                                else if (stats.week !== undefined)
                                    parts.push(Tr.t("%1 installs last week").arg(dialog.formatCount(stats.week)));
                                if (stats.total !== undefined)
                                    parts.push(Tr.t("%1 total").arg(dialog.formatCount(stats.total)));
                                return "Flathub: " + parts.join(" · ");
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }

                    // What this update is rated, and what it closes
                    RowLayout {
                        width: parent.width
                        spacing: Theme.spacingS
                        visible: dialog.advisory !== null && (dialog.advisory.type || "") === "security"

                        DankIcon {
                            Layout.alignment: Qt.AlignTop
                            name: "shield"
                            size: 16
                            color: Ui.failColor
                        }

                        StyledText {
                            Layout.fillWidth: true
                            text: {
                                if (!dialog.advisory)
                                    return "";
                                const severity = (dialog.advisory.severity || "").toLowerCase();
                                const names = ({
                                        critical: Tr.t("Critical"),
                                        important: Tr.t("Important"),
                                        moderate: Tr.t("Moderate"),
                                        low: Tr.t("Low")
                                    });
                                const label = names[severity] || Tr.t("Security");
                                const ids = dialog.advisory.ids || [];
                                return ids.length > 0 ? Tr.t("Security fix, rated %1 — %2").arg(label.toLowerCase()).arg(ids.join(", ")) : Tr.t("Security fix, rated %1").arg(label.toLowerCase());
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        }
                    }

                    // Release notes (AppStream releases from the host)
                    StyledText {
                        visible: dialog.releases.length > 0
                        text: dialog.releasesTitle
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }

                    Repeater {
                        model: dialog.releases

                        delegate: Column {
                            required property var modelData

                            width: bodyColumn.width
                            spacing: 2

                            RowLayout {
                                spacing: Theme.spacingS

                                Rectangle {
                                    Layout.preferredWidth: versionChip.implicitWidth + 14
                                    Layout.preferredHeight: 18
                                    radius: 9
                                    color: Theme.withAlpha(Theme.primary, 0.12)

                                    StyledText {
                                        id: versionChip
                                        anchors.centerIn: parent
                                        text: modelData.version || ""
                                        font.pixelSize: Theme.fontSizeSmall - 2
                                        color: Theme.primary
                                    }
                                }

                                StyledText {
                                    visible: (modelData.date || 0) > 0
                                    text: modelData.date > 0 ? new Date(modelData.date * 1000).toLocaleDateString(Qt.locale(), Locale.ShortFormat) : ""
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceVariantText
                                }
                            }

                            SelectableText {
                                width: parent.width
                                text: modelData.notesHtml || ("<i>" + Tr.t("No release notes published.") + "</i>")
                                textFormat: Text.RichText
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                wrapMode: Text.WordWrap
                            }
                        }
                    }

                    // Upstream notes for a git build. The distro has nothing
                    // to say about a commit, so this comes from the forge the
                    // package is built from.
                    StyledText {
                        visible: dialog.gitNotesLoading || dialog.gitReleases.length > 0
                        text: dialog.gitNotesKind === "commits" ? Tr.t("Commits since your build") : Tr.t("What's new upstream")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }

                    StyledText {
                        visible: dialog.gitNotesLoading
                        text: Tr.t("Asking upstream…")
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }

                    Repeater {
                        model: dialog.gitReleases

                        delegate: Column {
                            required property var modelData

                            width: bodyColumn.width
                            spacing: 2

                            RowLayout {
                                spacing: Theme.spacingS

                                Rectangle {
                                    Layout.preferredWidth: gitVersionChip.implicitWidth + 14
                                    Layout.preferredHeight: 18
                                    radius: 9
                                    color: Theme.withAlpha(Theme.primary, 0.12)

                                    StyledText {
                                        id: gitVersionChip
                                        anchors.centerIn: parent
                                        text: modelData.version || ""
                                        font.pixelSize: Theme.fontSizeSmall - 2
                                        font.family: dialog.gitNotesKind === "commits" ? (Theme.monoFontFamily || "monospace") : Theme.fontFamily
                                        color: Theme.primary
                                    }
                                }

                                StyledText {
                                    visible: dialog.gitNotesKind === "commits" && dialog.gitNotesCommits > 0
                                    text: Tr.t("%1 commits").arg(dialog.gitNotesCommits)
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceVariantText
                                }

                                StyledText {
                                    visible: (modelData.date || 0) > 0
                                    text: modelData.date > 0 ? new Date(modelData.date * 1000).toLocaleDateString(Qt.locale(), Locale.ShortFormat) : ""
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceVariantText
                                }
                            }

                            SelectableText {
                                width: parent.width
                                text: modelData.notesHtml || ("<i>" + Tr.t("No release notes published.") + "</i>")
                                textFormat: Text.RichText
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                wrapMode: Text.WordWrap
                            }
                        }
                    }

                    // Notes long enough to be cut short are worth finishing
                    // somewhere, and the page they came from is the place
                    RowLayout {
                        width: parent.width
                        spacing: Theme.spacingXS
                        visible: dialog.gitNotesUrl !== "" && dialog.gitReleases.length > 0

                        DankIcon {
                            name: "open_in_new"
                            size: 13
                            color: Theme.primary
                        }

                        StyledText {
                            text: dialog.gitNotesMore > 0 && dialog.gitNotesKind === "commits" ? Tr.t("%1 more commits upstream").arg(dialog.gitNotesMore) : (dialog.gitNotesMore > 0 ? Tr.t("Read the rest upstream") : Tr.t("Open upstream"))
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.primary
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        HoverHandler {
                            cursorShape: Qt.PointingHandCursor
                        }

                        TapHandler {
                            onTapped: Qt.openUrlExternally(dialog.gitNotesUrl)
                        }
                    }

                    // rpm changelog
                    StyledText {
                        visible: dialog.changelogLoading || dialog.changelog !== ""
                        text: Tr.t("Changelog")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }

                    SelectableText {
                        width: parent.width
                        visible: dialog.changelogLoading || dialog.changelog !== ""
                        text: dialog.changelogLoading ? Tr.t("Loading changelog…") : dialog.changelog
                        font.pixelSize: Theme.fontSizeSmall - 1
                        font.family: Theme.monoFontFamily || "monospace"
                        color: Theme.surfaceText
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        textFormat: Text.PlainText
                    }

                    // Previous versions
                    StyledText {
                        visible: dialog.versionsLoading || dialog.previousVersions.length > 0 || dialog.noOlderVersions
                        text: Tr.t("Previous versions")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }

                    StyledText {
                        visible: dialog.versionsLoading
                        text: Tr.t("Checking available versions…")
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        visible: !dialog.versionsLoading && dialog.noOlderVersions && dialog.previousVersions.length === 0
                        text: Tr.t("No older version available.")
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }

                    Flow {
                        width: parent.width
                        spacing: Theme.spacingS
                        visible: dialog.previousVersions.length > 0

                        Repeater {
                            model: dialog.previousVersions

                            delegate: DankButton {
                                required property var modelData

                                buttonHeight: 26
                                horizontalPadding: Theme.spacingM
                                iconName: "history"
                                iconSize: 13
                                text: Tr.t("Restore %1").arg(modelData.label)
                                backgroundColor: Theme.surfaceContainerHighest
                                textColor: Theme.surfaceText
                                enabled: !dialog.busy
                                onClicked: dialog.restoreRequested(modelData.payload)
                            }
                        }
                    }

                    // Reviews
                    RowLayout {
                        width: parent.width
                        visible: dialog.reviewable && ((dialog.info.reviews || []).length > 0 || dialog.installedChipVisible || dialog.showOpenButton)

                        StyledText {
                            text: Tr.t("Reviews")
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.DemiBold
                            color: Theme.surfaceText
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        StyledText {
                            visible: dialog.reviewStatus === "done"
                            text: Tr.t("Thanks — your review was submitted.")
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.success
                        }

                        // Wrapper Item: DankButton sizes itself via `width`,
                        // which the RowLayout would ignore and cramp the label
                        Item {
                            visible: !dialog.reviewFormOpen && dialog.reviewStatus !== "done"
                            Layout.preferredWidth: writeReviewButton.width
                            Layout.preferredHeight: writeReviewButton.height

                            DankButton {
                                id: writeReviewButton
                                buttonHeight: 26
                                horizontalPadding: Theme.spacingM
                                iconName: "rate_review"
                                iconSize: 13
                                text: Tr.t("Write a review")
                                backgroundColor: Theme.secondaryContainer
                                textColor: Theme.surfaceText
                                onClicked: dialog.reviewFormOpen = true
                            }
                        }
                    }

                    // Inline review form
                    Rectangle {
                        width: parent.width
                        visible: dialog.reviewFormOpen
                        implicitHeight: reviewForm.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.6)

                        ColumnLayout {
                            id: reviewForm
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Theme.spacingM
                            anchors.rightMargin: Theme.spacingM
                            spacing: Theme.spacingS

                            Row {
                                id: reviewStarsRow
                                spacing: 2

                                // Hover previews the rating live; a click
                                // confirms it
                                property int hoverStars: 0

                                Repeater {
                                    model: 5

                                    delegate: DankIcon {
                                        required property int index

                                        readonly property int shownStars: reviewStarsRow.hoverStars > 0 ? reviewStarsRow.hoverStars : dialog.reviewStars

                                        name: "star"
                                        filled: index < shownStars
                                        size: 20
                                        color: index < shownStars ? Theme.warning : Theme.withAlpha(Theme.surfaceVariantText, 0.5)

                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onEntered: reviewStarsRow.hoverStars = index + 1
                                            onExited: {
                                                if (reviewStarsRow.hoverStars === index + 1)
                                                    reviewStarsRow.hoverStars = 0;
                                            }
                                            onClicked: dialog.reviewStars = index + 1
                                        }
                                    }
                                }
                            }

                            DankTextField {
                                id: reviewNameField
                                Layout.fillWidth: true
                                // Says what happens if it is left alone: the
                                // backend falls back to the login name, which
                                // is a thing worth knowing before you publish
                                // rather than after
                                placeholderText: Tr.t("Display name — empty publishes as \"%1\"").arg(Quickshell.env("USER") || "user")
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: Tr.t("Shown publicly with your review. Any name will do — it does not have to be the one you log in with.")
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                            }

                            DankTextField {
                                id: reviewSummaryField
                                Layout.fillWidth: true
                                placeholderText: Tr.t("Summary")
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 96
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainer
                                border.width: 1
                                border.color: Theme.withAlpha(Theme.surfaceVariantText, 0.3)

                                TextEdit {
                                    id: reviewBodyEdit
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingS
                                    wrapMode: TextEdit.Wrap
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeSmall
                                    clip: true

                                    StyledText {
                                        visible: reviewBodyEdit.text === ""
                                        text: Tr.t("Your review")
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.withAlpha(Theme.surfaceVariantText, 0.7)
                                    }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                StyledText {
                                    Layout.fillWidth: true
                                    visible: dialog.reviewStatus.indexOf("error:") === 0
                                    text: Tr.t("Review failed: %1").arg(dialog.reviewStatus.substring(6))
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.error
                                    elide: Text.ElideRight
                                }

                                Item {
                                    Layout.fillWidth: true
                                    visible: dialog.reviewStatus.indexOf("error:") !== 0
                                }

                                DankSpinner {
                                    visible: dialog.reviewStatus === "sending"
                                    size: 18
                                }

                                // Wrapper Items: DankButton sizes itself via
                                // `width`, which the RowLayout would ignore
                                Item {
                                    Layout.preferredWidth: reviewCancelButton.width
                                    Layout.preferredHeight: reviewCancelButton.height

                                    DankButton {
                                        id: reviewCancelButton
                                        buttonHeight: 26
                                        horizontalPadding: Theme.spacingM
                                        text: Tr.t("Cancel")
                                        backgroundColor: Theme.surfaceContainerHighest
                                        textColor: Theme.surfaceText
                                        onClicked: {
                                            dialog.reviewFormOpen = false;
                                            dialog.reviewStatus = "";
                                        }
                                    }
                                }

                                Item {
                                    Layout.preferredWidth: reviewSubmitButton.width
                                    Layout.preferredHeight: reviewSubmitButton.height

                                    DankButton {
                                        id: reviewSubmitButton
                                        buttonHeight: 26
                                        horizontalPadding: Theme.spacingM
                                        iconName: "send"
                                        iconSize: 13
                                        text: Tr.t("Submit")
                                        backgroundColor: Theme.buttonBg
                                        textColor: Theme.buttonText
                                        enabled: dialog.reviewStatus !== "sending" && (reviewSummaryField.text.trim() !== "" || reviewBodyEdit.text.trim() !== "")
                                        onClicked: dialog.submitReview(reviewSummaryField.text.trim(), reviewBodyEdit.text.trim(), reviewNameField.text.trim())
                                    }
                                }
                            }
                        }
                    }

                    Repeater {
                        model: (dialog.info.reviews || []).slice(0, dialog.reviewsShown)

                        delegate: Rectangle {
                            required property var modelData

                            width: bodyColumn.width
                            implicitHeight: reviewColumn.implicitHeight + Theme.spacingM
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.5)

                            ColumnLayout {
                                id: reviewColumn
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: Theme.spacingM
                                anchors.rightMargin: Theme.spacingM
                                spacing: 2

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.spacingS

                                    Row {
                                        spacing: 1

                                        Repeater {
                                            model: 5

                                            delegate: DankIcon {
                                                required property int index

                                                name: "star"
                                                filled: index < modelData.stars
                                                size: 12
                                                color: index < modelData.stars ? Theme.warning : Theme.withAlpha(Theme.surfaceVariantText, 0.4)
                                            }
                                        }
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: modelData.user + (modelData.date > 0 ? (" · " + Qt.formatDate(new Date(modelData.date * 1000), "MMM yyyy")) : "")
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                    }
                                }

                                // Summary as a clear title, body text muted
                                // underneath so the two read differently
                                StyledText {
                                    Layout.fillWidth: true
                                    visible: (modelData.summary || "") !== ""
                                    text: modelData.summary
                                    textFormat: Text.PlainText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                    wrapMode: Text.WordWrap
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    Layout.topMargin: 2
                                    visible: (modelData.text || "") !== ""
                                    text: modelData.text || ""
                                    textFormat: Text.PlainText
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                }
            }

            // ── Footer actions ──────────────────────────────────────────────
            // Anchored rows instead of a RowLayout: DankButton sizes itself
            // via `width`, which layouts ignore — anchors keep the right edge
            // exactly flush with the content above.
            Item {
                Layout.fillWidth: true
                implicitHeight: 32

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingS
                    // The busy detail in the right-hand row can grow long
                    // (download counters) — yield the space during a run
                    visible: !dialog.busy

                    DankActionButton {
                        buttonSize: 30
                        iconName: "language"
                        iconSize: 16
                        iconColor: Theme.surfaceVariantText
                        visible: (dialog.appData.homepage || "") !== ""
                        tooltipText: Tr.t("Open website — %1").arg(dialog.appData.homepage || "")
                        onClicked: Qt.openUrlExternally(dialog.appData.homepage)
                    }

                    DankActionButton {
                        buttonSize: 30
                        iconName: dialog.appData.held === true ? "lock_open" : "lock"
                        iconSize: 15
                        iconColor: dialog.appData.held === true ? Theme.warning : Theme.surfaceVariantText
                        visible: dialog.showHoldToggle
                        tooltipText: dialog.appData.held === true ? Tr.t("Stop holding (updates allowed again)") : Tr.t("Hold (skip in updates)")
                        enabled: !dialog.busy
                        onClicked: dialog.holdToggleRequested()
                    }
                }

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingS

                    DankButton {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: dialog.showOpenButton
                        buttonHeight: 30
                        horizontalPadding: Theme.spacingM
                        iconName: "launch"
                        iconSize: 14
                        text: Tr.t("Open")
                        backgroundColor: Theme.secondaryContainer
                        textColor: Theme.surfaceText
                        onClicked: {
                            Quickshell.execDetached(dialog.openCommand.length > 0 ? dialog.openCommand : ["flatpak", "run", dialog.appData.id]);
                            dialog.close();
                        }
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: dialog.busy && dialog.busyDetail !== ""
                        text: dialog.busyDetail
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.primary
                        elide: Text.ElideLeft
                        width: Math.min(implicitWidth, 260)
                    }

                    M3WaveProgress {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: dialog.busy && dialog.busyFraction > 0
                        width: 110
                        height: 18
                        value: dialog.busyFraction
                        isPlaying: visible
                    }

                    DankSpinner {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: dialog.busy && dialog.busyFraction <= 0
                        size: 22
                    }

                    Rectangle {
                        visible: dialog.installedChipVisible
                        width: installedChipText.implicitWidth + 16
                        height: 24
                        anchors.verticalCenter: parent.verticalCenter
                        radius: 12
                        color: Theme.withAlpha(Theme.success, 0.15)

                        StyledText {
                            id: installedChipText
                            anchors.centerIn: parent
                            text: Tr.t("Installed")
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.success
                        }
                    }

                    DankButton {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: dialog.showUninstall
                        buttonHeight: 30
                        horizontalPadding: Theme.spacingM
                        iconName: "delete"
                        iconSize: 14
                        text: dialog._confirmUninstall === (dialog.appData.id || "") ? Tr.t("Confirm uninstall?") : Tr.t("Uninstall")
                        backgroundColor: dialog._confirmUninstall === (dialog.appData.id || "") ? Theme.error : Theme.errorPressed
                        // On the solid error fill, pick black/white by the fill's
                        // lightness — no theme tone is guaranteed to contrast.
                        textColor: dialog._confirmUninstall === (dialog.appData.id || "") ? Ui.onColor(Theme.error) : Theme.surfaceText
                        enabled: !dialog.busy
                        onClicked: {
                            if (dialog._confirmUninstall === (dialog.appData.id || "")) {
                                dialog._confirmUninstall = "";
                                dialog.uninstallRequested();
                            } else {
                                dialog._confirmUninstall = dialog.appData.id || "";
                                confirmTimer.restart();
                            }
                        }
                    }

                    DankButton {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: dialog.showUpdateButton
                        buttonHeight: 30
                        horizontalPadding: Theme.spacingM
                        iconName: "download"
                        iconSize: 14
                        text: Tr.t("Update")
                        backgroundColor: Theme.buttonBg
                        textColor: Theme.buttonText
                        enabled: !dialog.busy
                        onClicked: dialog.updateRequested()
                    }

                    Repeater {
                        model: (dialog.showInstallButtons && !dialog.installedChipVisible) ? (dialog.appData.sources || []) : []

                        delegate: DankButton {
                            required property var modelData

                            anchors.verticalCenter: parent.verticalCenter
                            buttonHeight: 30
                            horizontalPadding: Theme.spacingM
                            iconName: "download"
                            iconSize: 14
                            // A Copr is named after the person who builds it,
                            // which is the part worth reading on the button
                            text: modelData.kind === "flatpak" ? Tr.t("Install from Flathub") : (modelData.kind === "appimage" ? Tr.t("Install AppImage") : Tr.t("Install from %1").arg(modelData.kind === "copr" ? modelData.project : Backend.systemRepoLabel))
                            backgroundColor: modelData.kind === "flatpak" ? Theme.buttonBg : Theme.secondaryContainer
                            textColor: modelData.kind === "flatpak" ? Theme.buttonText : Theme.surfaceText
                            enabled: !dialog.busy
                            onClicked: dialog.installRequested(modelData)
                        }
                    }
                }
            }

            // ── Why this is here ────────────────────────────────────────────
            // Two facts settle it: did you ask for this package, and what
            // would miss it if it went. Every package manager can answer,
            // behind a flag nobody remembers.
            StyledText {
                Layout.fillWidth: true
                visible: dialog.provenance !== null && !dialog.busy
                text: {
                    const prov = dialog.provenance;
                    if (!prov)
                        return "";
                    const origin = prov.userInstalled ? Tr.t("You installed this") : Tr.t("Came in as a dependency");
                    const count = prov.requiredByCount || 0;
                    if (count === 0)
                        return origin + " · " + Tr.t("nothing else needs it");
                    const names = (prov.requiredBy || []).slice(0, 3).join(", ");
                    return origin + " · " + (count === 1 ? Tr.t("needed by %1").arg(names) : Tr.t("needed by %1 packages, among them %2").arg(count).arg(names));
                }
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }

            // ── What else goes ──────────────────────────────────────────────
            // The resolver knows that removing one package can take others
            // with it. Until now it happened silently: the run only ever
            // showed rows for what the user picked.
            StyledText {
                Layout.fillWidth: true
                visible: dialog.showUninstall && dialog.alsoRemoves.length > 0 && !dialog.busy
                text: {
                    const names = dialog.alsoRemoves;
                    const listed = names.slice(0, 4).join(", ");
                    const rest = names.length - 4;
                    const tail = rest > 0 ? listed + Tr.t(" and %1 more").arg(rest) : listed;
                    return (names.length === 1 ? Tr.t("Uninstalling also removes %1") : Tr.t("Uninstalling also removes %1 packages: %2").arg(names.length)).arg(tail);
                }
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.warning
                wrapMode: Text.WordWrap
                maximumLineCount: 3
                elide: Text.ElideRight
            }
        }
    }
}
