import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

// Standalone updater window: the full visual experience with logos, release
// notes, per-item progress and the phase stepper. Opens as a regular
// toplevel window, independent of the bar popout.
FloatingWindow {
    id: win

    required property var store
    required property var engine
    property var firmware: null
    property var widgetRoot: null
    property bool showRuntimes: false
    property int lastUpdateUnix: 0
    property real checkFraction: 0
    property int checkElapsedSecs: 0
    property int estCheckSecs: 45

    // Bumped whenever installed software changed (install, update run);
    // the Installed tab reloads its list when this moves.
    property int softwareSerial: 0

    Connections {
        target: win.engine

        function onFinished(ok) {
            if (win.engine.completedCount > 0) {
                win.softwareSerial++;
                win._dashFetchedAt = 0;
                win.refreshDashboard();
            }
            if (win._pendingShellNames.length > 0) {
                const shellNames = win._pendingShellNames;
                win._pendingShellNames = [];
                win._daemonUpgradeOnly(shellNames);
            }
        }
    }

    // ── Details popup for Updates-tab cards ─────────────────────────────────
    function openUpdateDetails(rowData, info) {
        const pkg = rowData.pkg || {};
        const isFirmware = pkg.repo === "firmware";
        const isFlatpak = pkg.repo === "flatpak";
        const base = win.store.stripArch(pkg.name || "");
        const newer = (info && info.releases) ? info.releases.filter(r => r.newer && (r.notesHtml || r.version)).slice(0, 5) : [];
        if (!isFlatpak && !isFirmware && newer.length === 0)
            win.store.fetchChangelog(base);
        updatesDialog.rowData = rowData;
        updatesDialog.releases = newer;
        let versionLabel = pkg.toVersion || "";
        if (pkg.fromVersion && pkg.toVersion)
            versionLabel = pkg.fromVersion + " → " + pkg.toVersion;
        updatesDialog.open({
            id: isFlatpak ? pkg.name : base,
            name: win.store.displayName(pkg),
            summary: (info && info.summary) || "",
            iconPath: (info && info.icon) || "",
            homepage: (info && info.homepage) || "",
            held: rowData.ignored === true || win.store.isHeld(pkg),
            holdReason: rowData.ignored === true ? Tr.t("held by you") : win.store.holdReason(pkg),
            versionLabel: versionLabel,
            origin: isFirmware ? "Firmware" : (isFlatpak ? "Flatpak" : "System"),
            isFlatpak: isFlatpak,
            sources: isFirmware ? [] : (isFlatpak ? [{
                source: "flathub",
                kind: "flatpak",
                ref: pkg.name
            }] : [{
                source: "fedora",
                kind: "dnf",
                ref: base
            }])
        });
    }

    AppDetailsDialog {
        id: updatesDialog

        property var rowData: null
        readonly property var rowPkg: rowData ? rowData.pkg : null
        readonly property bool rowIsRpm: rowPkg !== null && rowPkg.repo !== "flatpak" && rowPkg.repo !== "firmware"
        readonly property string rowBase: rowPkg ? win.store.stripArch(rowPkg.name || "") : ""

        releasesTitle: Tr.t("What's new")
        changelogLoading: rowIsRpm && releases.length === 0 && win.store.changelogs[rowBase] === undefined
        changelog: (rowIsRpm && releases.length === 0) ? (win.store.changelogs[rowBase] || "") : ""
        showHoldToggle: {
            if (!rowData)
                return false;
            if (rowData.ignored === true)
                return true;
            if (!rowPkg || rowPkg.repo === "firmware" || win.store.isHeld(rowPkg))
                return false;
            return SystemUpdateService.canIgnorePackage(rowPkg);
        }
        showUpdateButton: rowPkg !== null && rowPkg.repo === "flatpak" && !win.engine.running && win.singleBusyKey === "" && (rowData.ignored !== true)
        busy: {
            if (!rowPkg || !win.engine.running)
                return false;
            const state = win.engine.stateFor(rowPkg);
            return state !== null && state.status === "active";
        }

        onUpdateRequested: {
            const target = rowData;
            close();
            win.runSingleUpdate(target);
        }

        onHoldToggleRequested: {
            if (rowData.ignored === true) {
                SystemUpdateService.unignorePackage(rowPkg.name);
            } else {
                SystemUpdateService.ignorePackage(rowPkg.name);
            }
            close();
        }
    }

    // Manually update one pending item. Flatpaks and AppImages go through
    // the engine; firmware runs its own privileged command.
    property string singleBusyKey: ""

    // Upgrade ONLY the given rpm names, through the daemon: every other
    // pending rpm goes into this run's ignored list. Used for DMS/Quickshell
    // packages — the daemon finishes the transaction even when the shell
    // reloads mid-way (a plain pkexec child would be killed with the shell).
    function _daemonUpgradeOnly(rawNames) {
        const wanted = new Set(rawNames);
        const ignored = (SettingsData.updaterIgnoredPackages || []).slice();
        for (const pkg of win.pendingUpdates) {
            if (pkg.repo !== "flatpak" && !wanted.has(pkg.name))
                ignored.push(pkg.name);
        }
        // This pass has no completion hook (the shell reloads on dms
        // updates) — stash the log entry for replay at the next start
        if (widgetRoot)
            widgetRoot._stashShellRunLog(win.pendingUpdates.filter(p => p.repo !== "flatpak" && wanted.has(p.name)), []);
        DMSService.sysupdateUpgrade({
            includeFlatpak: false,
            ignored: ignored
        }, null);
    }

    function _isShellPkg(pkg) {
        return pkg.repo !== "flatpak" && pkg.repo !== "firmware" && engine.shellPackagePattern.test(store.stripArch(pkg.name));
    }

    function runSingleUpdate(rowData) {
        if (engine.running || engine.deferred || singleUpdateProcess.running)
            return;
        const pkg = rowData.pkg || {};
        if (pkg.repo === "appimage") {
            engine.start({
                dnf: false,
                flatpak: false,
                firmware: false,
                appimageIds: [pkg.name]
            });
            return;
        }
        if (pkg.repo === "flatpak") {
            engine.start({
                dnf: false,
                firmware: false,
                flatpak: true,
                flatpakIds: [pkg.name]
            });
            return;
        }
        if (_isShellPkg(pkg)) {
            _daemonUpgradeOnly([pkg.name]);
            return;
        }
        if (pkg.repo === "firmware" && rowData.fwInfo && rowData.fwInfo.deviceId) {
            singleBusyKey = rowData.key;
            singleUpdateProcess._label = store.displayName(pkg);
            singleUpdateProcess.command = ["fwupdmgr", "update", "-y", "--no-reboot-check", rowData.fwInfo.deviceId];
            singleUpdateProcess.running = true;
        }
    }

    property var _pendingShellNames: []

    // Last output line of the manual pass, shown in the progress strip
    property string singleUpdateStatus: ""

    Process {
        id: singleUpdateProcess

        property string _label: ""
        property int _count: 1
        property var _thenFlatpakIds: []
        property var _thenAppimageIds: []

        stdout: SplitParser {
            onRead: line => {
                const trimmed = line.trim();
                if (trimmed !== "")
                    win.singleUpdateStatus = trimmed;
            }
        }

        onExited: (exitCode, exitStatus) => {
            win.singleBusyKey = "";
            win.singleUpdateStatus = "";
            if (exitCode === 0 && win.widgetRoot && win.widgetRoot.actionLogger) {
                win.widgetRoot.actionLogger.record("update", (_count === 1 ? Tr.t("Updated %1 package") : Tr.t("Updated %1 packages")).arg(_count), [{
                    name: _label,
                    from: "",
                    to: "",
                    source: "System",
                    status: exitCode === 0 ? "done" : "error"
                }]);
            }
            _count = 1;
            const pending = _thenFlatpakIds || [];
            const pendingAi = _thenAppimageIds || [];
            _thenFlatpakIds = [];
            _thenAppimageIds = [];
            if ((pending.length > 0 || pendingAi.length > 0) && !win.engine.running) {
                win.engine.start({
                    dnf: false,
                    firmware: false,
                    flatpak: pending.length > 0,
                    flatpakIds: pending,
                    appimageIds: pendingAi
                });
            } else if (win._pendingShellNames.length > 0) {
                const shellNames = win._pendingShellNames;
                win._pendingShellNames = [];
                win._daemonUpgradeOnly(shellNames);
            } else {
                SystemUpdateService.checkForUpdates();
            }
        }
    }

    // Ctrl+F puts the caret in the current tab's search field
    Shortcut {
        sequences: [StandardKey.Find]
        enabled: win.visible
        onActivated: win.focusCurrentTab()
    }

    // Full-window layer that hosts the view-local detail popups, so their
    // dim overlay covers the entire window instead of just the tab area.
    Item {
        id: windowOverlayLayer
        anchors.fill: parent
        z: 150
    }

    // ── About popup (info icon in the header) ───────────────────────────────
    property bool aboutOpen: false
    property var pluginManifest: ({})
    readonly property string githubUrl: "https://github.com/vinceecniv/DankSoftwareDepot"

    FileView {
        path: Qt.resolvedUrl("plugin.json")

        onLoaded: {
            try {
                win.pluginManifest = JSON.parse(text());
            } catch (e) {
            }
        }
    }

    onAboutOpenChanged: {
        if (aboutOpen)
            aboutFocus.forceActiveFocus();
    }

    // ── Self-update: offer a newer plugin release published on GitHub ───────
    // Compares the version in main's plugin.json with the installed one and
    // shows a banner with the CHANGELOG section for the new version. The
    // update itself runs detached (`dms plugins update` + shell reload)
    // because the reload kills this process tree.
    property string selfUpdateVersion: ""
    property string selfUpdateNotes: ""
    property bool selfUpdateBusy: false
    // Dismissed via the banner's X: stays hidden until a yet newer version
    // appears (persisted in pluginData)
    readonly property string selfUpdateDismissedVersion: (widgetRoot && widgetRoot.pluginData) ? (widgetRoot.pluginData.selfUpdateDismissedVersion || "") : ""

    function _versionNewer(remote, local) {
        const a = String(remote).split(".").map(n => parseInt(n, 10) || 0);
        const b = String(local).split(".").map(n => parseInt(n, 10) || 0);
        for (let i = 0; i < Math.max(a.length, b.length); i++) {
            const d = (a[i] || 0) - (b[i] || 0);
            if (d !== 0)
                return d > 0;
        }
        return false;
    }

    function _changelogSection(md, version) {
        const lines = md.split("\n");
        const out = [];
        let inSection = false;
        for (const line of lines) {
            if (line.indexOf("## ") === 0) {
                if (inSection)
                    break;
                inSection = line.indexOf(version) !== -1;
                continue;
            }
            if (inSection)
                out.push(line);
        }
        return out.join("\n").trim();
    }

    Timer {
        interval: 30 * 1000
        running: true
        onTriggered: selfUpdateProcess.running = true
    }

    Timer {
        interval: 24 * 3600 * 1000
        running: true
        repeat: true
        onTriggered: selfUpdateProcess.running = true
    }

    Process {
        id: selfUpdateProcess

        // Exit 3 on a symlinked (development) install: never self-update a
        // working copy.
        command: ["sh", "-c", "dir=\"$HOME/.config/DankMaterialShell/plugins/dankSoftwareDepot\"; [ -L \"$dir\" ] && exit 3; curl -sf --max-time 15 " + win.githubUrl.replace("github.com", "raw.githubusercontent.com") + "/main/plugin.json; echo; echo ---NOTES---; curl -sf --max-time 15 " + win.githubUrl.replace("github.com", "raw.githubusercontent.com") + "/main/CHANGELOG.md"]

        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.split("---NOTES---");
                let remote = null;
                try {
                    remote = JSON.parse(parts[0]);
                } catch (e) {
                    return;
                }
                const localVersion = win.pluginManifest.version || "0";
                if (!remote || !remote.version || !win._versionNewer(remote.version, localVersion))
                    return;
                win.selfUpdateVersion = remote.version;
                win.selfUpdateNotes = win._changelogSection(parts[1] || "", remote.version);
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        visible: win.aboutOpen
        z: 90
        color: Qt.rgba(0, 0, 0, 0.45)

        MouseArea {
            anchors.fill: parent
            onClicked: win.aboutOpen = false
            onWheel: wheel => wheel.accepted = true
        }

        Item {
            id: aboutFocus
            Keys.onEscapePressed: win.aboutOpen = false
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(420, parent.width - Theme.spacingL * 2)
            height: aboutColumn.implicitHeight + Theme.spacingL * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainer
            border.width: 1
            border.color: Theme.withAlpha(Theme.surfaceVariantText, 0.25)

            MouseArea {
                anchors.fill: parent
            }

            // Anchored to the card so it is always in the top-right corner,
            // independent of how the header row lays out
            DankActionButton {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: Theme.spacingS
                buttonSize: 30
                iconName: "close"
                iconSize: 18
                iconColor: Theme.surfaceVariantText
                onClicked: win.aboutOpen = false
            }

            ColumnLayout {
                id: aboutColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingM

                    Image {
                        Layout.preferredWidth: 40
                        Layout.preferredHeight: 40
                        source: win.appIconSource
                        sourceSize.width: 80
                        sourceSize.height: 80
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        StyledText {
                            text: "Dank Software Depot"
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        StyledText {
                            text: Tr.t("Version %1 (beta)").arg(win.pluginManifest.version || "?")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    text: win.pluginManifest.description ? Tr.t(win.pluginManifest.description) : ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("Supports %1 packages, Flatpak and AppImage.").arg(Backend.systemRepoLabel)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                // Update notice: About is opened deliberately, so this shows
                // whenever a newer version exists — also after the banner in
                // the Updates tab was dismissed
                Rectangle {
                    Layout.fillWidth: true
                    visible: win.selfUpdateVersion !== ""
                    implicitHeight: aboutUpdateColumn.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.primary, 0.10)
                    border.width: 1
                    border.color: Theme.withAlpha(Theme.primary, 0.30)

                    ColumnLayout {
                        id: aboutUpdateColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacingM
                        anchors.rightMargin: Theme.spacingM
                        spacing: Theme.spacingS

                        StyledText {
                            Layout.fillWidth: true
                            textFormat: Text.StyledText
                            text: Tr.t("Dank Software Depot %1 is available").arg("<b>" + win.selfUpdateVersion + "</b>")
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            wrapMode: Text.WordWrap
                        }

                        Item {
                            Layout.preferredWidth: aboutUpdateButton.width
                            Layout.preferredHeight: aboutUpdateButton.height

                            DankButton {
                                id: aboutUpdateButton
                                buttonHeight: 30
                                iconName: "download"
                                iconSize: 14
                                horizontalPadding: Theme.spacingM
                                enabled: !win.selfUpdateBusy
                                text: win.selfUpdateBusy ? Tr.t("Updating…") : Tr.t("Update and reload shell")
                                backgroundColor: Theme.buttonBg
                                textColor: Theme.buttonText
                                onClicked: {
                                    win.selfUpdateBusy = true;
                                    Quickshell.execDetached(["sh", "-c", "dms plugins update dankSoftwareDepot && dms restart"]);
                                }
                            }
                        }
                    }
                }

                StyledText {
                    text: Tr.t("By %1 · MIT license").arg(win.pluginManifest.author || "") + " · " + Tr.t("requires DMS %1").arg(win.pluginManifest.requires_dms || "")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    text: Tr.t("Developed with Claude Code")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                // Wrapper Item: DankButton sizes itself via `width`, which a
                // ColumnLayout ignores — anchoring keeps its natural width.
                Item {
                    Layout.fillWidth: true
                    implicitHeight: 32

                    DankButton {
                        anchors.left: parent.left
                        buttonHeight: 32
                        iconName: "open_in_new"
                        iconSize: 15
                        horizontalPadding: Theme.spacingM
                        text: Tr.t("Open GitHub page")
                        backgroundColor: Theme.buttonBg
                        textColor: Theme.buttonText
                        onClicked: Qt.openUrlExternally(win.githubUrl)
                    }
                }
            }
        }
    }

    // ── Plugin settings popup (gear icon in the header) ─────────────────────
    property bool settingsOpen: false

    onSettingsOpenChanged: {
        if (settingsOpen)
            settingsFocus.forceActiveFocus();
    }

    Rectangle {
        anchors.fill: parent
        visible: win.settingsOpen
        z: 90
        color: Qt.rgba(0, 0, 0, 0.45)

        MouseArea {
            anchors.fill: parent
            onClicked: win.settingsOpen = false
            onWheel: wheel => wheel.accepted = true
        }

        Item {
            id: settingsFocus
            Keys.onEscapePressed: win.settingsOpen = false
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(480, parent.width - Theme.spacingL * 2)
            height: Math.min(settingsHeaderRow.implicitHeight + settingsScrollColumn.implicitHeight + Theme.spacingM + Theme.spacingL * 2, parent.height - Theme.spacingL * 2)
            radius: Theme.cornerRadius
            color: Theme.surfaceContainer
            border.width: 1
            border.color: Theme.withAlpha(Theme.surfaceVariantText, 0.25)

            MouseArea {
                anchors.fill: parent
            }

            ColumnLayout {
                id: settingsColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                RowLayout {
                    id: settingsHeaderRow
                    Layout.fillWidth: true

                    DankIcon {
                        name: "settings"
                        size: 20
                        color: Theme.surfaceText
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: Tr.t("Plugin settings")
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                    }

                    DankActionButton {
                        buttonSize: 30
                        iconName: "close"
                        iconSize: 18
                        iconColor: Theme.surfaceVariantText
                        onClicked: win.settingsOpen = false
                    }
                }

                // Everything below the header scrolls when the window is
                // shorter than the settings content
                Flickable {
                    id: settingsScroll
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentWidth: width
                    contentHeight: settingsScrollColumn.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: settingsScrollColumn
                        width: settingsScroll.width
                        spacing: Theme.spacingM

                    // Plain Column: DankToggle sizes itself via `height` (its
                    // implicitHeight stays 0), which a ColumnLayout would ignore —
                    // stacking by actual height keeps wrapped descriptions apart.
                    Column {
                        Layout.fillWidth: true
                        spacing: Theme.spacingS

                        DankToggle {
                            width: parent.width
                            text: Tr.t("Hide when up to date")
                            description: Tr.t("Hide the bar pill while there are no pending updates.")
                            checked: win.widgetRoot ? win.widgetRoot.hideWhenUpToDate : false
                            onToggled: checked => PluginService.savePluginData("dankSoftwareDepot", "hideWhenUpToDate", checked)
                        }

                        DankToggle {
                            width: parent.width
                            text: Tr.t("Show runtimes and extensions")
                            description: Tr.t("List Flatpak runtimes, locales and codec extensions. They are always included in Update All.")
                            checked: win.widgetRoot ? win.widgetRoot.showRuntimes : false
                            onToggled: checked => PluginService.savePluginData("dankSoftwareDepot", "showRuntimes", checked)
                        }

                        DankToggle {
                            width: parent.width
                            text: Tr.t("Include firmware updates")
                            description: Tr.t("Check for device firmware updates via fwupd (LVFS) and include them in Update All.")
                            checked: win.widgetRoot ? win.widgetRoot.includeFirmware : true
                            onToggled: checked => PluginService.savePluginData("dankSoftwareDepot", "includeFirmware", checked)
                        }

                        DankToggle {
                            width: parent.width
                            text: Tr.t("Confirm before updating")
                            description: Tr.t("Require a second click on Update All before the run starts.")
                            checked: win.widgetRoot ? win.widgetRoot.confirmBeforeUpdate : false
                            onToggled: checked => PluginService.savePluginData("dankSoftwareDepot", "confirmBeforeUpdate", checked)
                        }

                        DankToggle {
                            width: parent.width
                            text: Tr.t("Bar click opens window")
                            description: Tr.t("Open this window instead of the compact popout when clicking the bar pill.")
                            checked: win.widgetRoot ? win.widgetRoot.pillOpensWindow : false
                            onToggled: checked => PluginService.savePluginData("dankSoftwareDepot", "pillOpensWindow", checked)
                        }

                        DankDropdown {
                            readonly property var autoMap: ({
                                    "Off": "off",
                                    "Notify only": "notify",
                                    "Auto-install Flatpaks": "auto"
                                })

                            width: parent.width
                            text: Tr.t("Automatic updates")
                            description: Tr.t("Notify when updates are found, and optionally install Flatpak updates automatically. System packages always ask first.")
                            options: Object.keys(autoMap).map(k => Tr.t(k))
                            currentValue: {
                                const mode = win.widgetRoot ? win.widgetRoot.autoUpdateMode : "notify";
                                for (const label in autoMap) {
                                    if (autoMap[label] === mode)
                                        return Tr.t(label);
                                }
                                return Tr.t("Off");
                            }
                            onValueChanged: value => {
                                for (const label in autoMap) {
                                    if (Tr.t(label) === value) {
                                        PluginService.savePluginData("dankSoftwareDepot", "autoUpdateMode", autoMap[label]);
                                        return;
                                    }
                                }
                            }
                        }
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: Tr.t("Check interval and ignored packages are managed in DMS Settings → System Updater.")
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }

                    Item {
                        Layout.preferredWidth: dmsSettingsLinkButton.width
                        Layout.preferredHeight: dmsSettingsLinkButton.height

                        DankButton {
                            id: dmsSettingsLinkButton
                            buttonHeight: 30
                            horizontalPadding: Theme.spacingM
                            iconName: "open_in_new"
                            iconSize: 14
                            text: Tr.t("Open DMS System Updater settings")
                            backgroundColor: Theme.secondaryContainer
                            textColor: Theme.surfaceText
                            onClicked: {
                                win.settingsOpen = false;
                                PopoutService.openSettingsWithTab("updater");
                            }
                        }
                    }
                    }
                }
            }
        }
    }

    // Refresh relative timestamps once a minute while the window is open
    property int nowUnix: Math.floor(Date.now() / 1000)

    Timer {
        interval: 60000
        running: win.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: win.nowUnix = Math.floor(Date.now() / 1000)
    }

    function formatAgo(unix) {
        if (!unix)
            return "";
        const delta = Math.max(0, nowUnix - unix);
        if (delta < 90)
            return Tr.t("just now");
        if (delta < 3600)
            return Tr.t("%1m ago").arg(Math.round(delta / 60));
        if (delta < 86400)
            return Tr.t("%1h ago").arg(Math.round(delta / 3600));
        return Tr.t("%1d ago").arg(Math.round(delta / 86400));
    }

    title: "Dank Software Depot"
    minimumSize: Qt.size(560, 420)
    implicitWidth: 760
    implicitHeight: 640
    color: Theme.surface
    visible: false

    // A compositor-side close (Super+Q) kills the toplevel without updating
    // our visible flag, so the next `visible = true` becomes a no-op and the
    // window can never reopen. Resync on close.
    onClosed: visible = false

    function toggle() {
        visible = !visible;
    }

    // Dashboard shows whenever nothing is actionable — including when only
    // held updates remain (those don't count as out-of-date)
    readonly property bool dashboardMode: !showingRun && effectiveCount === 0

    // Collapsible sections (collapsed by default). A long run finishes far
    // more packages than it is working on; leaving that pile open would push
    // the active rows off screen, which is the opposite of the point.
    property var collapsedCats: ({
            "5 · Held packages": true,
            "3 · Completed": true
        })

    function toggleCategory(category) {
        const updated = Object.assign({}, collapsedCats);
        updated[category] = !updated[category];
        collapsedCats = updated;
    }

    // Own app icon, following the active light/dark theme
    readonly property url appIconSource: Qt.resolvedUrl("assets/icons/dank-software-depot-" + (Theme.isLightMode ? "light" : "dark") + ".svg")

    // ── Dashboard data (up-to-date empty state) ─────────────────────────────
    property var dashboard: null
    property double _dashFetchedAt: 0

    function refreshDashboard() {
        const now = Date.now();
        if (now - _dashFetchedAt < 60 * 1000 || dashboardProcess.running)
            return;
        _dashFetchedAt = now;
        dashboardProcess.command = ["python3", Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", ""), "--dashboard"];
        dashboardProcess.running = true;
    }

    Process {
        id: dashboardProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    win.dashboard = JSON.parse(text);
                } catch (e) {
                }
            }
        }
    }

    // ── OS compatibility: dnf-based features assume a Fedora-family distro.
    // Non-empty when running on anything whose os-release ID/ID_LIKE lacks
    // "fedora"; holds the distro's pretty name for the warning banner.
    property string osIncompatiblePretty: ""

    Process {
        id: osCheckProcess
        running: true
        command: ["sh", "-c", ". /etc/os-release 2>/dev/null; echo \"$ID $ID_LIKE|$PRETTY_NAME\""]

        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split("|");
                const ids = (parts[0] || "").toLowerCase().split(/\s+/).filter(t => t !== "");
                const supported = ["fedora", "debian", "ubuntu", "arch", "manjaro"].some(id => ids.indexOf(id) >= 0);
                win.osIncompatiblePretty = (ids.length > 0 && !supported) ? ((parts[1] || "").trim() || parts[0].trim()) : "";
            }
        }
    }

    function formatUptime(secs) {
        if (secs <= 0)
            return "";
        const days = Math.floor(secs / 86400);
        const hours = Math.floor((secs % 86400) / 3600);
        const mins = Math.floor((secs % 3600) / 60);
        if (days > 0)
            return days + "d " + hours + "h";
        if (hours > 0)
            return hours + "h " + mins + "m";
        return mins + "m";
    }

    // Fresh start on reopen: whenever the window opens (after having been
    // closed) it shows the Updates tab. openTab() runs after this and can
    // still select a specific tab explicitly.
    onVisibleChanged: {
        if (visible) {
            tabs.currentIndex = 0;
            refreshDashboard();
        }
    }

    // The same after sitting unused: an open but unfocused window falls back
    // to the Updates tab after a few minutes.
    Timer {
        interval: 3 * 60 * 1000
        running: win.visible && win.active === false
        onTriggered: tabs.currentIndex = 0
    }

    // ── Which tabs exist ────────────────────────────────────────────────────
    // Firmware is a setting, and a tab for something the user switched off is
    // just a dead end. Hiding it makes the bar's positions stop matching the
    // tab numbers, so everything else speaks in stable ids and only the bar
    // itself works in positions.
    readonly property bool firmwareEnabled: firmware !== null
    readonly property var tabIds: firmwareEnabled ? [0, 1, 2, 3, 4] : [0, 1, 2, 4]
    readonly property int currentTab: tabIds[Math.min(tabs.currentIndex, tabIds.length - 1)]

    // Switching firmware off while looking at it would silently land you on
    // whatever slid into that position — go somewhere deliberate instead
    onFirmwareEnabledChanged: {
        if (!firmwareEnabled && tabs.currentIndex >= tabIds.length)
            tabs.currentIndex = 0;
    }

    function openTab(id) {
        visible = true;
        const position = tabIds.indexOf(id);
        if (position === -1)
            return;
        tabs.currentIndex = position;
        if (id === 1)
            installedLoader.active = true;
        if (id === 2)
            installLoader.active = true;
        if (id === 3)
            firmwareLoader.active = true;
        if (id === 4)
            logLoader.active = true;
        focusCurrentTab();
    }

    // Jump from a finished run to its own entry in the log, where the full
    // per-package detail and the tools' own words live.
    function openLatestLogEntry() {
        openTab(4);
        Qt.callLater(() => {
            if (logLoader.item)
                logLoader.item.expandNewest();
        });
    }

    // Move keyboard focus into the freshly shown tab; tabs with a search
    // field get input focus on that field directly.
    function focusCurrentTab() {
        Qt.callLater(() => {
            switch (win.currentTab) {
            case 1:
                if (installedLoader.item)
                    installedLoader.item.focusSearch();
                break;
            case 2:
                if (installLoader.item)
                    installLoader.item.focusSearch();
                break;
            case 3:
                if (firmwareLoader.item)
                    firmwareLoader.item.focusSearch();
                break;
            case 4:
                if (logLoader.item)
                    logLoader.item.focusSearch();
                break;
            default:
                cardsList.forceActiveFocus();
                break;
            }
        });
    }

    function classify(pkg) {
        if (pkg.repo === "appimage")
            return "1 · Applications";
        if (pkg.repo === "firmware")
            return "4 · Firmware";
        if (pkg.repo !== "flatpak")
            return store.isHeld(pkg) ? "5 · Held packages" : "2 · System packages";
        const name = pkg.name || "";
        const runtime = /\.(Locale|Debug|Sources)$/.test(name)
            || /\.(Platform|Sdk)($|\.)/.test(name)
            || name.indexOf(".GL.") !== -1
            || name.indexOf(".VAAPI.") !== -1
            || name.indexOf(".codecs") !== -1
            || name.indexOf(".ffmpeg") !== -1;
        return runtime ? "3 · Runtimes & extensions" : "1 · Applications";
    }

    function _guessRepo(name) {
        return (name || "").split(".").length >= 3 ? "flatpak" : "system";
    }

    function _sortRows(rows) {
        rows.sort((a, b) => {
            if (a.category !== b.category)
                return a.category < b.category ? -1 : 1;
            // Among finished rows the failures go first — they are the ones
            // still asking something of you (no-op outside a run)
            const failedA = a.failed ? 0 : 1;
            const failedB = b.failed ? 0 : 1;
            if (failedA !== failedB)
                return failedA - failedB;
            const nameA = (store.meta[a.key] && store.meta[a.key].name) || a.pkg.name;
            const nameB = (store.meta[b.key] && store.meta[b.key].name) || b.pkg.name;
            return nameA.localeCompare(nameB);
        });
        return rows;
    }

    // Pending updates: live service data, or the widget's persisted snapshot
    // right after a restart (until the daemon has state again)
    readonly property var pendingUpdates: widgetRoot ? widgetRoot.pendingUpdates : (SystemUpdateService.availableUpdates || [])

    // Live list of pending updates (idle view)
    readonly property var updateRows: {
        const updates = win.pendingUpdates;
        const seen = new Set();
        const rows = [];
        for (const pkg of updates) {
            const key = store.keyFor(pkg);
            if (seen.has(key))
                continue;
            seen.add(key);
            const category = classify(pkg);
            if (!showRuntimes && category === "3 · Runtimes & extensions")
                continue;
            rows.push({
                pkg: pkg,
                key: key,
                category: category,
                ignored: false
            });
        }
        for (const fw of (firmware ? firmware.updates : []) || []) {
            rows.push({
                pkg: {
                    name: fw.name,
                    repo: "firmware",
                    fromVersion: fw.current,
                    toVersion: fw.next
                },
                key: "firmware/" + fw.name,
                category: "4 · Firmware",
                ignored: false,
                fwInfo: fw
            });
        }
        for (const ai of (widgetRoot ? widgetRoot.appimageUpdates : []) || []) {
            rows.push({
                pkg: {
                    name: ai.id,
                    displayName: ai.name,
                    repo: "appimage",
                    fromVersion: ai.current,
                    toVersion: ai.latest
                },
                key: "appimage/" + ai.id,
                category: "1 · Applications",
                ignored: false,
                aiInfo: ai
            });
        }
        for (const name of SettingsData.updaterIgnoredPackages || []) {
            const repo = _guessRepo(name);
            const pkg = {
                name: name,
                repo: repo,
                fromVersion: "",
                toVersion: ""
            };
            rows.push({
                pkg: pkg,
                key: store.keyFor(pkg),
                category: "5 · Held packages",
                ignored: true
            });
        }
        return _sortRows(rows);
    }

    // Snapshot of the running/finished run: keeps every queued item visible
    // with its own state (queued / downloading / installing / done / failed),
    // even while the daemon refreshes the live list mid-run.
    // During a run the list regroups by what is happening to each package
    // rather than by what kind of package it is. Sorted by source, the few
    // rows actually being worked on sit scattered among hundreds of queued
    // ones; grouped by state, they are the first thing on screen.
    readonly property var runRows: {
        const rows = [];
        for (const item of engine.runItems || []) {
            const state = engine.itemStates[item.key] || null;
            const status = state ? state.status : "pending";
            let category = "2 · Waiting";
            if (status === "active")
                category = "1 · In progress";
            else if (status === "done" || status === "error")
                category = "3 · Completed";
            rows.push({
                pkg: item.pkg,
                key: item.key,
                category: category,
                ignored: false,
                failed: status === "error"
            });
        }
        return _sortRows(rows);
    }

    readonly property bool showingRun: engine.phase !== "idle" && runRows.length > 0
    readonly property var visibleRows: {
        if (!showingRun)
            return updateRows;
        // The run view focuses on the live queue, but held updates that sit
        // out this run shouldn't vanish from the overview — keep their
        // section below the queue.
        const runKeys = new Set(runRows.map(row => row.key));
        return runRows.concat(updateRows.filter(row => row.category === "5 · Held packages" && !runKeys.has(row.key)));
    }

    // Flat list model with explicit header rows. This sidesteps ListView's
    // section attachment (which mis-assigned headers) and lets headers carry
    // their own hover actions.
    readonly property var listModel: {
        const counts = {};
        for (const row of visibleRows)
            counts[row.category] = (counts[row.category] || 0) + 1;
        const collapsible = ["5 · Held packages", "3 · Completed"];
        const out = [];
        let current = "";
        for (const row of visibleRows) {
            if (row.category !== current) {
                current = row.category;
                out.push({
                    type: "header",
                    category: current,
                    title: Tr.t(current.substring(4)),
                    count: counts[current] || 0,
                    collapsible: collapsible.indexOf(current) !== -1,
                    collapsed: collapsible.indexOf(current) !== -1 && collapsedCats[current] === true
                });
            }
            if (collapsible.indexOf(row.category) !== -1 && collapsedCats[row.category] === true)
                continue;
            out.push(Object.assign({
                type: "card"
            }, row));
        }
        return out;
    }

    // Whether the footer has anything to offer. "Deferred" counts as busy:
    // the click already committed a run and is waiting on the pre-run check,
    // so the button flips to Cancel immediately. Between a finished run and
    // its trailing check the stale list would re-offer Update All for a few
    // seconds — that window is suppressed.
    readonly property bool updateAllBusy: engine.running || engine.deferred
    readonly property bool showUpdateAll: {
        if (updateAllBusy)
            return true;
        const settling = engine.phase !== "idle" && SystemUpdateService.isChecking;
        return effectiveCount > 0 && !settling;
    }

    // Section headers carry the same iconography the rows use, so a group is
    // recognisable before its title is read. The run groups say what is
    // happening; the idle sections say what kind of software it is.
    function categoryIcon(category) {
        switch (category) {
        case "1 · In progress":
            return "sync";
        case "2 · Waiting":
            return "schedule";
        case "3 · Completed":
            return "check_circle";
        case "2 · System packages":
            return "memory";
        case "3 · Runtimes & extensions":
            return "extension";
        case "4 · Firmware":
            return "developer_board";
        case "5 · Held packages":
            return "lock";
        default:
            return "apps";
        }
    }

    function categoryColor(category) {
        switch (category) {
        case "2 · Waiting":
            return Theme.surfaceVariantText;
        case "3 · Completed":
            return Theme.success;
        case "5 · Held packages":
            return Theme.warning;
        default:
            return Theme.primary;
        }
    }

    function sectionUpdate(category) {
        if (engine.running)
            return;
        if (category === "2 · System packages") {
            engine.start({
                flatpak: false,
                firmware: false
            });
            return;
        }
        if (category === "4 · Firmware") {
            engine.start({
                dnf: false,
                flatpak: false
            });
            return;
        }
        const ids = visibleRows.filter(row => row.category === category && row.pkg.repo === "flatpak").map(row => row.pkg.name);
        const aiIds = visibleRows.filter(row => row.category === category && row.pkg.repo === "appimage").map(row => row.pkg.name);
        if (ids.length > 0 || aiIds.length > 0)
            engine.start({
                dnf: false,
                firmware: false,
                flatpak: ids.length > 0,
                appimageIds: aiIds,
                flatpakIds: ids
            });
    }

    // Effective pending count: held packages don't count as real updates
    // Follows the widget's count (held excluded)
    readonly property int effectiveCount: {
        if (widgetRoot)
            return widgetRoot.effectiveCount;
        const updates = win.pendingUpdates;
        return updates.filter(pkg => !store.isHeld(pkg)).length + ((firmware ? firmware.updates : []) || []).length;
    }

    readonly property int hiddenRuntimeCount: {
        const updates = win.pendingUpdates;
        if (showRuntimes)
            return 0;
        return updates.filter(pkg => classify(pkg) === "3 · Runtimes & extensions").length;
    }

    function lastCheckedText() {
        const ago = formatAgo(SystemUpdateService.lastCheckUnix);
        return ago ? Tr.t("checked %1").arg(ago) : "";
    }

    function formatIn(unix) {
        if (!unix)
            return "";
        const delta = unix - nowUnix;
        if (delta <= 0)
            return Tr.t("soon");
        if (delta < 3600)
            return Tr.t("in %1m").arg(Math.max(1, Math.round(delta / 60)));
        return Tr.t("in %1h").arg(Math.round(delta / 3600));
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacingL
        spacing: Theme.spacingM

        // ── Header (anchors: buttons pinned to the right edge) ──────────────
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 44

            Image {
                id: headerLogo
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: 40
                height: 40
                source: win.appIconSource
                sourceSize.width: 80
                sourceSize.height: 80
                fillMode: Image.PreserveAspectFit
                asynchronous: true
            }

            Column {
                anchors.left: headerLogo.right
                anchors.leftMargin: Theme.spacingM
                anchors.right: headerButtons.left
                anchors.rightMargin: Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                StyledText {
                    width: parent.width
                    text: "Dank Software Depot"
                    font.pixelSize: Theme.fontSizeXLarge
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }

                StyledText {
                    width: parent.width
                    text: {
                        let countText;
                        if (win.engine.running)
                            countText = Tr.t("updating…");
                        else if (SystemUpdateService.isChecking)
                            countText = Tr.t("checking…");
                        else if (win.effectiveCount === 0)
                            countText = Tr.t("up to date");
                        else
                            countText = (win.effectiveCount === 1 ? Tr.t("%1 update") : Tr.t("%1 updates")).arg(win.effectiveCount);
                        const checked = win.lastCheckedText();
                        return countText + (checked ? " · " + checked : "");
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    elide: Text.ElideRight
                }
            }

            Row {
                id: headerButtons
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                DankActionButton {
                    id: windowRefreshButton
                    buttonSize: 36
                    iconName: "refresh"
                    iconSize: 20
                    iconColor: Theme.surfaceText
                    enabled: !SystemUpdateService.isChecking && !win.engine.running
                    opacity: enabled ? 1 : 0.4
                    tooltipText: Tr.t("Check for updates")
                    onClicked: {
                        SystemUpdateService.checkForUpdates();
                        if (win.firmware)
                            win.firmware.check();
                    }

                    RotationAnimator on rotation {
                        from: 0
                        to: 360
                        duration: 1000
                        loops: Animation.Infinite
                        running: SystemUpdateService.isChecking

                        onRunningChanged: {
                            if (!running)
                                windowRefreshButton.rotation = 0;
                        }
                    }
                }

                DankActionButton {
                    buttonSize: 36
                    iconName: "info"
                    iconSize: 20
                    iconColor: Theme.surfaceText
                    tooltipText: Tr.t("About")
                    onClicked: win.aboutOpen = true
                }

                DankActionButton {
                    buttonSize: 36
                    iconName: "settings"
                    iconSize: 20
                    iconColor: Theme.surfaceText
                    tooltipText: Tr.t("Plugin settings")
                    onClicked: win.settingsOpen = true
                }

                DankActionButton {
                    buttonSize: 36
                    iconName: "close"
                    iconSize: 20
                    iconColor: Theme.surfaceText
                    tooltipText: Tr.t("Close")
                    onClicked: win.visible = false
                }
            }
        }

        // ── Unsupported OS warning (not a Fedora-based distro) ──────────────
        Rectangle {
            Layout.fillWidth: true
            visible: win.osIncompatiblePretty !== ""
            implicitHeight: osWarnRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.warning, 0.14)
            border.width: 1
            border.color: Theme.withAlpha(Theme.warning, 0.35)

            RowLayout {
                id: osWarnRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                DankIcon {
                    name: "warning"
                    size: 20
                    color: Theme.warning
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("This app is built for Fedora-based systems. You appear to be running %1 — system package features may not work correctly.").arg(win.osIncompatiblePretty)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }
            }
        }

        // ── Experimental-backend notice (Debian/Ubuntu, Arch) ───────────────
        Rectangle {
            Layout.fillWidth: true
            visible: Backend.backendId !== "dnf"
            implicitHeight: aptNoticeRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.secondary, 0.12)
            border.width: 1
            border.color: Theme.withAlpha(Theme.secondary, 0.3)

            RowLayout {
                id: aptNoticeRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                DankIcon {
                    name: "science"
                    size: 20
                    color: Theme.secondary
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("%1 support is experimental — please report anything that misbehaves.").arg(Backend.systemRepoLabel)
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                Item {
                    implicitWidth: aptIssueButton.width
                    implicitHeight: aptIssueButton.height

                    DankButton {
                        id: aptIssueButton
                        buttonHeight: 28
                        horizontalPadding: Theme.spacingM
                        iconName: "bug_report"
                        iconSize: 14
                        text: Tr.t("Report an issue")
                        backgroundColor: Theme.withAlpha(Theme.buttonBg, 0.9)
                        textColor: Theme.buttonText
                        onClicked: Qt.openUrlExternally(win.githubUrl + "/issues")
                    }
                }
            }
        }

        // ── Missing requirements ────────────────────────────────────────────
        // What the plugin needs from the distro and does not have, each with
        // the package that fixes it. Two kinds live here: the package-manager
        // bindings, without which no system package can be touched at all,
        // and the AppStream catalog, without which apps merely look poorer.
        // Both are separate distro packages that a default install can lack,
        // and both used to be invisible.
        Rectangle {
            Layout.fillWidth: true
            visible: Backend.missingRequirements.length > 0
            implicitHeight: requirementsColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            readonly property color accent: Backend.missingRequirements.some(r => r.blocking) ? Theme.error : Theme.warning
            color: Theme.withAlpha(accent, 0.10)
            border.width: 1
            border.color: Theme.withAlpha(accent, 0.30)

            ColumnLayout {
                id: requirementsColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingS

                Repeater {
                    model: Backend.missingRequirements

                    delegate: ColumnLayout {
                        id: requirementRow

                        required property var modelData

                        readonly property bool installing: Backend.installingRequirement === modelData.id

                        Layout.fillWidth: true
                        spacing: Theme.spacingXS

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingM

                            DankIcon {
                                name: requirementRow.modelData.blocking ? "error" : "info"
                                size: 20
                                color: requirementRow.modelData.blocking ? Theme.error : Theme.warning
                            }

                            StyledText {
                                Layout.fillWidth: true
                                text: {
                                    const pkg = requirementRow.modelData.package;
                                    if (requirementRow.installing)
                                        return Tr.t("Installing %1…").arg(pkg);
                                    if (requirementRow.modelData.blocking)
                                        return Tr.t("%1 is missing — system packages cannot be installed or updated until it is there.").arg(pkg);
                                    return Tr.t("%1 is missing — app names, icons and release notes stay limited without it.").arg(pkg);
                                }
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                wrapMode: Text.WordWrap
                            }

                            Item {
                                visible: Backend.installingRequirement === ""
                                implicitWidth: requirementInstallButton.width
                                implicitHeight: requirementInstallButton.height

                                DankButton {
                                    id: requirementInstallButton
                                    buttonHeight: 28
                                    horizontalPadding: Theme.spacingM
                                    iconName: "download"
                                    iconSize: 14
                                    text: Tr.t("Install")
                                    backgroundColor: requirementRow.modelData.blocking ? Theme.primary : Theme.withAlpha(Theme.buttonBg, 0.9)
                                    textColor: requirementRow.modelData.blocking ? Theme.primaryText : Theme.buttonText
                                    onClicked: Backend.installRequirement(requirementRow.modelData.id, requirementRow.modelData.package)
                                }
                            }
                        }

                        // The same install as a command, for anyone who would
                        // rather watch it happen in a terminal
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: requirementHint.implicitHeight + Theme.spacingS * 2
                            radius: Theme.cornerRadius / 2
                            color: Theme.withAlpha(Theme.surfaceVariant, 0.6)

                            StyledText {
                                id: requirementHint
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                text: Backend.installHintFor(requirementRow.modelData.package)
                                font.family: Theme.monoFontFamily
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                wrapMode: Text.WrapAnywhere
                            }
                        }
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: Backend.requirementInstallError !== ""
                    text: Backend.requirementInstallError
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.error
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }
            }
        }

        // ── Plugin self-update banner ───────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && win.selfUpdateVersion !== "" && win.selfUpdateVersion !== win.selfUpdateDismissedVersion
            implicitHeight: selfUpdateColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.primary, 0.10)
            border.width: 1
            border.color: Theme.withAlpha(Theme.primary, 0.30)

            ColumnLayout {
                id: selfUpdateColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingS

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingM

                    Image {
                        Layout.preferredWidth: 22
                        Layout.preferredHeight: 22
                        source: win.appIconSource
                        sourceSize.width: 44
                        sourceSize.height: 44
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                    }

                    StyledText {
                        Layout.fillWidth: true
                        textFormat: Text.StyledText
                        text: Tr.t("Dank Software Depot %1 is available").arg("<b>" + win.selfUpdateVersion + "</b>")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    // Wrapper Item: DankButton sizes itself via `width`,
                    // which the RowLayout would ignore and cramp the label
                    Item {
                        Layout.preferredWidth: selfUpdateButton.width
                        Layout.preferredHeight: selfUpdateButton.height

                        DankButton {
                            id: selfUpdateButton
                            buttonHeight: 30
                            iconName: "download"
                            iconSize: 14
                            horizontalPadding: Theme.spacingM
                            enabled: !win.selfUpdateBusy
                            text: win.selfUpdateBusy ? Tr.t("Updating…") : Tr.t("Update and reload shell")
                            backgroundColor: Theme.buttonBg
                            textColor: Theme.buttonText
                            onClicked: {
                                win.selfUpdateBusy = true;
                                // Detached: the shell reload below kills our
                                // own process tree mid-flight otherwise
                                Quickshell.execDetached(["sh", "-c", "dms plugins update dankSoftwareDepot && dms restart"]);
                            }
                        }
                    }

                    DankActionButton {
                        buttonSize: 28
                        iconName: "close"
                        iconSize: 16
                        iconColor: Theme.surfaceVariantText
                        tooltipText: Tr.t("Dismiss")
                        onClicked: PluginService.savePluginData("dankSoftwareDepot", "selfUpdateDismissedVersion", win.selfUpdateVersion)
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: win.selfUpdateNotes !== ""
                    text: win.selfUpdateNotes
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                    maximumLineCount: 10
                    elide: Text.ElideRight
                }
            }
        }

        // ── Reboot recommendation banner ────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: win.widgetRoot !== null && win.widgetRoot.rebootRecommended
            implicitHeight: rebootRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.warning, 0.14)
            border.width: 1
            border.color: Theme.withAlpha(Theme.warning, 0.35)

            RowLayout {
                id: rebootRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingM

                DankIcon {
                    name: "restart_alt"
                    size: 22
                    color: Theme.warning
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("A computer restart is recommended to finish applying updates.")
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                Item {
                    Layout.preferredWidth: windowRebootButton.width
                    Layout.preferredHeight: windowRebootButton.height

                    DankButton {
                        id: windowRebootButton
                        buttonHeight: 32
                        iconName: "restart_alt"
                        iconSize: 15
                        text: (win.widgetRoot && win.widgetRoot.confirmReboot) ? Tr.t("Confirm restart?") : Tr.t("Restart now")
                        backgroundColor: (win.widgetRoot && win.widgetRoot.confirmReboot) ? Theme.error : Theme.buttonBg
                        textColor: (win.widgetRoot && win.widgetRoot.confirmReboot) ? Ui.onColor(Theme.error) : Theme.buttonText
                        onClicked: win.widgetRoot.requestReboot()
                    }
                }

                DankActionButton {
                    buttonSize: 28
                    iconName: "close"
                    iconSize: 16
                    iconColor: Theme.surfaceVariantText
                    tooltipText: Tr.t("Dismiss")
                    onClicked: win.widgetRoot.dismissReboot()
                }
            }
        }

        // ── Compact status strip while updates are pending ──────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && !win.dashboardMode && !win.showingRun && !SystemUpdateService.isChecking && win.effectiveCount > 0
            implicitHeight: statusStripRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.primary, 0.08)

            RowLayout {
                id: statusStripRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                Rectangle {
                    Layout.preferredWidth: 26
                    Layout.preferredHeight: 26
                    radius: 13
                    color: Theme.isLightMode ? Theme.primary : "transparent"
                    visible: stripLogo.status === Image.Ready

                    Image {
                        anchors.centerIn: parent
                        width: 20
                        height: 20
                        source: stripLogo.source
                        sourceSize.width: 40
                        sourceSize.height: 40
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                    }
                }

                Image {
                    id: stripLogo
                    visible: false
                    Layout.preferredWidth: 22
                    Layout.preferredHeight: 22
                    source: (win.dashboard && win.dashboard.dankLogo) ? "file://" + win.dashboard.dankLogo : ""
                    sourceSize.width: 44
                    sourceSize.height: 44
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                }

                DankIcon {
                    visible: stripLogo.status !== Image.Ready
                    name: "deployed_code_update"
                    size: 20
                    color: Theme.primary
                }

                StyledText {
                    Layout.fillWidth: true
                    text: {
                        const parts = [(win.effectiveCount === 1 ? Tr.t("%1 update available") : Tr.t("%1 updates available")).arg(win.effectiveCount)];
                        if (win.widgetRoot && win.widgetRoot.updateSizeText !== "")
                            parts.push(win.widgetRoot.updateSizeText);
                        const checked = win.lastCheckedText();
                        if (checked)
                            parts.push(checked);
                        return parts.join(" · ");
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    elide: Text.ElideRight
                }
            }
        }

        // ── Manual-pass progress (Install all now / single overrides) ──────
        Rectangle {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && win.singleBusyKey !== ""
            implicitHeight: manualRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.primary, 0.08)

            RowLayout {
                id: manualRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                DankSpinner {
                    size: 22
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0

                    StyledText {
                        Layout.fillWidth: true
                        text: Tr.t("Installing updates…")
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                    }

                    StyledText {
                        Layout.fillWidth: true
                        visible: win.singleUpdateStatus !== ""
                        text: win.singleUpdateStatus
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }
                }
            }
        }

        // ── End-of-life components (no longer maintained upstream) ─────────
        Rectangle {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && win.widgetRoot !== null && (win.widgetRoot.eolRefs || []).length > 0
            implicitHeight: eolRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.error, 0.10)

            RowLayout {
                id: eolRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                DankIcon {
                    name: "warning"
                    size: 18
                    color: Theme.error
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("No longer maintained (end-of-life): %1").arg(((win.widgetRoot ? win.widgetRoot.eolRefs : []) || []).map(r => r.appName || r.id).join(", "))
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }
            }
        }

        // ── Newer Fedora release available ──────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && win.widgetRoot !== null && win.widgetRoot.distroUpgrade !== null && win.widgetRoot.distroUpgrade.available === true
            implicitHeight: distroRow.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.primary, 0.10)

            RowLayout {
                id: distroRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingM

                DankIcon {
                    name: "rocket_launch"
                    size: 18
                    color: Theme.primary
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("A new Fedora release is available: Fedora %1.").arg(win.widgetRoot && win.widgetRoot.distroUpgrade ? win.widgetRoot.distroUpgrade.latest : "")
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                Item {
                    Layout.preferredWidth: distroInfoButton.width
                    Layout.preferredHeight: distroInfoButton.height

                    DankButton {
                        id: distroInfoButton
                        buttonHeight: 28
                        horizontalPadding: Theme.spacingM
                        iconName: "open_in_new"
                        iconSize: 13
                        text: Tr.t("Learn more")
                        backgroundColor: Theme.buttonBg
                        textColor: Theme.buttonText
                        onClicked: Qt.openUrlExternally("https://docs.fedoraproject.org/en-US/quick-docs/upgrading-fedora-offline/")
                    }
                }
            }
        }

        // ── Tabs ────────────────────────────────────────────────────────────
        DankTabBar {
            id: tabs
            Layout.fillWidth: true
            // The active-tab indicator draws ~10px below the bar's bounds, so
            // reserve extra space between the bar and the tab content.
            Layout.bottomMargin: Theme.spacingL
            // Taller than the content so the hover highlight gets internal padding
            tabHeight: 52
            // Built from the same list of ids the rest of the window uses, so
            // a hidden tab cannot make the two disagree
            model: win.tabIds.map(id => {
                switch (id) {
                case 1:
                    return {
                        text: Tr.t("Installed"),
                        icon: "apps"
                    };
                case 2:
                    return {
                        text: Tr.t("Install"),
                        icon: "storefront"
                    };
                case 3:
                    return {
                        text: Tr.t("Firmware"),
                        icon: "memory"
                    };
                case 4:
                    return {
                        text: Tr.t("Log"),
                        icon: "history"
                    };
                default:
                    return {
                        text: Tr.t("Updates"),
                        icon: "deployed_code_update"
                    };
                }
            })

            // The shared tab bar does carry a state layer, but at surfaceTint
            // 0.08 it is invisible against this window. Draw a clearer one on
            // top: a HoverHandler never swallows clicks, so the bar keeps
            // handling those itself.
            Repeater {
                model: tabs.model.length

                Rectangle {
                    id: tabHover

                    required property int index
                    readonly property int tabCount: Math.max(1, tabs.model.length)
                    readonly property real tabWidth: (tabs.width - tabs.spacing * Math.max(0, tabCount - 1)) / tabCount

                    x: index * (tabWidth + tabs.spacing)
                    y: 0
                    width: tabWidth
                    height: tabs.tabHeight
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.primary, 0.14)
                    // Fades, never hides: an invisible item receives no hover
                    // events, so `visible: opacity > 0` would latch it off
                    // forever. A fully transparent item still gets them.
                    opacity: hoverHandler.hovered ? 1 : 0

                    HoverHandler {
                        id: hoverHandler
                    }

                    Behavior on opacity {
                        NumberAnimation {
                            duration: Theme.shortDuration
                            easing.type: Theme.standardEasing
                        }
                    }
                }
            }

            onTabClicked: index => {
                currentIndex = index;
            }

            onCurrentIndexChanged: {
                // Derived from currentIndex right here, not read off
                // win.currentTab: that is a binding on this very property and
                // is not guaranteed to have caught up while this handler runs.
                // Reading it stale activated the previous tab's loader and
                // left the new tab blank until it was clicked twice.
                const id = win.tabIds[Math.min(currentIndex, win.tabIds.length - 1)];
                if (id === 1)
                    installedLoader.active = true;
                if (id === 2)
                    installLoader.active = true;
                if (id === 3) {
                    // Re-scan hardware on every visit; first activation scans
                    // via Component.onCompleted
                    const rescan = firmwareLoader.active;
                    firmwareLoader.active = true;
                    if (rescan && firmwareLoader.item)
                        firmwareLoader.item.reload();
                }
                if (id === 4)
                    logLoader.active = true;
                win.focusCurrentTab();
            }
        }

        // ── Installed tab (lazy) ────────────────────────────────────────────
        Loader {
            id: installedLoader
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: win.currentTab === 1
            active: false

            sourceComponent: InstalledView {
                store: win.store
                engine: win.engine
                logger: win.widgetRoot ? win.widgetRoot.actionLogger : null
                refreshSerial: win.softwareSerial
                overlayParent: windowOverlayLayer
                onSoftwareMutated: win.softwareSerial++
            }
        }

        // ── Install tab (lazy) ──────────────────────────────────────────────
        Loader {
            id: installLoader
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: win.currentTab === 2
            active: false

            sourceComponent: InstallView {
                logger: win.widgetRoot ? win.widgetRoot.actionLogger : null
                refreshSerial: win.softwareSerial
                overlayParent: windowOverlayLayer
                onSoftwareMutated: win.softwareSerial++
            }
        }

        // ── Firmware tab (lazy) ─────────────────────────────────────────────
        Loader {
            id: firmwareLoader
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: win.currentTab === 3
            active: false

            sourceComponent: FirmwareView {
                firmware: win.firmware
            }
        }

        // ── Log tab (lazy) ──────────────────────────────────────────────────
        Loader {
            id: logLoader
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: win.currentTab === 4
            active: false

            sourceComponent: LogView {
                logger: win.widgetRoot ? win.widgetRoot.actionLogger : null
            }
        }

        // ── Progress panel (only while a run adds information) ──────────────
        Rectangle {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && (win.engine.running || (win.engine.phase !== "idle" && win.engine.failedCount > 0) || win.engine.phase === "done")
            implicitHeight: progressColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainer
            border.width: 1
            border.color: Theme.withAlpha(Theme.outline, 0.1)

            ColumnLayout {
                id: progressColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingS

                PhaseIndicator {
                    Layout.alignment: Qt.AlignHCenter
                    visible: win.engine.running
                    step: win.engine.phaseStep
                    running: win.engine.running
                    failed: win.engine.failedCount > 0
                }

                // No overall progress bar: with parallel downloads and mixed
                // phases an aggregate fraction is more misleading than
                // helpful — the per-package rows below carry the progress.
                RowLayout {
                    Layout.fillWidth: true

                    BusyText {
                        text: win.engine.phaseLabel
                        pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: (win.engine.running && win.engine.currentItem) ? "·  " + win.store.prettyId(win.engine.currentItem) : ""
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    // A run that ends with failures ends in the "failed"
                    // phase, so this summary has to cover that phase too —
                    // its failure half used to be unreachable
                    StyledText {
                        visible: !win.engine.running && (win.engine.phase === "done" || win.engine.phase === "failed")
                        text: Tr.t("%1 updated").arg(win.engine.completedCount) + (win.engine.failedCount > 0 ? " · " + Tr.t("%1 failed").arg(win.engine.failedCount) : "")
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: win.engine.failedCount > 0 ? Ui.failColor : Theme.success
                    }

                    // Whatever happens to this panel — dismissed, or swept
                    // away by the shell reloading — the log keeps the run
                    DankButton {
                        visible: !win.engine.running && win.engine.phase !== "idle" && win.engine.failedCount > 0
                        buttonHeight: 26
                        horizontalPadding: Theme.spacingM
                        iconName: "history"
                        iconSize: 14
                        text: Tr.t("View in log")
                        backgroundColor: Theme.withAlpha(Theme.buttonBg, 0.9)
                        textColor: Theme.buttonText
                        onClicked: win.openLatestLogEntry()
                    }

                    DankActionButton {
                        visible: !win.engine.running && win.engine.phase !== "idle"
                        buttonSize: 24
                        iconName: "close"
                        iconSize: 15
                        iconColor: Theme.surfaceVariantText
                        tooltipText: Tr.t("Dismiss result")
                        onClicked: win.engine.dismiss()
                    }
                }

                // Download phase details: sizes, speed, item counts
                BusyText {
                    Layout.fillWidth: true
                    visible: win.engine.running && win.engine.progressDetail !== ""
                    text: win.engine.progressDetail
                    pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                }
            }
        }

        // ── Update list ─────────────────────────────────────────────────────
        DankListView {
            id: cardsList
            Component.onCompleted: Ui.softenScrollbar(cardsList)
            header: win.dashboardMode ? dashboardHeaderComponent : null

            // The dashboard header makes originY negative, and DankListView's
            // wheel handler floors its scroll limit at 0 instead of the true
            // bottom edge — letting the dashboard be wheeled into empty space
            // and snap back. Clamp to the real end of the content.
            onContentYChanged: {
                const maxY = Math.max(originY, originY + contentHeight - height);
                if (contentY > maxY)
                    contentY = maxY;
            }
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Theme.spacingS
            model: win.listModel
            visible: win.currentTab === 0 && (win.listModel.length > 0 || win.dashboardMode)

            delegate: Loader {
                required property var modelData

                width: cardsList.width
                sourceComponent: modelData.type === "header" ? headerRowComponent : cardRowComponent

                onLoaded: item.rowData = modelData
            }
        }

        Component {
            id: headerRowComponent

            Item {
                property var rowData: ({})

                readonly property bool updatable: !win.engine.running && win.singleBusyKey === "" && ["1 · Applications", "2 · System packages", "3 · Runtimes & extensions", "4 · Firmware"].includes(rowData.category || "")

                width: cardsList.width
                height: 36

                HoverHandler {
                    id: headerHover
                }

                // Collapsible sections toggle on click anywhere in the header
                MouseArea {
                    anchors.fill: parent
                    enabled: rowData.collapsible === true
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: win.toggleCategory(rowData.category)
                }

                Row {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 4
                    spacing: Theme.spacingS

                    DankIcon {
                        name: win.categoryIcon(rowData.category || "")
                        size: 18
                        color: win.categoryColor(rowData.category || "")
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: rowData.title || ""
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    // How many rows the group holds — the answer to "how much
                    // is still waiting", readable without counting rows and
                    // without opening a collapsed group
                    Rectangle {
                        width: headerCount.implicitWidth + 14
                        height: 18
                        radius: 9
                        color: Theme.withAlpha(win.categoryColor(rowData.category || ""), 0.15)
                        anchors.verticalCenter: parent.verticalCenter

                        StyledText {
                            id: headerCount
                            anchors.centerIn: parent
                            text: String(rowData.count || 0)
                            font.pixelSize: Theme.fontSizeSmall - 2
                            font.weight: Font.Medium
                            color: win.categoryColor(rowData.category || "")
                        }
                    }

                    DankIcon {
                        visible: rowData.collapsible === true
                        name: rowData.collapsed === true ? "expand_more" : "expand_less"
                        size: 16
                        color: Theme.surfaceVariantText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // Anchored separately so its appearance never moves the title
                DankButton {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: updatable && headerHover.hovered
                    buttonHeight: 26
                    iconName: "download"
                    iconSize: 14
                    horizontalPadding: Theme.spacingM
                    text: Tr.t("Update these")
                    backgroundColor: Theme.withAlpha(Theme.buttonBg, 0.9)
                    textColor: Theme.buttonText
                    onClicked: win.sectionUpdate(rowData.category)
                }
            }
        }

        Component {
            id: cardRowComponent

            UpdateCard {
                property var rowData: ({})

                width: cardsList.width
                pkg: rowData.pkg || ({
                        name: "",
                        repo: "system"
                    })
                info: {
                    if (rowData.aiInfo)
                        return {
                            name: rowData.aiInfo.name,
                            summary: "AppImage",
                            homepage: rowData.aiInfo.url || "",
                            icon: "",
                            releases: []
                        };
                    if (rowData.fwInfo)
                        return {
                            name: rowData.fwInfo.name,
                            summary: rowData.fwInfo.summary,
                            homepage: rowData.fwInfo.homepage,
                            icon: "",
                            releases: [{
                                    version: rowData.fwInfo.next,
                                    date: 0,
                                    notesHtml: rowData.fwInfo.notesHtml,
                                    newer: true
                                }]
                        };
                    return win.store.infoFor(rowData.pkg);
                }
                itemState: win.engine.stateFor(rowData.pkg)
                errorDetail: win.engine.runErrorDetails && rowData.pkg ? win.engine.errorDetailFor(rowData.pkg) : ""
                advisory: (win.widgetRoot && rowData.pkg) ? (win.widgetRoot.advisories[win.store.stripArch(rowData.pkg.name)] || null) : null
                store: win.store
                engineBusy: win.engine.running
                held: rowData.ignored === true || win.store.isHeld(rowData.pkg)
                holdReason: rowData.ignored === true ? Tr.t("held by you") : win.store.holdReason(rowData.pkg)
                isIgnored: rowData.ignored === true
                canHold: {
                    if (rowData.ignored === true)
                        return true;
                    if (!rowData.pkg || rowData.pkg.repo === "firmware")
                        return false;
                    if (win.store.isHeld(rowData.pkg))
                        return false;
                    return SystemUpdateService.canIgnorePackage(rowData.pkg);
                }
                showUpdateButton: rowData.pkg && (rowData.pkg.repo === "flatpak" || rowData.pkg.repo === "appimage") && win.singleBusyKey === ""
                onUpdateRequested: win.runSingleUpdate(rowData)
                onHoldToggleRequested: {
                    if (rowData.ignored === true) {
                        SystemUpdateService.unignorePackage(rowData.pkg.name);
                    } else {
                        SystemUpdateService.ignorePackage(rowData.pkg.name);
                    }
                }
                onDetailsRequested: win.openUpdateDetails(rowData, info)
            }
        }

        // ── Up-to-date dashboard: rendered as the list header so collapsed
        // Held section scrolls along underneath it ─────────────────────────
        Component {
            id: dashboardHeaderComponent

            Item {
                width: cardsList.width
                implicitHeight: dashHeaderColumn.implicitHeight + Theme.spacingL

                ColumnLayout {
                    id: dashHeaderColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    spacing: Theme.spacingL

                    // Hero: Dank logo, status, check-on-hover
                    Item {
                        Layout.fillWidth: true
                        Layout.topMargin: Theme.spacingL
                        implicitHeight: heroRow.implicitHeight + Theme.spacingM

                        MouseArea {
                            id: windowEmptyArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: (SystemUpdateService.isChecking || win.engine.running) ? Qt.ArrowCursor : Qt.PointingHandCursor
                            onClicked: {
                                if (!SystemUpdateService.isChecking && !win.engine.running)
                                    SystemUpdateService.checkForUpdates();
                            }
                        }

                        RowLayout {
                            id: heroRow
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: Theme.spacingL

                            Item {
                                Layout.preferredWidth: 72
                                Layout.preferredHeight: 72

                                Rectangle {
                                    anchors.fill: parent
                                    radius: 36
                                    // Light mode: solid primary disc so the white penguin stays visible
                                    color: {
                                        if (Theme.isLightMode)
                                            return windowEmptyArea.containsMouse && !SystemUpdateService.isChecking ? Qt.darker(Theme.primary, 1.15) : Theme.primary;
                                        return windowEmptyArea.containsMouse && !SystemUpdateService.isChecking ? Theme.withAlpha(Theme.primary, 0.12) : Theme.withAlpha(Theme.primary, 0.06);
                                    }

                                    Behavior on color {
                                        ColorAnimation {
                                            duration: Theme.shortDuration
                                        }
                                    }
                                }

                                Image {
                                    id: dankLogoImage
                                    anchors.centerIn: parent
                                    width: 46
                                    height: 46
                                    source: (win.dashboard && win.dashboard.dankLogo) ? "file://" + win.dashboard.dankLogo : ""
                                    sourceSize.width: 92
                                    sourceSize.height: 92
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                    visible: status === Image.Ready && !SystemUpdateService.isChecking && !windowEmptyArea.containsMouse
                                }

                                DankIcon {
                                    id: heroStateIcon
                                    anchors.centerIn: parent
                                    visible: !dankLogoImage.visible
                                    name: {
                                        if (SystemUpdateService.isChecking || windowEmptyArea.containsMouse)
                                            return "refresh";
                                        return SystemUpdateService.hasError ? "error" : "task_alt";
                                    }
                                    size: 40
                                    // This one spins. DankIcon draws glyphs with
                                    // native hinting by default, which snaps them
                                    // to the pixel grid — fine standing still,
                                    // ragged once rotated. smoothTransform swaps
                                    // in distance-field rendering, which turns.
                                    smoothTransform: true
                                    color: {
                                        if (Theme.isLightMode)
                                            return "white";
                                        if (SystemUpdateService.isChecking || windowEmptyArea.containsMouse)
                                            return Theme.primary;
                                        return SystemUpdateService.hasError ? Theme.error : Theme.success;
                                    }

                                    RotationAnimator on rotation {
                                        from: 0
                                        to: 360
                                        duration: 1000
                                        loops: Animation.Infinite
                                        running: SystemUpdateService.isChecking

                                        onRunningChanged: {
                                            if (!running)
                                                heroStateIcon.rotation = 0;
                                        }
                                    }
                                }
                            }

                            ColumnLayout {
                                spacing: 2

                                BusyText {
                                    text: {
                                        if (SystemUpdateService.isChecking)
                                            return Tr.t("Checking for updates…");
                                        if (windowEmptyArea.containsMouse)
                                            return Tr.t("Check for updates");
                                        if (SystemUpdateService.hasError)
                                            return Tr.t("Check failed");
                                        return Tr.t("Your system is up to date!");
                                    }
                                    pixelSize: Theme.fontSizeLarge
                                    color: Theme.surfaceText
                                }

                                // The raw service error (curl/dnf output) can be
                                // arbitrarily long — wrap it in a bounded block
                                // instead of letting it stretch the hero row.
                                StyledText {
                                    visible: SystemUpdateService.hasError && !SystemUpdateService.isChecking && !windowEmptyArea.containsMouse
                                    text: SystemUpdateService.errorMessage || ""
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Ui.failColor
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 3
                                    elide: Text.ElideRight
                                    Layout.maximumWidth: Math.min(520, win.width - 220)
                                }

                                StyledText {
                                    visible: !SystemUpdateService.isChecking && !SystemUpdateService.hasError && (win.lastUpdateUnix > 0 || SystemUpdateService.nextCheckUnix > 0)
                                    text: {
                                        const parts = [];
                                        if (win.lastUpdateUnix > 0)
                                            parts.push(Tr.t("Last update %1").arg(win.formatAgo(win.lastUpdateUnix)));
                                        const next = win.formatIn(SystemUpdateService.nextCheckUnix);
                                        if (next)
                                            parts.push(Tr.t("next check %1").arg(next));
                                        return parts.join(" · ");
                                    }
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }


                            }
                        }
                    }

                    // Cards
                    GridLayout {
                        Layout.fillWidth: true
                        columns: cardsList.width < 640 ? 1 : 2
                        columnSpacing: Theme.spacingM
                        rowSpacing: Theme.spacingM

                        // System info
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            implicitHeight: systemCardCol.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.45)

                            ColumnLayout {
                                id: systemCardCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.leftMargin: Theme.spacingM
                                anchors.rightMargin: Theme.spacingM
                                anchors.topMargin: Theme.spacingM
                                spacing: Theme.spacingS

                                RowLayout {
                                    spacing: Theme.spacingS

                                    DankIcon {
                                        name: "computer"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    StyledText {
                                        text: Tr.t("System")
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                    }
                                }

                                Repeater {
                                    model: {
                                        const dash = win.dashboard || {};
                                        return [
                                            { label: "OS", value: dash.osPretty || SystemUpdateService.distroPretty || "" },
                                            { label: "Host", value: dash.hostname || "" },
                                            { label: "Kernel", value: dash.kernel || "" },
                                            { label: Tr.t("Uptime"), value: win.formatUptime(dash.uptimeSecs || 0) }
                                        ].filter(row => row.value !== "");
                                    }

                                    delegate: RowLayout {
                                        required property var modelData

                                        Layout.fillWidth: true
                                        spacing: Theme.spacingS

                                        StyledText {
                                            text: modelData.label
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            Layout.preferredWidth: 60
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: modelData.value
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                            }
                        }

                        // Status
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            implicitHeight: statusCardCol.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.45)

                            ColumnLayout {
                                id: statusCardCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.leftMargin: Theme.spacingM
                                anchors.rightMargin: Theme.spacingM
                                anchors.topMargin: Theme.spacingM
                                spacing: Theme.spacingS

                                RowLayout {
                                    spacing: Theme.spacingS

                                    DankIcon {
                                        name: "monitor_heart"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    StyledText {
                                        text: Tr.t("Status")
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                    }
                                }

                                Repeater {
                                    model: {
                                        const root = win.widgetRoot;
                                        if (!root)
                                            return [];
                                        const autoLabels = {
                                            "off": Tr.t("Off"),
                                            "notify": Tr.t("Notify only"),
                                            "auto": Tr.t("Auto-install Flatpaks")
                                        };
                                        return [
                                            { label: Tr.t("Held"), value: String((root.heldSystemKeys || []).length + (SettingsData.updaterIgnoredPackages || []).length) },
                                            { label: "End-of-life", value: String((root.eolRefs || []).length) },
                                            { label: Tr.t("Automatic updates"), value: autoLabels[root.autoUpdateMode] || Tr.t("Off") },
                                            { label: "Dank Software Depot", value: win.pluginManifest.version ? "v" + win.pluginManifest.version : "" }
                                        ].filter(row => row.value !== "");
                                    }

                                    delegate: RowLayout {
                                        required property var modelData

                                        Layout.fillWidth: true
                                        spacing: Theme.spacingS

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: modelData.label
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            elide: Text.ElideRight
                                        }

                                        StyledText {
                                            text: modelData.value
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.DemiBold
                                            color: Theme.surfaceText
                                        }
                                    }
                                }
                            }
                        }
                        // Installed software per source
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            implicitHeight: installedCardCol.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.45)

                            ColumnLayout {
                                id: installedCardCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.leftMargin: Theme.spacingM
                                anchors.rightMargin: Theme.spacingM
                                anchors.topMargin: Theme.spacingM
                                spacing: Theme.spacingS

                                RowLayout {
                                    spacing: Theme.spacingS

                                    DankIcon {
                                        name: "apps"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    StyledText {
                                        text: Tr.t("Installed software")
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                    }
                                }

                                Repeater {
                                    model: {
                                        const dash = win.dashboard || {};
                                        const copr = dash.coprCount || 0;
                                        // Second row: COPR on Fedora, AUR/foreign on Arch,
                                        // nothing comparable on Debian
                                        return [
                                            { label: Backend.systemRepoLabel, icon: "memory", count: Math.max(0, (dash.rpmTotal || 0) - copr) },
                                            { label: Backend.backendId === "pacman" ? "AUR" : "COPR", icon: "science", count: copr },
                                            { label: "Flatpak", icon: "apps", count: dash.flatpakCount || 0 },
                                            { label: "AppImage", icon: "deployed_code", count: dash.appimageCount || 0 }
                                        ].filter(row => row.label !== "COPR" && row.label !== "AUR" || row.count > 0 || Backend.backendId === "dnf");
                                    }

                                    delegate: RowLayout {
                                        required property var modelData

                                        Layout.fillWidth: true
                                        spacing: Theme.spacingS

                                        DankIcon {
                                            name: modelData.icon
                                            size: 14
                                            color: Theme.surfaceVariantText
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: modelData.label
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            text: String(modelData.count)
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.DemiBold
                                            color: Theme.primary
                                        }
                                    }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 1
                                    color: Theme.withAlpha(Theme.outline, 0.15)
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    text: Tr.t("Total: %1").arg((win.dashboard ? (win.dashboard.rpmTotal || 0) + (win.dashboard.flatpakCount || 0) + (win.dashboard.appimageCount || 0) : 0))
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    horizontalAlignment: Text.AlignRight
                                }
                            }
                        }

                        // Recently updated
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            implicitHeight: recentCardCol.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.45)

                            ColumnLayout {
                                id: recentCardCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.leftMargin: Theme.spacingM
                                anchors.rightMargin: Theme.spacingM
                                anchors.topMargin: Theme.spacingM
                                spacing: Theme.spacingS

                                RowLayout {
                                    spacing: Theme.spacingS

                                    DankIcon {
                                        name: "history"
                                        size: 20
                                        color: Theme.primary
                                    }

                                    StyledText {
                                        text: Tr.t("Recently updated")
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        color: Theme.surfaceText
                                    }
                                }

                                ListView {
                                    id: recentList

                                    // Five visible rows (one fewer than before) keeps
                                    // this card level with the installed-software one;
                                    // the rest of the 50 entries scrolls.
                                    readonly property int rowHeight: 24

                                    Layout.fillWidth: true
                                    Layout.preferredHeight: rowHeight * Math.min(5, count)
                                    clip: true
                                    boundsBehavior: Flickable.StopAtBounds
                                    model: (win.dashboard && win.dashboard.recent) ? win.dashboard.recent : []

                                    delegate: Item {
                                        required property var modelData

                                        width: ListView.view.width
                                        height: recentList.rowHeight

                                        RowLayout {
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: Theme.spacingS

                                            StyledText {
                                                Layout.fillWidth: true
                                                text: modelData.name
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceText
                                                elide: Text.ElideRight
                                            }

                                            Rectangle {
                                                Layout.preferredWidth: recentChip.implicitWidth + 10
                                                Layout.preferredHeight: 16
                                                radius: 8
                                                color: Theme.withAlpha(Theme.tertiary, 0.12)

                                                StyledText {
                                                    id: recentChip
                                                    anchors.centerIn: parent
                                                    text: Tr.t(modelData.source)
                                                    font.pixelSize: Theme.fontSizeSmall - 3
                                                    color: Theme.tertiary
                                                }
                                            }

                                            StyledText {
                                                text: win.formatAgo(modelData.ts)
                                                font.pixelSize: Theme.fontSizeSmall - 1
                                                color: Theme.surfaceVariantText
                                            }
                                        }
                                    }
                                }
                            }
                        }

                    }

                    // ── Reclaimable space ───────────────────────────────────
                    // Two piles nobody looks at until a disk fills: packages
                    // pulled in for something since removed, and the download
                    // cache. Shown with their real sizes so the offer is a
                    // fact rather than a suggestion.
                    Rectangle {
                        readonly property var scan: win.widgetRoot ? win.widgetRoot.cleanup : null
                        readonly property real total: scan ? ((scan.unneeded.bytes || 0) + (scan.cache.bytes || 0)) : 0

                        Layout.fillWidth: true
                        visible: total > 50 * 1024 * 1024
                        implicitHeight: cleanupColumn.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.45)

                        ColumnLayout {
                            id: cleanupColumn
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Theme.spacingM
                            anchors.rightMargin: Theme.spacingM
                            spacing: Theme.spacingS

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.spacingS

                                DankIcon {
                                    name: "cleaning_services"
                                    size: 18
                                    color: Theme.primary
                                }

                                StyledText {
                                    text: Tr.t("Reclaim space")
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }

                                Item {
                                    Layout.fillWidth: true
                                }

                                StyledText {
                                    text: win.engine.formatBytes(parent.parent.parent.total)
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    color: Theme.primary
                                }
                            }

                            Repeater {
                                model: {
                                    const scan = win.widgetRoot ? win.widgetRoot.cleanup : null;
                                    if (!scan)
                                        return [];
                                    const rows = [];
                                    if (scan.unneeded.count > 0)
                                        rows.push({
                                            kind: "packages",
                                            label: Tr.t("%1 packages nothing needs any more").arg(scan.unneeded.count),
                                            bytes: scan.unneeded.bytes || 0,
                                            action: Tr.t("Remove")
                                        });
                                    if ((scan.cache.bytes || 0) > 0)
                                        rows.push({
                                            kind: "cache",
                                            label: Tr.t("Downloaded package files, already installed"),
                                            bytes: scan.cache.bytes,
                                            action: Tr.t("Empty")
                                        });
                                    return rows;
                                }

                                delegate: RowLayout {
                                    required property var modelData

                                    Layout.fillWidth: true
                                    spacing: Theme.spacingS

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: modelData.label + " · " + win.engine.formatBytes(modelData.bytes)
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                    }

                                    Item {
                                        implicitWidth: cleanupButton.width
                                        implicitHeight: cleanupButton.height

                                        DankButton {
                                            id: cleanupButton
                                            buttonHeight: 26
                                            horizontalPadding: Theme.spacingM
                                            text: (win.widgetRoot && win.widgetRoot.cleanupBusy === modelData.kind) ? Tr.t("Working…") : modelData.action
                                            backgroundColor: Theme.withAlpha(Theme.buttonBg, 0.9)
                                            textColor: Theme.buttonText
                                            enabled: win.widgetRoot !== null && win.widgetRoot.cleanupBusy === ""
                                            onClicked: {
                                                if (modelData.kind === "packages")
                                                    win.widgetRoot.removeUnneeded();
                                                else
                                                    win.widgetRoot.cleanCache();
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── Support links ───────────────────────────────────────
                    // Only on the dashboard, where nothing else needs doing.
                    // Deliberately quiet: a plugin asking for votes and stars
                    // should not outshout the software it is reporting on.
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: Theme.spacingXS
                        spacing: Theme.spacingS

                        Item {
                            Layout.fillWidth: true
                        }

                        Repeater {
                            model: [
                                {
                                    text: Tr.t("Upvote plugin in Directory"),
                                    icon: "thumb_up",
                                    accent: Theme.primary,
                                    url: "https://github.com/AvengeMedia/dms-plugin-registry/issues/720"
                                },
                                {
                                    text: Tr.t("Star on GitHub"),
                                    icon: "star",
                                    accent: Theme.warning,
                                    url: "https://github.com/vinceecniv/DankSoftwareDepot"
                                },
                                {
                                    text: Tr.t("Built with Vito"),
                                    // Vito's own mark, drawn rather than
                                    // loaded: as bars it inherits the chip's
                                    // colour and hover like the other two,
                                    // which a bitmap or a gradient could not
                                    bars: true,
                                    icon: "",
                                    // Vito's own gradient, coral into violet
                                    gradientFrom: "#FF6B5E",
                                    gradientTo: "#7C3AED",
                                    accent: Theme.tertiary,
                                    url: "https://vito.talk"
                                }
                            ]

                            delegate: Rectangle {
                                id: supportChip

                                required property var modelData

                                implicitWidth: supportChipRow.implicitWidth + Theme.spacingM * 2
                                implicitHeight: 26
                                radius: height / 2
                                color: chipHover.hovered ? Theme.withAlpha(Theme.surfaceVariantText, 0.16) : Theme.withAlpha(Theme.surfaceVariantText, 0.08)

                                HoverHandler {
                                    id: chipHover
                                    cursorShape: Qt.PointingHandCursor
                                }

                                TapHandler {
                                    onTapped: Qt.openUrlExternally(supportChip.modelData.url)
                                }

                                RowLayout {
                                    id: supportChipRow
                                    anchors.centerIn: parent
                                    spacing: Theme.spacingXS

                                    // Takes its own colour and fills in on
                                    // hover — enough to feel alive, while the
                                    // chip stays quiet at rest
                                    DankIcon {
                                        visible: supportChip.modelData.icon !== ""
                                        name: supportChip.modelData.icon
                                        size: 13
                                        filled: chipHover.hovered
                                        color: chipHover.hovered ? supportChip.modelData.accent : Theme.surfaceVariantText

                                        Behavior on color {
                                            ColorAnimation {
                                                duration: Theme.shortDuration
                                            }
                                        }
                                    }

                                    // Vito's five bars, at the proportions of
                                    // its own mark (12 wide on a 20 pitch,
                                    // 20/36/56/36/20 tall)
                                    Row {
                                        visible: supportChip.modelData.bars === true
                                        spacing: 2
                                        Layout.alignment: Qt.AlignVCenter

                                        Repeater {
                                            model: [4, 7, 11, 7, 4]

                                            delegate: Rectangle {
                                                required property int modelData
                                                required property int index

                                                width: 2.5
                                                height: modelData
                                                radius: 1.25
                                                // Five separate bars cannot share one fill, so each
                                                // takes its own point along Vito's gradient — the
                                                // blend reads across the mark as one sweep
                                                color: chipHover.hovered ? Ui.mix(supportChip.modelData.gradientFrom, supportChip.modelData.gradientTo, index / 4) : Theme.surfaceVariantText

                                                Behavior on color {
                                                    ColorAnimation {
                                                        duration: Theme.shortDuration
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    StyledText {
                                        text: supportChip.modelData.text
                                        font.pixelSize: Theme.fontSizeSmall - 1
                                        color: Theme.surfaceVariantText
                                    }
                                }
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                        }
                    }
                }
            }
        }

        // ── What Update All would do ────────────────────────────────────────
        // The resolver's answer, shown before the click rather than after the
        // password: how much arrives, what nobody asked for, and what leaves.
        Rectangle {
            id: planStrip

            Layout.fillWidth: true
            readonly property var plan: win.engine.previewPlan
            visible: win.currentTab === 0 && !win.engine.running && win.showUpdateAll && plan !== null
            implicitHeight: planRow.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(plan && plan.removals > 0 ? Theme.warning : Theme.surfaceVariantText, 0.08)

            RowLayout {
                id: planRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingS

                DankIcon {
                    name: planStrip.plan && planStrip.plan.removals > 0 ? "warning" : "checklist"
                    size: 16
                    color: planStrip.plan && planStrip.plan.removals > 0 ? Theme.warning : Theme.surfaceVariantText
                }

                StyledText {
                    Layout.fillWidth: true
                    text: {
                        const plan = win.engine.previewPlan;
                        if (!plan)
                            return "";
                        const parts = [Tr.t("%1 packages").arg(plan.total), win.engine.formatBytes(plan.downloadBytes)];
                        if (plan.diskDeltaBytes > 0)
                            parts.push(Tr.t("+%1 on disk").arg(win.engine.formatBytes(plan.diskDeltaBytes)));
                        else if (plan.diskDeltaBytes < 0)
                            parts.push(Tr.t("frees %1").arg(win.engine.formatBytes(-plan.diskDeltaBytes)));
                        if (plan.extra > 0)
                            parts.push(Tr.t("%1 pulled in as dependencies").arg(plan.extra));
                        if (plan.removals > 0)
                            parts.push(Tr.t("%1 will be removed: %2").arg(plan.removals).arg(plan.removedNames.slice(0, 3).join(", ")));
                        // Measured here, not guessed: silent while this
                        // machine has not shown enough runs to have an opinion
                        const seconds = win.widgetRoot ? win.widgetRoot.estimateRunSeconds(plan.total) : -1;
                        if (seconds > 0)
                            parts.push(Tr.t("usually about %1 here").arg(win.engine.formatEta(seconds).replace(Tr.t("left"), "").trim() || (Math.round(seconds / 60) + " min")));
                        return parts.join(" · ");
                    }
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && win.hiddenRuntimeCount > 0
            text: (win.hiddenRuntimeCount === 1 ? Tr.t("%1 runtime component hidden (enable in plugin settings) — still included in Update All.") : Tr.t("%1 runtime components hidden (enable in plugin settings) — still included in Update All.")).arg(win.hiddenRuntimeCount)
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
        }

        // ── Footer buttons (standard DMS button styling) ────────────────────
        // The whole row goes when it has nothing to offer, not just the
        // button inside it: a layout skips invisible items, but a visible
        // wrapper around a hidden button keeps reserving its height — which
        // made the dashboard start scrolling a button's worth too early.
        // The condition lives on the window because a child's `visible`
        // follows its parent's, so a row that hid itself by reading the
        // button could never come back.
        RowLayout {
            Layout.fillWidth: true
            visible: win.currentTab === 0 && win.showUpdateAll
            spacing: Theme.spacingM

            Item {
                Layout.fillWidth: true
            }

            Item {
                Layout.preferredWidth: windowUpdateAllButton.width
                Layout.preferredHeight: windowUpdateAllButton.height

                DankButton {
                    id: windowUpdateAllButton

                    readonly property bool busyRun: win.updateAllBusy

                    text: busyRun ? Tr.t("Cancel") : (Tr.t("Update All") + ((win.widgetRoot && win.widgetRoot.updateSizeText !== "") ? " · " + win.widgetRoot.updateSizeText : ""))
                    iconName: busyRun ? "close" : "download"
                    backgroundColor: busyRun ? Theme.errorPressed : Theme.buttonBg
                    textColor: busyRun ? Theme.surfaceText : Theme.buttonText
                    onClicked: {
                        if (busyRun) {
                            win.engine.cancel();
                        } else {
                            win.engine.start({});
                        }
                    }
                }
            }
        }
    }
}
