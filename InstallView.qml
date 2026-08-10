import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

// Install tab: live search across Fedora repos and Flathub (AppStream-based),
// with ODRS star ratings, a source choice when software is available from
// multiple sources, and a most-popular storefront shown before searching.
Item {
    id: view

    property var featured: []        // enrich.py --featured output: [{category, items}]
    property string searchText: ""
    property int sourceFilter: 0     // 0 all, 1 flathub, 2 fedora
    property string busyAction: ""   // "<ref>" while an install runs
    property string lastInstallResult: ""
    property string installProgress: ""  // live phase/percent line while installProcess runs
    property int installStep: 0          // PhaseIndicator step: 0 check, 1 download, 2 install
    property real installFraction: 0     // 0..1 overall progress estimate
    property string installIcon: ""      // catalog icon (path or URL) of the app being installed
    property var installedFlatpaks: new Set()
    property var installedRpms: new Set()
    property var logger: null

    // Fired after a successful install so other views can refresh their lists
    signal softwareMutated()

    // Fired when what was installed only exists in the next deployment, so
    // the window can raise its reboot notice (atomic systems)
    signal stagedChange()

    // The sources panel lives in the window, because it is about the whole
    // system rather than about this tab — but this is where you stand when
    // the question comes up
    signal sourcesRequested()

    // Bumped by the window when software changed elsewhere (Installed tab,
    // update run) so the Installed-chips stay current.
    property int refreshSerial: 0

    onRefreshSerialChanged: installedProcess.running = true

    // Set from the command palette, which searches what is already in memory
    // and hands anything needing the repositories to this tab
    function setQuery(text) {
        searchField.text = text;
        searchText = text;
        searchField.forceActiveFocus();
    }

    function focusSearch() {
        searchField.forceActiveFocus();
    }

    // ── App details popup ────────────────────────────────────────────────────
    function openDetails(entry) {
        detailsDialog.entry = entry;
        detailsDialog.open({
            id: entry.id,
            name: entry.name,
            summary: entry.summary || "",
            descriptionHtml: entry.descriptionHtml || "",
            screenshots: entry.screenshots || [],
            iconPath: entry.icon || "",
            homepage: entry.homepage || "",
            rating: entry.rating || null,
            sources: entry.sources
        });
    }

    // Reparented into the window's overlay layer so the dim covers everything
    property var overlayParent: null

    AppDetailsDialog {
        id: detailsDialog

        parent: view.overlayParent || view

        property var entry: null

        showInstallButtons: true
        installedChipVisible: entry ? view.isInstalled(entry) : false
        showOpenButton: entry !== null && entry.sources.some(s => s.kind === "flatpak" && view.installedFlatpaks.has(s.ref.toLowerCase()))
        busy: entry ? entry.sources.some(s => s.ref !== "" && view.sourceKey(s) === view.busyAction) : false
        busyDetail: view.installProgress
        busyFraction: view.installFraction

        onInstallRequested: source => view.install(source, entry.name, entry.icon || "")
    }

    readonly property string scriptPath: Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", "")

    Component.onCompleted: {
        installedProcess.running = true;
        featuredProcess.running = true;
        indexProcess.running = true;
        appimageIndexProcess.running = true;
        appimageListProcess.running = true;
        Ui.steadyCursorFor(searchField);
        Ui.softenScrollbar(resultsList);
    }

    Process {
        id: appimageIndexProcess
        command: ["python3", Qt.resolvedUrl("scripts/appimage.py").toString().replace("file://", ""), "--index"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const raw = JSON.parse(text);
                    view.appimageIndex = raw.map(e => ({
                                id: e.id,
                                name: e.name,
                                summary: e.summary || "",
                                descriptionHtml: e.descriptionHtml || "",
                                screenshots: e.screenshots || [],
                                homepage: e.homepage || "",
                                icon: e.iconUrl || "",
                                updated: 0,
                                rating: null,
                                nl: e.nl,
                                ne: e.nl,
                                il: e.id,
                                pl: "",
                                sl: e.sl || "",
                                sources: [{
                                        source: "appimage",
                                        kind: "appimage",
                                        ref: e.repo || e.download,
                                        repo: e.repo || "",
                                        download: e.download || ""
                                    }]
                            }));
                } catch (e) {
                    view.appimageIndex = [];
                }
            }
        }
    }

    Process {
        id: appimageListProcess
        command: ["python3", Qt.resolvedUrl("scripts/appimage.py").toString().replace("file://", ""), "--list"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const ids = new Set();
                    for (const rec of JSON.parse(text))
                        ids.add(rec.id);
                    view.installedAppimages = ids;
                } catch (e) {
                }
            }
        }
    }

    // Install an AppImage from the catalog (GitHub release) or from a
    // user-supplied URL / local file
    property string appimageBusy: ""

    function installAppimage(args, label) {
        if (appimageInstallProcess.running)
            return;
        appimageBusy = label;
        lastInstallResult = "";
        appimageInstallProcess._label = label;
        appimageInstallProcess.command = ["python3", scriptPath.replace("enrich.py", "appimage.py")].concat(args);
        appimageInstallProcess.running = true;
    }

    Process {
        id: appimageInstallProcess

        property string _label: ""

        stdout: SplitParser {
            onRead: line => {
                let event;
                try {
                    event = JSON.parse(line);
                } catch (e) {
                    return;
                }
                if (event.event === "progress" && event.total > 0)
                    view.lastInstallResult = appimageInstallProcess._label + " · " + event.percent + "%";
                else if (event.event === "error")
                    view.lastInstallResult = Tr.t("%1 failed (exit %2)").arg(appimageInstallProcess._label).arg(event.message || "?");
            }
        }

        onExited: (exitCode, exitStatus) => {
            view.appimageBusy = "";
            const failed = view.lastInstallResult.indexOf("%") === -1 && view.lastInstallResult !== "" && view.lastInstallResult.indexOf("✓") === -1;
            if (exitCode === 0 && !failed) {
                view.lastInstallResult = Tr.t("%1 installed ✓").arg(_label);
                if (view.logger)
                    view.logger.record("install", Tr.t("Installed %1").arg(_label), [{
                        name: _label,
                        id: _label,
                        repo: "appimage",
                        from: "",
                        to: "",
                        source: "AppImage",
                        status: "done"
                    }]);
                view.softwareMutated();
            } else if (view.lastInstallResult.indexOf("✓") === -1 && view.lastInstallResult.indexOf("%") !== -1) {
                view.lastInstallResult = Tr.t("%1 failed (exit %2)").arg(_label).arg(exitCode);
            }
            appimageListProcess.running = true;
            resultClearTimer.restart();
        }
    }

    // ── Installing an AppImage from a file ───────────────────────────────────
    // Both ways in end up here: the toolbar button opens the dialog empty,
    // and a .appimage double-clicked in the file manager opens it on that
    // file. The dialog does the reading and the asking; running the install
    // stays here, where the progress, the log entry and the refresh live.
    AppimageOfferDialog {
        id: offerDialog

        parent: view.overlayParent || view
        busy: view.appimageBusy !== ""

        onInstallRequested: (args, label) => view.installAppimage(args, label)
    }

    function offerAppimageFile(path) {
        offerDialog.openWithFile(path);
    }

    // ── Instant search ───────────────────────────────────────────────────────
    // The merged AppStream index is loaded into memory once, so filtering
    // happens locally on every keystroke. The dnf name fallback (CLI packages
    // without AppStream data) is slower and trickles in asynchronously.
    property var searchIndex: []
    property var appimageIndex: []
    property var installedAppimages: new Set()
    property bool indexLoading: true
    readonly property bool searching: searchMode && indexLoading
    property var dnfExtras: []
    property string dnfExtrasQuery: ""
    // True while the async dnf name search hasn't answered for the current query
    readonly property bool moreResultsPending: searchMode && dnfExtrasQuery !== searchText.trim()

    // ── Copr ─────────────────────────────────────────────────────────────────
    // Nothing in Copr is part of any index this machine has: a package built
    // there stays invisible to search until its project is enabled, which is
    // the wrong way round for software nobody has found yet. Asking the hub
    // is therefore possible — but on request, not on every keystroke: it is
    // someone else's server and it takes seconds, not milliseconds.
    property var coprResults: []
    property string coprQuery: ""     // the query coprResults answer
    property string coprError: ""
    property bool coprSearching: false

    function searchCopr() {
        const query = searchText.trim();
        if (query.length < 2 || coprProcess.running)
            return;
        coprError = "";
        coprSearching = true;
        coprProcess._query = query;
        coprProcess.command = Backend.coprSearchCommand(query);
        coprProcess.running = true;
    }

    onSearchTextChanged: {
        dnfDebounce.restart();
        // Results belong to the query they were asked for
        if (searchText.trim() !== coprQuery) {
            coprResults = [];
            coprError = "";
        }
    }

    Timer {
        id: dnfDebounce
        interval: 450
        onTriggered: view.runDnfSearch()
    }

    function runDnfSearch() {
        const query = searchText.trim();
        if (query.length < 2) {
            dnfExtras = [];
            dnfExtrasQuery = "";
            return;
        }
        if (dnfProcess.running) {
            dnfDebounce.restart();
            return;
        }
        dnfProcess._query = query;
        dnfProcess.command = ["python3", scriptPath, "--search-dnf", query];
        dnfProcess.running = true;
    }

    function localResults(query) {
        const needle = query.toLowerCase();
        const words = needle.split(/\s+/).filter(w => w !== "");
        const scored = [];
        const pool = searchIndex.concat(appimageIndex);
        for (const item of pool) {
            let score = -1;
            if (words.length <= 1) {
                if (item.nl === needle || item.ne === needle || item.il === needle)
                    score = 0;
                else if (item.nl.startsWith(needle) || item.ne.startsWith(needle))
                    score = 1;
                else if (item.nl.indexOf(needle) !== -1 || item.ne.indexOf(needle) !== -1 || item.il.indexOf(needle) !== -1 || item.pl.indexOf(needle) !== -1)
                    score = 2;
                else if (item.sl.indexOf(needle) !== -1)
                    score = 3;
            } else {
                // Multi-word AND search: every word must match somewhere,
                // order-independent
                const mainHay = item.nl + " " + item.ne + " " + item.il + " " + item.pl;
                let all = true;
                let allInMain = true;
                for (const word of words) {
                    const inMain = mainHay.indexOf(word) !== -1;
                    if (!inMain && item.sl.indexOf(word) === -1) {
                        all = false;
                        break;
                    }
                    if (!inMain)
                        allInMain = false;
                }
                if (all)
                    score = allInMain ? 2 : 3;
            }
            if (score >= 0)
                scored.push({
                    item: item,
                    score: score
                });
        }
        scored.sort((a, b) => {
            if (a.score !== b.score)
                return a.score - b.score;
            const countA = a.item.rating ? a.item.rating.count : 0;
            const countB = b.item.rating ? b.item.rating.count : 0;
            if (countA !== countB)
                return countB - countA;
            return a.item.name.localeCompare(b.item.name);
        });
        return scored.slice(0, 60).map(s => Object.assign({
                score: s.score
            }, s.item));
    }

    readonly property var filterKinds: ["", "flatpak", "dnf", "appimage", "copr"]

    function matchesSourceFilter(item) {
        if (sourceFilter === 0)
            return true;
        const wanted = filterKinds[sourceFilter] || "dnf";
        return item.sources.some(s => s.kind === wanted);
    }

    // Two Coprs can build a package of the same name, so what is busy is this
    // project's copy of it rather than the name
    function sourceKey(source) {
        return source.kind === "copr" ? source.project + ":" + source.ref : source.ref;
    }

    readonly property bool searchMode: searchText.trim().length >= 2
    readonly property int resultCount: {
        let count = 0;
        for (const row of listModel) {
            if (row.type === "app")
                count++;
        }
        return count;
    }

    // Sort order for search results
    property string sortMode: "Relevance"
    readonly property var sortOptions: ["Relevance", "Name", "Rating", "Popularity", "Recently updated"]

    function sortResults(items) {
        const sorted = items.slice();
        switch (sortMode) {
        case "Name":
            sorted.sort((a, b) => a.name.localeCompare(b.name));
            break;
        case "Rating":
            sorted.sort((a, b) => {
                const ratingA = a.rating ? a.rating.stars : -1;
                const ratingB = b.rating ? b.rating.stars : -1;
                if (ratingB !== ratingA)
                    return ratingB - ratingA;
                return (b.rating ? b.rating.count : 0) - (a.rating ? a.rating.count : 0);
            });
            break;
        case "Popularity":
            sorted.sort((a, b) => (b.rating ? b.rating.count : 0) - (a.rating ? a.rating.count : 0));
            break;
        case "Recently updated":
            sorted.sort((a, b) => (b.updated || 0) - (a.updated || 0));
            break;
        default:
            break;
        }
        return sorted;
    }

    // Flat model shared by search results and the featured storefront:
    // {type: "header", label} | {type: "app", data}
    readonly property var listModel: {
        const rows = [];
        if (searchMode) {
            const query = searchText.trim();
            let items = localResults(query);
            // Async dnf extras trickle in once repoquery finishes
            if (dnfExtrasQuery === query && dnfExtras.length > 0) {
                const covered = new Set();
                for (const item of items) {
                    for (const s of item.sources) {
                        if (s.kind === "dnf")
                            covered.add(s.ref);
                    }
                }
                for (const extra of dnfExtras) {
                    if (!covered.has(extra.sources[0].ref))
                        items.push(extra);
                }
            }
            if (sortMode === "Relevance")
                items.sort((a, b) => (a.score !== undefined ? a.score : 9) - (b.score !== undefined ? b.score : 9));
            else
                items = sortResults(items);
            for (const item of items) {
                if (matchesSourceFilter(item))
                    rows.push({
                        type: "app",
                        data: item
                    });
            }
            // Copr answers are kept apart rather than mixed in: they come from
            // a person rather than from the distribution, and that is the
            // first thing worth knowing about them
            if (coprQuery === query && coprResults.length > 0) {
                const coprRows = coprResults.filter(item => matchesSourceFilter(item));
                if (coprRows.length > 0) {
                    rows.push({
                        type: "header",
                        label: "Copr · built by individuals"
                    });
                    for (const item of coprRows)
                        rows.push({
                            type: "app",
                            data: item
                        });
                }
            }
            return rows;
        }
        for (const group of featured) {
            const items = group.items.filter(item => matchesSourceFilter(item));
            if (items.length === 0)
                continue;
            rows.push({
                type: "header",
                label: group.category
            });
            for (const item of items)
                rows.push({
                    type: "app",
                    data: item
                });
        }
        return rows;
    }

    function isInstalled(item) {
        for (const source of item.sources) {
            if (source.kind === "flatpak" && installedFlatpaks.has(source.ref.toLowerCase()))
                return true;
            if (source.kind === "dnf" && installedRpms.has(source.ref))
                return true;
            // A Copr row is installed only when the package on the machine
            // came out of that Copr: five of them can build the same name,
            // and the name alone would mark all five
            if (source.kind === "copr" && source.installed === true)
                return true;
            if (source.kind === "appimage" && installedAppimages.has(item.id))
                return true;
        }
        return false;
    }

    function install(source, itemName, itemIcon) {
        if (source.kind === "appimage") {
            if (source.repo)
                installAppimage(["--install-github", source.repo, itemName], itemName);
            else if (source.download)
                Qt.openUrlExternally(source.download);
            return;
        }
        busyAction = sourceKey(source);
        installIcon = itemIcon || "";
        lastInstallResult = "";
        installProcess._label = itemName;
        // The ref is what the log needs to lead back to this app later
        installProcess._id = source.ref || "";
        installProcess._source = source.kind === "flatpak" ? "Flatpak" : "System";
        installStep = 0;
        installFraction = 0.02;
        _fpOpCount = 0;
        _fpOpsDone = 0;
        _helperError = "";
        _staged = false;
        if (source.kind === "flatpak") {
            // The flatpak CLI is silent when piped; the libflatpak helper
            // emits NDJSON progress events instead (same one updates use).
            installProgress = Tr.t("Starting…");
            installProcess.command = ["python3", scriptPath.replace("enrich.py", "flatpak_helper.py"), "install", source.source, source.ref];
        } else {
            // rpm installs run through the backend helper: real per-package
            // byte progress as NDJSON events instead of scraping dnf output.
            // A package found in Copr brings its repository with it, added by
            // the same privileged run so it costs one password, not two.
            installProgress = Tr.t("Waiting for authorization…");
            installProcess.command = (source.kind === "copr" && !source.enabled) ? Backend.coprInstallCommand(source.project, [source.ref]) : Backend.helperCommand("install", [source.ref]);
        }
        installProcess.running = true;
    }

    Process {
        id: installedProcess
        command: ["sh", "-c", "LC_ALL=C flatpak list --app --columns=application 2>/dev/null; echo '---RPM---'; " + Backend.installedNamesShellFragment]

        stdout: StdioCollector {
            onStreamFinished: {
                const flatpaks = new Set();
                const rpms = new Set();
                let inRpm = false;
                for (const line of text.trim().split("\n")) {
                    const value = line.trim();
                    if (value === "---RPM---") {
                        inRpm = true;
                        continue;
                    }
                    if (!value)
                        continue;
                    if (inRpm)
                        rpms.add(value);
                    else
                        flatpaks.add(value.toLowerCase());
                }
                view.installedFlatpaks = flatpaks;
                view.installedRpms = rpms;
            }
        }
    }

    Process {
        id: featuredProcess
        command: ["python3", view.scriptPath, "--featured"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    view.featured = JSON.parse(text);
                } catch (e) {
                    view.featured = [];
                }
            }
        }
    }

    Process {
        id: indexProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    view.searchIndex = JSON.parse(text);
                } catch (e) {
                    view.searchIndex = [];
                }
                view.indexLoading = false;
            }
        }

        command: ["python3", view.scriptPath, "--qml-index"]

        onExited: (exitCode, exitStatus) => {
            view.indexLoading = false;
        }
    }

    Process {
        id: dnfProcess

        property string _query: ""

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    view.dnfExtras = JSON.parse(text);
                    view.dnfExtrasQuery = dnfProcess._query;
                } catch (e) {
                }
            }
        }
    }

    Process {
        id: coprProcess

        property string _query: ""

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const answer = JSON.parse(text);
                    view.coprResults = answer.items || [];
                    view.coprError = answer.error || "";
                } catch (e) {
                    view.coprResults = [];
                    view.coprError = Tr.t("Copr could not be reached.");
                }
                view.coprQuery = coprProcess._query;
            }
        }

        onExited: (exitCode, exitStatus) => {
            view.coprSearching = false;
            if (exitCode !== 0 && view.coprQuery !== coprProcess._query) {
                view.coprError = Tr.t("Copr could not be reached.");
                view.coprQuery = coprProcess._query;
            }
        }
    }

    // Turn a raw dnf5/flatpak output line into progress state: a short message,
    // a PhaseIndicator step and an overall 0..1 fraction (check 0–0.35,
    // download 0.35–0.65, install 0.65–1). dnf5 piped output: "Updating and
    // loading repositories:", "Repositories loaded.", "Total size of inbound
    // packages is 39 KiB. …", then
    // "[x/y] <package or transaction step> … NN% | speed | size | time".
    // Flatpak-helper transaction bookkeeping (ops = app + runtimes/extensions)
    property int _fpOpCount: 0
    property int _fpOpsDone: 0

    function _formatBytes(bytes) {
        if (!bytes || bytes <= 0)
            return "";
        if (bytes >= 1e9)
            return (bytes / 1e9).toFixed(1) + " GB";
        if (bytes >= 1e6)
            return Math.round(bytes / 1e6) + " MB";
        return Math.max(1, Math.round(bytes / 1e3)) + " kB";
    }

    // NDJSON event from flatpak_helper.py or rpm_helper.py. Flatpak events
    // carry no phase (download-dominated); the rpm helper tags each event
    // with download/install/remove and index/total for the rpm stage.
    property int _rpmIdx: 0
    property int _rpmTot: 0
    property real _planBytes: 0
    property real _lastOverall: 0

    function _installEvent(event) {
        const count = Math.max(1, _fpOpCount);
        const phase = event.phase || "";
        switch (event.event) {
        case "status":
            installStep = 0;
            installFraction = 0.1;
            installProgress = Tr.t("Loading repositories…");
            break;
        case "plan":
            _fpOpCount = (event.ops || []).length;
            _fpOpsDone = 0;
            _rpmIdx = 0;
            _rpmTot = 0;
            _planBytes = event.totalDownloadBytes || 0;
            _lastOverall = 0;
            installStep = 1;
            installFraction = 0.05;
            const total = _formatBytes(event.totalDownloadBytes);
            installProgress = total !== "" ? Tr.t("Downloading (%1)…").arg(total) : Tr.t("Downloading");
            break;
        case "op-start":
            if (phase === "install" || phase === "remove") {
                _rpmIdx = event.index || (_rpmIdx + 1);
                _rpmTot = event.total || _rpmTot;
                installStep = 2;
                installProgress = (phase === "remove" ? Tr.t("Removing") : Tr.t("Installing")) + " " + _rpmIdx + "/" + Math.max(1, _rpmTot);
            } else {
                installStep = 1;
                installProgress = Tr.t("Downloading") + " " + Math.min(_fpOpsDone + 1, count) + "/" + count;
            }
            break;
        case "progress":
            const part = Math.min(100, event.percent || 0) / 100;
            if (phase === "install" || phase === "remove") {
                const tot = Math.max(1, _rpmTot);
                const overall = Math.min(1, (Math.max(0, _rpmIdx - 1) + part) / tot);
                installStep = 2;
                installFraction = 0.65 + 0.3 * overall;
                installProgress = (phase === "remove" ? Tr.t("Removing") : Tr.t("Installing")) + " " + _rpmIdx + "/" + tot + " · " + Math.round(overall * 100) + "%";
            } else {
                // rpm has a real install stage after this; flatpak's download
                // dominates its whole transaction
                const span = installProcess._source === "System" ? 0.55 : 0.9;
                // Downloads run in parallel and their events interleave —
                // aggregate bytes (rpm helper) give a steady overall; the
                // per-event fallback (flatpak) is clamped monotonic.
                let overall;
                if (event.totalTransferred !== undefined && _planBytes > 0)
                    overall = Math.min(1, event.totalTransferred / _planBytes);
                else
                    overall = Math.min(1, (_fpOpsDone + part) / count);
                overall = Math.max(_lastOverall, overall);
                _lastOverall = overall;
                installStep = 1;
                installFraction = 0.05 + span * overall;
                // Transaction-wide percentage, not the current component's
                installProgress = Tr.t("Downloading") + " " + Math.min(_fpOpsDone + 1, count) + "/" + count + " · " + Math.round(overall * 100) + "%";
            }
            break;
        case "op-done":
            if (phase === "install" || phase === "remove")
                break;
            _fpOpsDone = Math.min(_fpOpsDone + 1, count);
            installFraction = 0.05 + (installProcess._source === "System" ? 0.55 : 0.9) * (_fpOpsDone / count);
            if (_fpOpsDone >= count) {
                installStep = 2;
                installProgress = Tr.t("Installing…");
            }
            break;
        case "error":
            _helperError = event.message || "";
            break;
        case "done":
            // rpm-ostree writes the next boot rather than this one, and says
            // so. Claiming the package is ready would be a claim about a
            // system that does not have it yet.
            _staged = event.staged === true;
            break;
        }
    }

    // Last error message from a helper, shown with the failure result
    property string _helperError: ""
    // The helper wrote a deployment that takes effect at the next boot
    property bool _staged: false

    function _installLine(raw) {
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
            _installEvent(event);
            return;
        }
        if (line.indexOf("Updating and loading repositories") === 0) {
            installStep = 0;
            installFraction = 0.1;
            installProgress = Tr.t("Loading repositories…");
            return;
        }
        if (line.indexOf("Repositories loaded") === 0) {
            installStep = 0;
            installFraction = 0.25;
            installProgress = Tr.t("Resolving dependencies…");
            return;
        }
        const inbound = /Total size of inbound packages is ([0-9.,]+\s*\S+)/.exec(line);
        if (inbound) {
            installStep = 1;
            installFraction = 0.35;
            installProgress = Tr.t("Downloading (%1)…").arg(inbound[1]);
            return;
        }
        if (line.indexOf("Running transaction") === 0) {
            installStep = 2;
            installFraction = 0.65;
            installProgress = Tr.t("Installing…");
            return;
        }
        const step = /^\[\s*(\d+)\s*\/\s*(\d+)\s*\]\s*(.*)/.exec(line);
        if (step) {
            const x = parseInt(step[1], 10);
            const y = Math.max(1, parseInt(step[2], 10));
            const rest = step[3] || "";
            const transaction = /^(Verify|Prepare|Installing|Upgrading|Reinstalling|Downgrading|Running|Cleanup|Removing)/.test(rest);
            const pct = /(\d{1,3})%/.exec(rest);
            const part = Math.min(1, (x - 1 + (pct ? Math.min(100, parseInt(pct[1], 10)) / 100 : 0)) / y);
            installStep = transaction ? 2 : 1;
            installFraction = transaction ? 0.65 + 0.35 * part : 0.35 + 0.3 * part;
            // Stage-wide percentage — the per-item percent reads oddly ("16/24 · 100%")
            installProgress = (transaction ? Tr.t("Installing") : Tr.t("Downloading")) + " " + x + "/" + y + " · " + Math.round(part * 100) + "%";
            return;
        }
        // Flatpak's piped output has no bracket steps; keep whatever percent shows up
        const pct = /(\d{1,3})%/.exec(line);
        if (pct) {
            const part = Math.min(100, parseInt(pct[1], 10)) / 100;
            installStep = 1;
            installFraction = 0.3 + 0.6 * part;
            installProgress = Tr.t("Downloading") + " · " + pct[1] + "%";
        } else if (line.indexOf("Installing") === 0) {
            installStep = 2;
            installFraction = Math.max(installFraction, 0.7);
            installProgress = Tr.t("Installing…");
        }
    }

    Process {
        id: installProcess

        property string _label: ""
        property string _id: ""
        property string _source: ""

        stdout: SplitParser {
            onRead: line => view._installLine(line)
        }

        stderr: SplitParser {
            onRead: line => view._installLine(line)
        }

        onExited: (exitCode, exitStatus) => {
            view.busyAction = "";
            view.installProgress = "";
            view.installStep = 0;
            view.installFraction = 0;
            view.installIcon = "";
            view.lastInstallResult = exitCode === 0 ? (Tr.t("%1 installed ✓").arg(installProcess._label) + (view._staged ? " · " + Tr.t("takes effect after reboot") : "")) : (Tr.t("%1 failed (exit %2)").arg(installProcess._label).arg(exitCode) + (view._helperError !== "" ? " · " + view._helperError : ""));
            if (exitCode === 0) {
                if (view.logger) {
                    view.logger.record("install", Tr.t("Installed %1").arg(installProcess._label), [{
                        name: installProcess._label,
                        id: installProcess._id || installProcess._label,
                        repo: installProcess._source === "Flatpak" ? "flatpak" : "system",
                        from: "",
                        to: "",
                        source: installProcess._source,
                        status: "done"
                    }]);
                }
                view.softwareMutated();
                if (view._staged)
                    view.stagedChange();
                // Which Copr a package came from, and which Coprs are
                // configured, both just changed. The answer is cached, so
                // asking again costs nothing.
                if (view.coprQuery !== "" && view.coprQuery === view.searchText.trim())
                    view.searchCopr();
            }
            installedProcess.running = true;
            resultClearTimer.restart();
        }
    }

    Timer {
        id: resultClearTimer
        interval: 8000
        onTriggered: view.lastInstallResult = ""
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Theme.spacingM

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingM

            DankTextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: Tr.t("Search new software (%1 repos + Flathub)…").arg(Backend.systemRepoLabel)
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
                // focus; catch it window-wide as long as the popup doesn't
                // need it.
                Shortcut {
                    sequence: "Escape"
                    enabled: view.visible && searchField.text !== "" && !detailsDialog.visible
                    onActivated: searchField.clear()
                }
            }

            DankActionButton {
                buttonSize: 34
                iconName: "database"
                iconSize: 18
                iconColor: Theme.surfaceText
                tooltipText: Tr.t("Software sources")
                onClicked: view.sourcesRequested()
            }

            DankActionButton {
                buttonSize: 34
                iconName: "note_add"
                iconSize: 18
                iconColor: offerDialog.showing ? Theme.primary : Theme.surfaceText
                tooltipText: Tr.t("Install AppImage from file or URL")
                onClicked: offerDialog.open()
            }
        }

        // Second toolbar row: source filter + sorting (wraps cleanly at
        // narrow window widths)
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingM

            DankButtonGroup {
                model: Backend.hasCopr ? [Tr.t("All"), "Flathub", Backend.systemRepoLabel, "AppImage", "Copr"] : [Tr.t("All"), "Flathub", Backend.systemRepoLabel, "AppImage"]
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
                visible: view.searchMode
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

        // ── Copr, on request ─────────────────────────────────────────────────
        // The one search that leaves the machine, so it is the one search that
        // has to be asked for. What it finds is built by individuals, which is
        // said here rather than after the fact.
        Rectangle {
            Layout.fillWidth: true
            visible: view.searchMode && Backend.hasCopr
            implicitHeight: coprRow.implicitHeight + Theme.spacingS * 2
            radius: Theme.cornerRadius
            color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.45)

            RowLayout {
                id: coprRow

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingS
                spacing: Theme.spacingS

                DankIcon {
                    name: "person"
                    size: 16
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    Layout.fillWidth: true
                    text: {
                        if (view.coprSearching)
                            return Tr.t("Searching Copr…");
                        if (view.coprError !== "")
                            return Tr.t("Copr could not be reached.");
                        if (view.coprQuery === view.searchText.trim())
                            return view.coprResults.length > 0 ? Tr.t("%1 found in Copr, listed below").arg(view.coprResults.length) : Tr.t("Nothing in Copr for \"%1\"").arg(view.coprQuery);
                        return Tr.t("Not here? Copr has builds by individuals, for software Fedora does not ship.");
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: view.coprError !== "" ? Theme.error : Theme.surfaceVariantText
                    elide: Text.ElideRight
                }

                DankSpinner {
                    visible: view.coprSearching
                    size: 16
                }

                DankButton {
                    visible: !view.coprSearching && view.coprQuery !== view.searchText.trim()
                    buttonHeight: 26
                    horizontalPadding: Theme.spacingM
                    iconName: "search"
                    iconSize: 13
                    text: Tr.t("Search Copr")
                    backgroundColor: Theme.withAlpha(Theme.primary, 0.22)
                    textColor: Theme.surfaceText
                    onClicked: view.searchCopr()
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: view.searchMode && !view.indexLoading
            spacing: Theme.spacingS

            StyledText {
                text: (view.resultCount === 1 ? Tr.t("%1 result") : Tr.t("%1 results")).arg(view.resultCount)
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
            }

            // More results may still arrive from the dnf name fallback
            DankSpinner {
                visible: view.moreResultsPending
                size: 14
            }

            StyledText {
                Layout.fillWidth: true
                visible: ["Rating", "Popularity", "Recently updated"].indexOf(view.sortMode) !== -1
                text: Tr.t("Sorting uses app-catalog data — plain rpm packages without it are listed last.")
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignRight
            }
        }

        // Live install progress: same visual language as the Updates run
        // panel — phase stepper, animated wave bar and a detail row.
        Rectangle {
            Layout.fillWidth: true
            visible: view.busyAction !== ""
            implicitHeight: installProgressColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.surfaceContainer
            border.width: 1
            border.color: Theme.withAlpha(Theme.outline, 0.1)

            ColumnLayout {
                id: installProgressColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingS

                M3WaveProgress {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 18
                    value: view.installFraction
                    isPlaying: visible
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacingS

                    Item {
                        Layout.preferredWidth: 22
                        Layout.preferredHeight: 22
                        visible: view.installIcon !== ""

                        Image {
                            id: installProgressLogo
                            anchors.fill: parent
                            source: view.installIcon !== "" ? (view.installIcon.indexOf("http") === 0 ? view.installIcon : "file://" + view.installIcon) : ""
                            sourceSize.width: 44
                            sourceSize.height: 44
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            visible: status === Image.Ready
                        }

                        DankIcon {
                            anchors.centerIn: parent
                            visible: installProgressLogo.status !== Image.Ready
                            name: "apps"
                            size: 16
                            color: Theme.surfaceVariantText
                        }
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: installProcess._label
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    StyledText {
                        text: view.installProgress
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                        color: Theme.primary
                    }
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: view.busyAction === "" && view.lastInstallResult !== ""
            text: view.lastInstallResult
            font.pixelSize: Theme.fontSizeSmall
            color: view.lastInstallResult.indexOf("✓") !== -1 ? Theme.success : Theme.error
        }

        DankListView {
            id: resultsList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Theme.spacingXS
            model: view.listModel
            visible: view.listModel.length > 0 && !view.searching

            delegate: Loader {
                required property var modelData

                width: resultsList.width
                sourceComponent: modelData.type === "header" ? categoryHeaderComponent : appRowComponent

                onLoaded: item.rowData = modelData
            }
        }

        Component {
            id: categoryHeaderComponent

            Item {
                property var rowData: ({})

                implicitHeight: headerLabel.implicitHeight + Theme.spacingM

                StyledText {
                    id: headerLabel
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 2
                    text: Tr.t(rowData.label || "")
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.DemiBold
                    color: Theme.primary
                }
            }
        }

        Component {
            id: appRowComponent

            Rectangle {
                id: resultRow

                property var rowData: ({})

                readonly property var app: rowData.data || ({})
                readonly property bool installed: app.sources ? view.isInstalled(app) : false
                readonly property bool busy: app.sources ? app.sources.some(s => s.ref !== "" && (view.sourceKey(s) === view.busyAction || (view.appimageBusy !== "" && s.kind === "appimage" && view.appimageBusy === app.name))) : false

                implicitHeight: resultContent.implicitHeight + Theme.spacingS * 2
                radius: Theme.cornerRadius
                color: resultHover.hovered ? Theme.surfaceContainerHigh : Theme.withAlpha(Theme.surfaceContainerHigh, 0.45)

                HoverHandler {
                    id: resultHover
                }

                // Free-space click opens the details popup (buttons stay on top)
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: view.openDetails(resultRow.app)
                }

                RowLayout {
                    id: resultContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingS
                    spacing: Theme.spacingM

                    Item {
                        Layout.preferredWidth: 36
                        Layout.preferredHeight: 36

                        Image {
                            id: resultLogo
                            anchors.fill: parent
                            source: resultRow.app.icon ? (resultRow.app.icon.indexOf("http") === 0 ? resultRow.app.icon : "file://" + resultRow.app.icon) : ""
                            sourceSize.width: 72
                            sourceSize.height: 72
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            visible: status === Image.Ready
                        }

                        DankIcon {
                            anchors.centerIn: parent
                            visible: resultLogo.status !== Image.Ready
                            name: "apps"
                            size: 22
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
                                text: resultRow.app.name || ""
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                                Layout.maximumWidth: 320
                            }

                            // ODRS star rating
                            RowLayout {
                                visible: !!resultRow.app.rating
                                spacing: 1

                                Repeater {
                                    model: 5

                                    delegate: DankIcon {
                                        required property int index

                                        name: {
                                            const stars = resultRow.app.rating ? resultRow.app.rating.stars : 0;
                                            if (index + 0.75 <= stars)
                                                return "star";
                                            if (index + 0.25 <= stars)
                                                return "star_half";
                                            return "star";
                                        }
                                        filled: resultRow.app.rating && (index + 0.25 <= resultRow.app.rating.stars)
                                        size: 13
                                        color: resultRow.app.rating && (index + 0.25 <= resultRow.app.rating.stars) ? Theme.warning : Theme.withAlpha(Theme.surfaceVariantText, 0.5)
                                    }
                                }

                                StyledText {
                                    text: resultRow.app.rating ? (resultRow.app.rating.stars + " (" + resultRow.app.rating.count + ")") : ""
                                    font.pixelSize: Theme.fontSizeSmall - 2
                                    color: Theme.surfaceVariantText
                                }
                            }

                            Item {
                                Layout.fillWidth: true
                            }
                        }

                        StyledText {
                            Layout.fillWidth: true
                            visible: text !== ""
                            // Which Copr a package comes out of is the first
                            // thing to know about it, so it leads the line
                            text: {
                                const summary = resultRow.app.summary || "";
                                const copr = (resultRow.app.sources || []).find(s => s.kind === "copr");
                                if (!copr)
                                    return summary;
                                return summary !== "" ? copr.project + " · " + summary : copr.project;
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            elide: Text.ElideRight
                        }
                    }

                    DankSpinner {
                        visible: resultRow.busy
                        size: 22
                    }

                    Rectangle {
                        visible: resultRow.installed
                        Layout.preferredWidth: installedChip.implicitWidth + 14
                        Layout.preferredHeight: 20
                        radius: 10
                        color: Theme.withAlpha(Theme.success, 0.15)

                        StyledText {
                            id: installedChip
                            anchors.centerIn: parent
                            text: Tr.t("Installed")
                            font.pixelSize: Theme.fontSizeSmall - 2
                            color: Theme.success
                        }
                    }

                    // One install button per available source — the source
                    // choice when software ships from multiple sources
                    Repeater {
                        model: resultRow.installed ? [] : (resultRow.app.sources || [])

                        delegate: DankButton {
                            required property var modelData

                            buttonHeight: 28
                            horizontalPadding: Theme.spacingM
                            iconName: modelData.kind === "appimage" && !modelData.repo ? "open_in_new" : "download"
                            iconSize: 13
                            text: modelData.kind === "flatpak" ? "Flathub" : (modelData.kind === "appimage" ? "AppImage" : (modelData.kind === "copr" ? "Copr" : Backend.systemRepoLabel))
                            backgroundColor: modelData.kind === "flatpak" ? Theme.buttonBg : (modelData.kind === "appimage" ? Theme.withAlpha(Theme.tertiary, 0.25) : (modelData.kind === "copr" ? Theme.withAlpha(Theme.primary, 0.22) : Theme.secondaryContainer))
                            textColor: modelData.kind === "flatpak" ? Theme.buttonText : Theme.surfaceText
                            enabled: !resultRow.busy && view.busyAction === "" && view.appimageBusy === ""
                            onClicked: view.install(modelData, resultRow.app.name, resultRow.app.icon || "")
                        }
                    }
                }
            }
        }

        // States: idle hint / searching / no results
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: view.listModel.length === 0 || view.searching

            Column {
                anchors.centerIn: parent
                spacing: Theme.spacingM

                DankSpinner {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: view.searching
                    size: 36
                }

                DankIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: !view.searching
                    name: view.searchText.trim().length >= 2 ? "search_off" : "storefront"
                    size: 48
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: {
                        if (view.searching)
                            return Tr.t("Searching…");
                        if (view.searchMode)
                            return Tr.t("No results for \"%1\"").arg(view.searchText.trim());
                        return Tr.t("Type to search %1 repos and Flathub").arg(Backend.systemRepoLabel);
                    }
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: !view.searching && view.searchText.trim().length < 2
                    text: Tr.t("Ratings by the Open Desktop Ratings Service")
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.withAlpha(Theme.surfaceVariantText, 0.7)
                }
            }
        }
    }

}
