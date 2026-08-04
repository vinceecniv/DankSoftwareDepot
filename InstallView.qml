import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Modals.FileBrowser
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

    // Bumped by the window when software changed elsewhere (Installed tab,
    // update run) so the Installed-chips stay current.
    property int refreshSerial: 0

    onRefreshSerialChanged: installedProcess.running = true

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
        busy: entry ? entry.sources.some(s => s.ref !== "" && s.ref === view.busyAction) : false
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

    // Inline "install from file or URL" row
    property bool fileInstallOpen: false

    // DMS-native file browser for picking an existing .AppImage
    Loader {
        id: appimagePickerLoader
        active: false

        sourceComponent: FileBrowserModal {
            browserTitle: Tr.t("Choose an AppImage file")
            browserIcon: "note_add"
            browserType: "generic"
            fileExtensions: ["*.AppImage", "*.appimage"]

            onFileSelected: path => {
                fileInstallField.text = path.replace("file://", "");
            }
        }
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

    onSearchTextChanged: {
        dnfDebounce.restart();
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

    function matchesSourceFilter(item) {
        if (sourceFilter === 0)
            return true;
        const wanted = sourceFilter === 1 ? "flatpak" : (sourceFilter === 3 ? "appimage" : "dnf");
        return item.sources.some(s => s.kind === wanted);
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
        busyAction = source.ref;
        installIcon = itemIcon || "";
        lastInstallResult = "";
        installProcess._label = itemName;
        installProcess._source = source.kind === "flatpak" ? "Flatpak" : "System";
        installStep = 0;
        installFraction = 0.02;
        _fpOpCount = 0;
        _fpOpsDone = 0;
        if (source.kind === "flatpak") {
            // The flatpak CLI is silent when piped; the libflatpak helper
            // emits NDJSON progress events instead (same one updates use).
            installProgress = Tr.t("Starting…");
            installProcess.command = ["python3", scriptPath.replace("enrich.py", "flatpak_helper.py"), "install", source.source, source.ref];
        } else {
            installProgress = Tr.t("Waiting for authorization…");
            installProcess.command = ["pkexec", "dnf5", "install", "-y", source.ref];
        }
        installProcess.running = true;
    }

    Process {
        id: installedProcess
        command: ["sh", "-c", "LC_ALL=C flatpak list --app --columns=application 2>/dev/null; echo '---RPM---'; rpm -qa --qf '%{NAME}\\n' 2>/dev/null"]

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

    // NDJSON event from flatpak_helper.py install
    function _installEvent(event) {
        const count = Math.max(1, _fpOpCount);
        switch (event.event) {
        case "plan":
            _fpOpCount = (event.ops || []).length;
            _fpOpsDone = 0;
            installStep = 1;
            installFraction = 0.05;
            const total = _formatBytes(event.totalDownloadBytes);
            installProgress = total !== "" ? Tr.t("Downloading (%1)…").arg(total) : Tr.t("Downloading");
            break;
        case "op-start":
            installStep = 1;
            installProgress = Tr.t("Downloading") + " " + Math.min(_fpOpsDone + 1, count) + "/" + count;
            break;
        case "progress":
            const part = Math.min(100, event.percent || 0) / 100;
            const overall = Math.min(1, (_fpOpsDone + part) / count);
            installStep = 1;
            installFraction = 0.05 + 0.9 * overall;
            // Transaction-wide percentage, not the current component's
            installProgress = Tr.t("Downloading") + " " + Math.min(_fpOpsDone + 1, count) + "/" + count + " · " + Math.round(overall * 100) + "%";
            break;
        case "op-done":
            _fpOpsDone = Math.min(_fpOpsDone + 1, count);
            installFraction = 0.05 + 0.9 * (_fpOpsDone / count);
            if (_fpOpsDone >= count) {
                installStep = 2;
                installProgress = Tr.t("Installing…");
            }
            break;
        }
    }

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
            view.lastInstallResult = exitCode === 0 ? Tr.t("%1 installed ✓").arg(installProcess._label) : Tr.t("%1 failed (exit %2)").arg(installProcess._label).arg(exitCode);
            if (exitCode === 0) {
                if (view.logger) {
                    view.logger.record("install", Tr.t("Installed %1").arg(installProcess._label), [{
                        name: installProcess._label,
                        from: "",
                        to: "",
                        source: installProcess._source,
                        status: "done"
                    }]);
                }
                view.softwareMutated();
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
                placeholderText: Tr.t("Search new software (Fedora repos + Flathub)…")
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
                iconName: "note_add"
                iconSize: 18
                iconColor: view.fileInstallOpen ? Theme.primary : Theme.surfaceText
                tooltipText: Tr.t("Install AppImage from file or URL")
                onClicked: view.fileInstallOpen = !view.fileInstallOpen
            }
        }

        // Second toolbar row: source filter + sorting (wraps cleanly at
        // narrow window widths)
        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.spacingM

            DankButtonGroup {
                model: [Tr.t("All"), "Flathub", "Fedora", "AppImage"]
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

        RowLayout {
            Layout.fillWidth: true
            visible: view.fileInstallOpen
            spacing: Theme.spacingS

            DankTextField {
                id: fileInstallField
                Layout.fillWidth: true
                placeholderText: Tr.t("Path or URL of an .AppImage…")
                showClearButton: true
            }

            DankActionButton {
                buttonSize: 32
                iconName: "folder_open"
                iconSize: 17
                iconColor: Theme.surfaceText
                tooltipText: Tr.t("Choose an AppImage file")
                onClicked: {
                    appimagePickerLoader.active = true;
                    if (appimagePickerLoader.item)
                        appimagePickerLoader.item.open();
                }
            }

            DankButton {
                buttonHeight: 32
                horizontalPadding: Theme.spacingM
                iconName: "download"
                iconSize: 14
                text: Tr.t("Install")
                backgroundColor: Theme.buttonBg
                textColor: Theme.buttonText
                enabled: fileInstallField.text.trim() !== "" && view.appimageBusy === ""
                onClicked: {
                    const source = fileInstallField.text.trim();
                    const base = source.split("/").pop().replace(/\.appimage$/i, "");
                    view.installAppimage(["--install", source], base || "AppImage");
                    view.fileInstallOpen = false;
                    fileInstallField.clear();
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
                readonly property bool busy: app.sources ? app.sources.some(s => s.ref !== "" && (s.ref === view.busyAction || (view.appimageBusy !== "" && s.kind === "appimage" && view.appimageBusy === app.name))) : false

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
                            visible: (resultRow.app.summary || "") !== ""
                            text: resultRow.app.summary || ""
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
                            text: modelData.kind === "flatpak" ? "Flathub" : (modelData.kind === "appimage" ? "AppImage" : "Fedora")
                            backgroundColor: modelData.kind === "flatpak" ? Theme.buttonBg : (modelData.kind === "appimage" ? Theme.withAlpha(Theme.tertiary, 0.25) : Theme.secondaryContainer)
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
                        return Tr.t("Type to search Fedora repos and Flathub");
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
