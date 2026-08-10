import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

// Installed software tab: all Flatpak apps and rpm packages, live-searchable,
// with per-app actions (uninstall, hold, restore previous version).
// Loaded lazily on first tab activation.
Item {
    id: view

    required property var store
    required property var engine
    property var logger: null

    // Bumped by the window when software was installed/updated elsewhere
    // (Install tab, update run) so this list stays current.
    property int refreshSerial: 0

    onRefreshSerialChanged: reload()

    // Fired after a successful uninstall/restore so other views can refresh
    signal softwareMutated()

    // Set from the command palette, so a query typed there carries over
    // into the tab that can search it properly
    function setQuery(text) {
        searchField.text = text;
        searchText = text;
        searchField.forceActiveFocus();
    }

    function focusSearch() {
        searchField.forceActiveFocus();
    }

    // ── App details popup ────────────────────────────────────────────────────
    function openDetails(rowData) {
        detailsDialog.entry = rowData;
        if (rowData.kind === "flatpak") {
            loadDowngradeLog(rowData.id, rowData.origin);
        } else if (rowData.kind === "appimage") {
        } else {
            store.fetchChangelog(rowData.id);
            loadRpmVersions(rowData.id, rowData.version);
            loadRemovalImpact(rowData.id);
            loadProvenance(rowData.id);
        }
        detailsDialog.open({
            id: rowData.id,
            name: rowData.name,
            summary: rowData.summary || "",
            iconPath: (rowData.info && rowData.info.icon) || "",
            homepage: (rowData.info && rowData.info.homepage) || "",
            held: isHeldName(rowData.id),
            versionLabel: rowData.version || "",
            origin: rowData.origin || "",
            isFlatpak: rowData.kind === "flatpak",
            sources: rowData.kind === "flatpak" ? [{
                source: rowData.origin || "flathub",
                kind: "flatpak",
                ref: rowData.id
            }] : (rowData.kind === "appimage" ? [] : [{
                source: "fedora",
                kind: "dnf",
                ref: rowData.id
            }])
        });
    }

    // Reparented into the window's overlay layer so the dim covers everything
    property var overlayParent: null

    AppDetailsDialog {
        id: detailsDialog

        parent: view.overlayParent || view

        property var entry: null
        readonly property string entryId: entry ? entry.id : ""
        readonly property bool entryIsFlatpak: entry ? entry.kind === "flatpak" : false
        readonly property bool entryIsAppimage: entry ? entry.kind === "appimage" : false

        showHoldToggle: !entryIsAppimage
        showUninstall: true
        showOpenButton: entryIsFlatpak || entryIsAppimage
        openCommand: entryIsAppimage && entry.file ? [entry.file] : []
        showUpdateSource: entryIsAppimage
        updateSourceRepo: entryIsAppimage ? (entry.repo || "") : ""
        busy: entryId !== "" && view.busyAction.endsWith(":" + entryId)
        busyDetail: view.mutationProgress
        busyFraction: view.mutationFraction
        releases: (entryIsFlatpak && entry.info && entry.info.releases) ? entry.info.releases.slice(0, 3) : []
        changelogLoading: entry !== null && !entryIsFlatpak && !entryIsAppimage && view.store.changelogs[entryId] === undefined
        changelog: (entry !== null && !entryIsFlatpak && !entryIsAppimage) ? (view.store.changelogs[entryId] || "") : ""
        versionsLoading: {
            if (!entry || entryIsAppimage)
                return false;
            return entryIsFlatpak ? view.downgradeLogs[entryId] === "loading" : view.rpmVersions[entryId] === "loading";
        }
        previousVersions: {
            if (!entry || entryIsAppimage)
                return [];
            if (entryIsFlatpak) {
                const log = view.downgradeLogs[entryId];
                return (log && log !== "loading") ? log.map(c => ({
                    label: c.date || c.commit.substring(0, 8),
                    payload: c.commit
                })) : [];
            }
            const versions = view.rpmVersions[entryId];
            return Array.isArray(versions) ? versions.map(v => ({
                label: v,
                payload: v
            })) : [];
        }
        noOlderVersions: entry !== null && !entryIsFlatpak && !entryIsAppimage && Array.isArray(view.rpmVersions[entryId]) && view.rpmVersions[entryId].length === 0
        alsoRemoves: (entry !== null && !entryIsFlatpak && !entryIsAppimage) ? (view.removalImpact[entryId] || []) : []
        provenance: (entry !== null && !entryIsFlatpak && !entryIsAppimage) ? (view.provenance[entryId] || null) : null

        onHoldToggleRequested: {
            view.toggleHold(entryId);
            app = Object.assign({}, app, {
                held: view.isHeldName(entryId)
            });
        }

        onUpdateSourceSaveRequested: link => {
            updateSourceStatus = "saving";
            appimageRepoProcess.command = ["python3", Qt.resolvedUrl("scripts/appimage.py").toString().replace("file://", ""), "--set-repo", entryId, link];
            appimageRepoProcess.running = true;
        }

        onUninstallRequested: {
            const target = entry;
            close();
            if (target.kind === "appimage")
                view.uninstallAppimage(target.id, target.name);
            else if (target.kind === "flatpak")
                view.uninstallFlatpak(target.id);
            else
                view.uninstallRpm(target.id, target.name);
        }

        onRestoreRequested: payload => {
            const target = entry;
            close();
            if (target.kind === "flatpak")
                view.downgradeTo(target.id, payload);
            else
                view.downgradeRpm(target.id, payload);
        }
    }

    property var flatpakApps: []     // {id, version, origin, installation}
    property var rpmPackages: []     // {name, version}
    property var meta: ({})          // "flatpak/<id>" -> enrichment info
    property bool loading: true
    property string searchText: ""
    property int sourceFilter: 0     // 0 all, 1 flatpak, 2 system
    property string busyAction: ""   // "<action>:<id>" while a mutation runs
    property string mutationProgress: ""  // live phase/percent line while mutationProcess runs
    property real mutationFraction: 0     // 0..1 overall progress estimate
    property var downgradeLogs: ({}) // id -> [{commit, date}] | "loading"
    property var rpmVersions: ({})   // name -> [version strings older than installed] | "loading"
    // name -> [other packages the resolver would remove along with it]
    property var removalImpact: ({})

    // Asks the helper to resolve the removal without running it — no root,
    // no changes — so the popup can say what a click would cost before the
    // click happens.
    function loadRemovalImpact(name) {
        if (removalImpact[name] !== undefined || removalPlanProcess.running)
            return;
        removalPlanProcess._target = name;
        removalPlanProcess._others = [];
        removalPlanProcess.command = Backend.planCommand("remove", [name]);
        removalPlanProcess.running = true;
    }

    // name -> {userInstalled, requiredBy, requiredByCount}
    property var provenance: ({})

    function loadProvenance(name) {
        if (provenance[name] !== undefined || provenanceProcess.running)
            return;
        provenanceProcess._target = name;
        provenanceProcess.command = Backend.provenanceCommand(name);
        provenanceProcess.running = true;
    }

    Process {
        id: provenanceProcess

        property string _target: ""

        stdout: StdioCollector {
            onStreamFinished: {
                const updated = Object.assign({}, view.provenance);
                try {
                    updated[provenanceProcess._target] = JSON.parse(text);
                } catch (e) {
                    updated[provenanceProcess._target] = null;
                }
                view.provenance = updated;
            }
        }
    }

    Process {
        id: removalPlanProcess

        property string _target: ""
        property var _others: []

        stdout: SplitParser {
            onRead: line => {
                let event;
                try {
                    event = JSON.parse(line);
                } catch (e) {
                    return;
                }
                if (event.event !== "plan")
                    return;
                const others = [];
                for (const op of event.ops || []) {
                    if (op.name !== removalPlanProcess._target && /remove|obsolet/i.test(op.action || ""))
                        others.push(op.name);
                }
                removalPlanProcess._others = others;
            }
        }

        onExited: (exitCode, exitStatus) => {
            const updated = Object.assign({}, view.removalImpact);
            updated[_target] = _others;
            view.removalImpact = updated;
        }
    }

    Component.onCompleted: {
        reload();
        Ui.steadyCursorFor(searchField);
        Ui.softenScrollbar(installedList);
    }

    property var appimageApps: []    // records from scripts/appimage.py --list

    // Enrich both flatpaks and rpm packages (icons + friendly names); the
    // catalog scan is cached, so only the first pass after a catalog change
    // is expensive.
    function _requestEnrich() {
        const request = {
            rpm: rpmPackages.map(pkg => ({
                        name: pkg.name,
                        from: ""
                    })),
            flatpak: flatpakApps.map(app => ({
                        name: app.id,
                        from: ""
                    }))
        };
        if (request.rpm.length === 0 && request.flatpak.length === 0)
            return;
        if (enrichProcess.running) {
            _enrichPending = true;
            return;
        }
        enrichProcess.command = ["python3", Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", ""), JSON.stringify(request)];
        enrichProcess.running = true;
    }

    property bool _enrichPending: false

    function reload() {
        loading = true;
        flatpakListProcess.running = true;
        rpmListProcess.running = true;
        appimageListProcess.running = true;
        desktopOwnersProcess.running = true;
    }

    Process {
        id: appimageListProcess
        command: ["python3", Qt.resolvedUrl("scripts/appimage.py").toString().replace("file://", ""), "--list"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    view.appimageApps = JSON.parse(text);
                } catch (e) {
                    view.appimageApps = [];
                }
            }
        }
    }

    Process {
        id: appimageMutationProcess

        property string _logTitle: ""
        property var _logItem: null

        stdout: StdioCollector {
            onStreamFinished: {}
        }

        onExited: (exitCode, exitStatus) => {
            view.busyAction = "";
            if (exitCode === 0) {
                if (view.logger && _logItem) {
                    _logItem.status = "done";
                    view.logger.record("uninstall", _logTitle, [_logItem]);
                }
                view.softwareMutated();
            }
            _logItem = null;
            view.reload();
        }
    }

    // Save the GitHub update source chosen in the details popup
    Process {
        id: appimageRepoProcess

        stdout: StdioCollector {
            onStreamFinished: {
                let result = null;
                try {
                    result = JSON.parse(text);
                } catch (e) {
                }
                if (result && result.ok === true) {
                    if (detailsDialog.entry && detailsDialog.entry.kind === "appimage")
                        detailsDialog.entry = Object.assign({}, detailsDialog.entry, {
                            repo: result.repo
                        });
                    detailsDialog.updateSourceStatus = "done";
                    view.softwareMutated();
                } else {
                    detailsDialog.updateSourceStatus = "error:" + ((result && result.error) || Tr.t("script failed"));
                }
            }
        }
    }

    function uninstallAppimage(id, name) {
        busyAction = "uninstall:" + id;
        appimageMutationProcess._logTitle = Tr.t("Uninstalled %1").arg(name);
        appimageMutationProcess._logItem = {
            name: name,
            id: id,
            repo: "appimage",
            from: "",
            to: "",
            source: "AppImage"
        };
        appimageMutationProcess.command = ["python3", Qt.resolvedUrl("scripts/appimage.py").toString().replace("file://", ""), "--uninstall", id];
        appimageMutationProcess.running = true;
    }

    // System packages that own a launchable desktop entry, as
    // {package: {icon, name}}. Flatpak apps and AppImages are applications
    // by definition; for rpm/deb/pacman packages this is what separates "a
    // program I installed" from the libraries, fonts and services that came
    // along with it — and it carries the icon and name the launcher shows,
    // which is the only one packages outside AppStream have.
    property var appPackages: ({})

    function _isApplication(row) {
        return row.kind !== "system" || appPackages[row.id] !== undefined;
    }

    readonly property var filteredItems: {
        const needle = searchText.toLowerCase();
        const rows = [];
        if (sourceFilter === 0 || sourceFilter === 1) {
            for (const app of flatpakApps) {
                const info = meta["flatpak/" + app.id] || null;
                const name = (info && info.name) ? info.name : app.id;
                const summary = info ? (info.summary || "") : "";
                if (needle && !Ui.matchesWords((name + " " + app.id + " " + summary).toLowerCase(), needle))
                    continue;
                rows.push({
                    kind: "flatpak",
                    id: app.id,
                    name: name,
                    summary: summary,
                    version: app.version,
                    origin: app.origin,
                    sizeBytes: app.sizeBytes || 0,
                    updatedTs: app.updatedTs || 0,
                    info: info
                });
            }
        }
        if (sourceFilter === 0 || sourceFilter === 3) {
            for (const rec of appimageApps) {
                if (needle && !Ui.matchesWords((rec.name + " " + rec.id).toLowerCase(), needle))
                    continue;
                rows.push({
                    kind: "appimage",
                    id: rec.id,
                    name: rec.name,
                    summary: "AppImage",
                    version: rec.tag || "",
                    origin: "appimage",
                    sizeBytes: rec.sizeBytes || 0,
                    updatedTs: rec.installedAt || 0,
                    file: rec.file || "",
                    repo: rec.repo || "",
                    info: {
                        name: rec.name,
                        summary: "",
                        homepage: rec.repo ? ("https://github.com/" + rec.repo) : "",
                        icon: rec.icon || "",
                        releases: []
                    }
                });
            }
        }
        if (sourceFilter === 0 || sourceFilter === 2) {
            for (const pkg of rpmPackages) {
                let info = meta["system/" + pkg.name] || null;
                // Packages outside AppStream (COPR builds, third-party
                // repos) have no metadata at all; their desktop entry still
                // knows the icon and name the launcher uses.
                const desktop = appPackages[pkg.name];
                if (desktop && (!info || !info.icon || !info.name)) {
                    info = Object.assign({
                        name: "",
                        summary: "",
                        homepage: "",
                        icon: "",
                        releases: []
                    }, info || {});
                    if (!info.icon)
                        info.icon = desktop.icon || "";
                    if (!info.name)
                        info.name = desktop.name || "";
                }
                const name = (info && info.name) ? info.name : pkg.name;
                const summary = info ? (info.summary || "") : "";
                if (needle && !Ui.matchesWords((name + " " + pkg.name + " " + summary).toLowerCase(), needle))
                    continue;
                rows.push({
                    kind: "system",
                    id: pkg.name,
                    name: name,
                    summary: summary,
                    version: pkg.version,
                    origin: "fedora",
                    sizeBytes: pkg.sizeBytes || 0,
                    updatedTs: pkg.updatedTs || 0,
                    info: info
                });
            }
        }
        // Applications come first in every sort order: the programs someone
        // installed to use are what this list is for, and the supporting
        // packages they dragged in are context underneath them.
        const appRank = row => view._isApplication(row) ? 0 : 1;
        switch (sortMode) {
        case "Largest":
            rows.sort((a, b) => (appRank(a) - appRank(b)) || (b.sizeBytes - a.sizeBytes) || a.name.localeCompare(b.name));
            break;
        case "Recently updated":
            rows.sort((a, b) => (appRank(a) - appRank(b)) || (b.updatedTs - a.updatedTs) || a.name.localeCompare(b.name));
            break;
        default:
            const kindRank = kind => kind === "flatpak" ? 0 : (kind === "appimage" ? 1 : 2);
            rows.sort((a, b) => {
                if (appRank(a) !== appRank(b))
                    return appRank(a) - appRank(b);
                if (kindRank(a.kind) !== kindRank(b.kind))
                    return kindRank(a.kind) - kindRank(b.kind);
                return a.name.localeCompare(b.name);
            });
            break;
        }
        // Mark where each group starts; the delegate draws a heading there.
        // Counting first means the heading can say how big its group is.
        let appCount = 0;
        for (const row of rows) {
            if (appRank(row) === 0)
                appCount++;
        }
        for (let i = 0; i < rows.length; i++) {
            const isApp = appRank(rows[i]) === 0;
            if (i > 0 && isApp === (appRank(rows[i - 1]) === 0))
                continue;
            rows[i].sectionLabel = isApp ? Tr.t("Applications") : Tr.t("System packages");
            rows[i].sectionCount = isApp ? appCount : rows.length - appCount;
            rows[i].sectionFirst = i === 0;
        }
        return rows;
    }

    // Sort order for the list
    property string sortMode: "Name"
    readonly property var sortOptions: ["Name", "Recently updated", "Largest"]

    function formatSize(bytes) {
        if (bytes >= 1e9)
            return (bytes / 1e9).toFixed(1) + " GB";
        if (bytes >= 1e6)
            return Math.round(bytes / 1e6) + " MB";
        if (bytes >= 1e3)
            return Math.max(1, Math.round(bytes / 1e3)) + " kB";
        return bytes > 0 ? bytes + " B" : "";
    }

    function isHeldName(name) {
        return (SettingsData.updaterIgnoredPackages || []).indexOf(name) !== -1;
    }

    function toggleHold(name) {
        if (isHeldName(name)) {
            SystemUpdateService.unignorePackage(name);
        } else {
            SystemUpdateService.ignorePackage(name);
        }
    }

    function _flatpakDisplayName(id) {
        const info = meta["flatpak/" + id] || null;
        return (info && info.name) ? info.name : id;
    }

    function _flatpakInstalledVersion(id) {
        for (const app of flatpakApps) {
            if (app.id === id)
                return app.version || "";
        }
        return "";
    }

    function uninstallFlatpak(id) {
        busyAction = "uninstall:" + id;
        mutationProgress = Tr.t("Starting…");
        mutationFraction = 0.02;
        mutationProcess._logType = "uninstall";
        mutationProcess._logTitle = Tr.t("Uninstalled %1").arg(_flatpakDisplayName(id));
        mutationProcess._logItem = {
            name: _flatpakDisplayName(id),
            id: id,
            repo: "flatpak",
            from: _flatpakInstalledVersion(id),
            to: "",
            source: "Flatpak"
        };
        mutationProcess.command = ["flatpak", "uninstall", "-y", "--noninteractive", id];
        mutationProcess.running = true;
    }

    function loadDowngradeLog(id, origin) {
        if (downgradeLogs[id] !== undefined)
            return;
        const updated = Object.assign({}, downgradeLogs);
        updated[id] = "loading";
        downgradeLogs = updated;
        logProcess._target = id;
        logProcess.command = ["sh", "-c", "LC_ALL=C flatpak remote-info --log " + origin + " " + id + " 2>/dev/null | grep -E '^\\s*(Commit|Date):' | head -20"];
        logProcess.running = true;
    }

    function downgradeTo(id, commit) {
        busyAction = "downgrade:" + id;
        mutationProgress = Tr.t("Waiting for authorization…");
        mutationFraction = 0.02;
        mutationProcess._logType = "downgrade";
        mutationProcess._logTitle = Tr.t("Restored previous version of %1").arg(_flatpakDisplayName(id));
        mutationProcess._logItem = {
            name: _flatpakDisplayName(id),
            from: _flatpakInstalledVersion(id),
            to: Tr.t("commit %1").arg(commit.substring(0, 8)),
            source: "Flatpak"
        };
        mutationProcess.command = ["pkexec", "flatpak", "update", "--noninteractive", "--commit=" + commit, id];
        mutationProcess.running = true;
    }

    function loadRpmVersions(name, installedVersion) {
        if (rpmVersions[name] !== undefined)
            return;
        const updated = Object.assign({}, rpmVersions);
        updated[name] = "loading";
        rpmVersions = updated;
        rpmVersionsProcess._target = name;
        rpmVersionsProcess._installed = installedVersion;
        rpmVersionsProcess.command = Backend.availableVersionsCommand(name);
        rpmVersionsProcess.running = true;
    }

    function uninstallRpm(name, displayName) {
        busyAction = "uninstall:" + name;
        mutationProgress = Tr.t("Waiting for authorization…");
        mutationFraction = 0.02;
        mutationProcess._logType = "uninstall";
        mutationProcess._logTitle = Tr.t("Uninstalled %1").arg(displayName || name);
        mutationProcess._logItem = {
            name: displayName || name,
            from: "",
            to: "",
            source: "System"
        };
        mutationProcess.command = Backend.helperCommand("remove", [name]);
        mutationProcess.running = true;
    }

    function downgradeRpm(name, version) {
        busyAction = "downgrade:" + name;
        mutationProgress = Tr.t("Waiting for authorization…");
        mutationFraction = 0.02;
        mutationProcess._logType = "downgrade";
        mutationProcess._logTitle = Tr.t("Downgraded %1").arg(name);
        mutationProcess._logItem = {
            name: name,
            from: "",
            to: version,
            source: "System"
        };
        mutationProcess.command = Backend.helperCommand("downgrade", [name + "-" + version]);
        mutationProcess.running = true;
    }

    // ── Data collection ──────────────────────────────────────────────────────
    Process {
        id: flatpakListProcess
        // size column is human readable; the deploy dir mtime gives the last
        // install/update moment
        command: ["sh", "-c", "LC_ALL=C flatpak list --app --columns=application,version,origin,installation,size 2>/dev/null | while IFS=$'\\t' read -r id ver origin inst size; do base=/var/lib/flatpak; [ \"$inst\" = user ] && base=\"$HOME/.local/share/flatpak\"; ts=$(stat -c %Y \"$base/app/$id/current/active\" 2>/dev/null || echo 0); printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \"$id\" \"$ver\" \"$origin\" \"$inst\" \"$size\" \"$ts\"; done"]

        function parseSize(text) {
            const match = /^([\d.,]+)\s*(kB|MB|GB|B)?/.exec((text || "").replace(",", "."));
            if (!match)
                return 0;
            const value = parseFloat(match[1]) || 0;
            switch (match[2]) {
            case "GB":
                return value * 1e9;
            case "MB":
                return value * 1e6;
            case "kB":
                return value * 1e3;
            default:
                return value;
            }
        }

        stdout: StdioCollector {
            onStreamFinished: {
                const apps = [];
                const ids = [];
                for (const line of text.trim().split("\n")) {
                    const parts = line.split("\t");
                    if (parts.length >= 3 && parts[0]) {
                        apps.push({
                            id: parts[0],
                            version: parts[1] || "",
                            origin: parts[2] || "",
                            installation: parts[3] || "system",
                            sizeBytes: flatpakListProcess.parseSize(parts[4]),
                            updatedTs: parseInt(parts[5], 10) || 0
                        });
                        ids.push(parts[0]);
                    }
                }
                view.flatpakApps = apps;
                view._requestEnrich();
            }
        }
    }

    Process {
        id: rpmListProcess
        command: Backend.installedTableCommand()

        stdout: StdioCollector {
            onStreamFinished: {
                const pkgs = [];
                for (const line of text.trim().split("\n")) {
                    const parts = line.split("\t");
                    if (parts.length >= 2 && parts[0])
                        pkgs.push({
                            name: parts[0],
                            version: parts[1],
                            sizeBytes: parseInt(parts[2], 10) || 0,
                            updatedTs: parseInt(parts[3], 10) || 0
                        });
                }
                view.rpmPackages = pkgs;
                view._requestEnrich();
                view.loading = false;
            }
        }
    }

    Process {
        id: desktopOwnersProcess
        command: Backend.desktopOwnersCommand()

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    view.appPackages = JSON.parse(text) || ({});
                } catch (e) {
                    view.appPackages = ({});
                }
            }
        }
    }

    Process {
        id: enrichProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(text);
                    const merged = {};
                    for (const name in (data.flatpak || {}))
                        merged["flatpak/" + name] = data.flatpak[name];
                    for (const name in (data.rpm || {}))
                        merged["system/" + name] = data.rpm[name];
                    view.meta = merged;
                } catch (e) {
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (view._enrichPending) {
                view._enrichPending = false;
                view._requestEnrich();
            }
        }
    }

    function _formatBytes(bytes) {
        if (!bytes || bytes <= 0)
            return "";
        if (bytes >= 1e9)
            return (bytes / 1e9).toFixed(1) + " GB";
        if (bytes >= 1e6)
            return Math.round(bytes / 1e6) + " MB";
        return Math.max(1, Math.round(bytes / 1e3)) + " kB";
    }

    // rpm mutations run through rpm_helper.py (libdnf5) and report NDJSON
    // events; flatpak output still arrives as raw lines below.
    property real _mutPlanBytes: 0
    property real _mutLastOverall: 0
    property int _mutIdx: 0
    property int _mutTot: 0

    function _mutationEvent(event) {
        const removing = mutationProcess._logType === "uninstall";
        const part = Math.min(100, event.percent || 0) / 100;
        switch (event.event) {
        case "status":
            mutationFraction = 0.1;
            mutationProgress = Tr.t("Loading repositories…");
            break;
        case "plan":
            _mutPlanBytes = event.totalDownloadBytes || 0;
            _mutLastOverall = 0;
            _mutIdx = 0;
            _mutTot = 0;
            mutationFraction = 0.3;
            mutationProgress = _mutPlanBytes > 0 ? Tr.t("Downloading (%1)…").arg(_formatBytes(_mutPlanBytes)) : Tr.t("Applying changes…");
            break;
        case "op-start":
            if (event.phase === "install" || event.phase === "remove") {
                _mutIdx = event.index || (_mutIdx + 1);
                _mutTot = event.total || _mutTot;
                mutationFraction = Math.max(mutationFraction, 0.55);
                mutationProgress = (removing ? Tr.t("Removing") : Tr.t("Applying")) + " " + _mutIdx + "/" + Math.max(1, _mutTot);
            }
            break;
        case "progress":
            if (event.phase === "install" || event.phase === "remove") {
                const tot = Math.max(1, _mutTot);
                const overall = Math.min(1, (Math.max(0, _mutIdx - 1) + part) / tot);
                mutationFraction = 0.55 + 0.45 * overall;
                mutationProgress = (removing ? Tr.t("Removing") : Tr.t("Applying")) + " " + _mutIdx + "/" + tot + " · " + Math.round(overall * 100) + "%";
            } else if (event.totalTransferred !== undefined && _mutPlanBytes > 0) {
                let overall = Math.min(1, event.totalTransferred / _mutPlanBytes);
                overall = Math.max(_mutLastOverall, overall);
                _mutLastOverall = overall;
                mutationFraction = 0.3 + 0.25 * overall;
                mutationProgress = Tr.t("Downloading") + " · " + Math.round(overall * 100) + "%";
            }
            break;
        }
    }

    // Short progress message from a raw dnf5/flatpak output line, with labels
    // that fit removals and downgrades alike. dnf5 piped output: "Updating and
    // loading repositories:", "Repositories loaded.", then
    // "[x/y] <package or transaction step> … NN% | speed | size | time".
    function _mutationLine(raw) {
        const line = raw.trim();
        if (line === "")
            return;
        if (line[0] === "{") {
            let event = null;
            try {
                event = JSON.parse(line);
            } catch (e) {
                return;
            }
            _mutationEvent(event);
            return;
        }
        if (line.indexOf("Updating and loading repositories") === 0) {
            mutationFraction = 0.1;
            mutationProgress = Tr.t("Loading repositories…");
            return;
        }
        if (line.indexOf("Repositories loaded") === 0) {
            mutationFraction = 0.3;
            mutationProgress = Tr.t("Resolving dependencies…");
            return;
        }
        if (line.indexOf("Running transaction") === 0) {
            mutationFraction = Math.max(mutationFraction, 0.5);
            mutationProgress = Tr.t("Applying changes…");
            return;
        }
        // Uninstalls download nothing, so a step line that isn't a recognized
        // transaction keyword is still removal work — never label it Downloading.
        const removing = mutationProcess._logType === "uninstall";
        const step = /^\[\s*(\d+)\s*\/\s*(\d+)\s*\]\s*(.*)/.exec(line);
        if (step) {
            const x = parseInt(step[1], 10);
            const y = Math.max(1, parseInt(step[2], 10));
            const rest = step[3] || "";
            const transaction = removing || /^(Verify|Prepare|Installing|Upgrading|Reinstalling|Downgrading|Running|Cleanup|Removing|Erasing)/.test(rest);
            const pct = /(\d{1,3})%/.exec(rest);
            const part = Math.min(1, (x - 1 + (pct ? Math.min(100, parseInt(pct[1], 10)) / 100 : 0)) / y);
            mutationFraction = transaction ? 0.5 + 0.5 * part : 0.3 + 0.2 * part;
            // Stage-wide percentage — the per-item percent reads oddly ("16/24 · 100%")
            const label = removing ? Tr.t("Removing") : (transaction ? Tr.t("Applying") : Tr.t("Downloading"));
            mutationProgress = label + " " + x + "/" + y + " · " + Math.round(part * 100) + "%";
            return;
        }
        const pct = /(\d{1,3})%/.exec(line);
        if (pct) {
            const part = Math.min(100, parseInt(pct[1], 10)) / 100;
            mutationFraction = 0.3 + 0.6 * part;
            mutationProgress = (removing ? Tr.t("Removing") : Tr.t("Downloading")) + " · " + pct[1] + "%";
        } else if (line.indexOf("Uninstalling") === 0) {
            mutationFraction = Math.max(mutationFraction, 0.5);
            mutationProgress = Tr.t("Applying changes…");
        }
    }

    Process {
        id: mutationProcess

        property string _logType: ""
        property string _logTitle: ""
        property var _logItem: null

        stdout: SplitParser {
            onRead: line => view._mutationLine(line)
        }

        stderr: SplitParser {
            onRead: line => view._mutationLine(line)
        }

        onExited: (exitCode, exitStatus) => {
            view.busyAction = "";
            view.mutationProgress = "";
            view.mutationFraction = 0;
            view.downgradeLogs = {};
            if (exitCode === 0) {
                if (view.logger && _logType !== "") {
                    _logItem.status = "done";
                    view.logger.record(_logType, _logTitle, [_logItem]);
                }
                // The serial bump this triggers reloads our own list too
                view.softwareMutated();
            } else {
                view.reload();
            }
            _logType = "";
            SystemUpdateService.checkForUpdates();
        }
    }

    Process {
        id: rpmVersionsProcess

        property string _target: ""
        property string _installed: ""

        stdout: StdioCollector {
            onStreamFinished: {
                const versions = [];
                const raw = text.trim();
                if (raw.startsWith("[")) {
                    // apt backend: JSON array, newest first, installed flagged
                    try {
                        const list = JSON.parse(raw);
                        let past = false;
                        for (const entry of list) {
                            if (entry.installed) {
                                past = true;
                                continue;
                            }
                            if (past)
                                versions.unshift(entry.version);
                        }
                    } catch (e) {
                    }
                } else {
                    for (const line of raw.split("\n")) {
                        const version = line.trim();
                        // Keep only versions different from (and listed before)
                        // the installed one — sort -V put them in ascending order
                        if (version && version !== rpmVersionsProcess._installed)
                            versions.push(version);
                        else if (version === rpmVersionsProcess._installed)
                            break;
                    }
                }
                const updated = Object.assign({}, view.rpmVersions);
                updated[rpmVersionsProcess._target] = versions.slice(-3).reverse();
                view.rpmVersions = updated;
            }
        }
    }

    Process {
        id: logProcess

        property string _target: ""

        stdout: StdioCollector {
            onStreamFinished: {
                const entries = [];
                let current = {};
                for (const line of text.split("\n")) {
                    const commitMatch = /Commit:\s*([0-9a-f]+)/.exec(line);
                    const dateMatch = /Date:\s*(.+)/.exec(line);
                    if (commitMatch) {
                        current = {
                            commit: commitMatch[1]
                        };
                    } else if (dateMatch && current.commit) {
                        current.date = dateMatch[1].trim().split(" ")[0];
                        entries.push(current);
                        current = {};
                    }
                }
                const updated = Object.assign({}, view.downgradeLogs);
                // First entry is the newest (usually what's installed) — offer
                // the ones after it as "previous versions".
                updated[logProcess._target] = entries.slice(1, 4);
                view.downgradeLogs = updated;
            }
        }
    }

    // ── UI ───────────────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.spacingM

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingM

            DankTextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: Tr.t("Search installed software…")
                leftIconName: "search"
                showClearButton: true
                onTextChanged: view.searchText = text
                Keys.onEscapePressed: event => {
                    if (text !== "") {
                        clear();
                    } else {
                        event.accepted = false;
                    }
                }

                // The Keys handler above only sees Esc while the field has
                // focus; after e.g. an uninstall the focus is elsewhere.
                // Catch Esc window-wide as long as the popup doesn't need it.
                Shortcut {
                    sequence: "Escape"
                    enabled: view.visible && searchField.text !== "" && !detailsDialog.visible
                    onActivated: searchField.clear()
                }
            }

        }

        // Second toolbar row: source filter + sorting (wraps cleanly at
        // narrow window widths)
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingM

            DankButtonGroup {
                id: filterGroup
                model: [Tr.t("All"), "Flatpak", Tr.t("System"), "AppImage"]
                currentIndex: view.sourceFilter
                onSelectionChanged: (index, selected) => {
                    if (selected)
                        view.sourceFilter = index;
                }
            }

            Item {
                Layout.fillWidth: true
            }

            DankDropdown {
                dropdownWidth: 170
                alignPopupRight: true
                options: view.sortOptions.map(o => Tr.t(o))
                currentValue: Tr.t(view.sortMode)
                onValueChanged: value => {
                    for (const option of view.sortOptions) {
                        if (Tr.t(option) === value) {
                            view.sortMode = option;
                            return;
                        }
                    }
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: !view.loading
            text: {
                const total = view.filteredItems.length;
                const flatpakCount = view.flatpakApps.length;
                const rpmCount = view.rpmPackages.length;
                return Tr.t("%1 shown · %2 Flatpak apps · %3 system packages").arg(total).arg(flatpakCount).arg(rpmCount);
            }
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
        }

        DankListView {
            id: installedList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Theme.spacingXS
            model: view.filteredItems
            visible: !view.loading

            // A row, optionally under the heading that opens its group
            delegate: Column {
                id: rowWrap

                required property var modelData

                width: installedList.width
                spacing: Theme.spacingXS

                Item {
                    width: parent.width
                    visible: (rowWrap.modelData.sectionLabel || "") !== ""
                    height: visible ? sectionHeading.implicitHeight + (rowWrap.modelData.sectionFirst ? Theme.spacingXS : Theme.spacingL) : 0

                    StyledText {
                        id: sectionHeading
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: Theme.spacingS
                        text: (rowWrap.modelData.sectionLabel || "") + " · " + (rowWrap.modelData.sectionCount || 0)
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.surfaceVariantText
                    }
                }

                Rectangle {
                    id: row

                    readonly property var modelData: rowWrap.modelData
                    readonly property bool isFlatpak: modelData.kind === "flatpak"
                    readonly property bool held: view.isHeldName(modelData.id)
                    readonly property bool busy: view.busyAction.endsWith(":" + modelData.id)

                    width: rowWrap.width
                    implicitHeight: rowContent.implicitHeight + Theme.spacingS * 2
                    radius: Theme.cornerRadius
                    color: rowHover.hovered ? Theme.surfaceContainerHigh : Theme.withAlpha(Theme.surfaceContainerHigh, 0.45)

                    HoverHandler {
                        id: rowHover
                    }

                    // Click opens the details popup with all info and actions
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: view.openDetails(row.modelData)
                    }

                    ColumnLayout {
                        id: rowContent
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacingS
                        anchors.rightMargin: Theme.spacingS
                        spacing: Theme.spacingS

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingM

                            Item {
                                Layout.preferredWidth: 32
                                Layout.preferredHeight: 32

                                Image {
                                    id: rowLogo
                                    anchors.fill: parent
                                    source: (row.modelData.info && row.modelData.info.icon) ? "file://" + row.modelData.info.icon : ""
                                    sourceSize.width: 64
                                    sourceSize.height: 64
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                    visible: status === Image.Ready
                                }

                                DankIcon {
                                    anchors.centerIn: parent
                                    visible: rowLogo.status !== Image.Ready
                                    name: row.modelData.kind === "system" ? "memory" : "apps"
                                    size: 20
                                    color: Theme.surfaceVariantText
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.spacingS

                                    StyledText {
                                        text: row.modelData.name
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                        Layout.maximumWidth: 380
                                    }

                                    Rectangle {
                                        visible: row.held
                                        Layout.preferredWidth: heldMark.implicitWidth + 12
                                        Layout.preferredHeight: 16
                                        radius: 8
                                        color: Theme.withAlpha(Theme.warning, 0.18)

                                        StyledText {
                                            id: heldMark
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

                                StyledText {
                                    Layout.fillWidth: true
                                    visible: text !== ""
                                    text: {
                                        const parts = [];
                                        if (row.modelData.version)
                                            parts.push(row.modelData.version);
                                        if (view.sortMode === "Largest" && row.modelData.sizeBytes > 0)
                                            parts.push(view.formatSize(row.modelData.sizeBytes));
                                        if (view.sortMode === "Recently updated" && row.modelData.updatedTs > 0)
                                            parts.push(new Date(row.modelData.updatedTs * 1000).toLocaleDateString(Qt.locale(), Locale.ShortFormat));
                                        if (row.modelData.summary)
                                            parts.push(row.modelData.summary);
                                        return parts.join(" · ");
                                    }
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                }
                            }

                            StyledText {
                                visible: row.busy && view.mutationProgress !== ""
                                text: view.mutationProgress
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: Theme.primary
                            }

                            M3WaveProgress {
                                visible: row.busy && view.mutationFraction > 0
                                Layout.preferredWidth: 90
                                Layout.preferredHeight: 16
                                value: view.mutationFraction
                                isPlaying: visible
                            }

                            DankSpinner {
                                visible: row.busy && view.mutationFraction <= 0
                                size: 22
                            }
                        }
                    }
                }
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: view.loading

            Column {
                anchors.centerIn: parent
                spacing: Theme.spacingM

                DankSpinner {
                    anchors.horizontalCenter: parent.horizontalCenter
                    size: 40
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Tr.t("Loading installed software…")
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                }
            }
        }
    }

}
