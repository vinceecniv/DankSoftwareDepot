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

    property var sectionOrder: []    // section labels, in the order enrich.py assigns them
    property var installsById: ({})  // Flathub app id -> installs last month
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

    // ── Which source ─────────────────────────────────────────────────────────
    function openSourcePicker(entry) {
        sourcePicker.pickerEntry = entry;
        sourcePicker.open({
            id: entry.id,
            name: entry.name,
            iconPath: entry.icon || "",
            sources: entry.sources || []
        });
    }

    // Reparented into the window's overlay layer so the dim covers everything
    property var overlayParent: null

    SourcePickerDialog {
        id: sourcePicker

        parent: view.overlayParent || view

        property var pickerEntry: null

        onInstallRequested: source => {
            if (pickerEntry)
                view.install(source, pickerEntry.name, pickerEntry.icon || "");
        }
    }

    AppDetailsDialog {
        id: detailsDialog

        parent: view.overlayParent || view

        property var entry: null

        showInstallButtons: true
        installedChipVisible: entry ? view.isInstalled(entry) : false
        installedRefs: entry ? (entry.sources || []).filter(source => view.isSourceInstalled(entry, source)).map(source => source.ref) : []
        showOpenButton: entry !== null && entry.sources.some(s => s.kind === "flatpak" && view.installedFlatpaks.has(s.ref.toLowerCase()))
        busy: entry ? entry.sources.some(s => s.ref !== "" && view.sourceKey(s) === view.busyAction) : false
        busyDetail: view.installProgress
        busyFraction: view.installFraction

        onInstallRequested: source => view.install(source, entry.name, entry.icon || "")
    }

    readonly property string scriptPath: Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", "")

    Component.onCompleted: {
        installedProcess.running = true;
        installsProcess.running = true;
        indexProcess.running = true;
        appimageIndexProcess.running = true;
        appimageListProcess.running = true;
        Ui.steadyCursorFor(searchField);
        Ui.softenScrollbar(resultsList);
    }

    Process {
        id: appimageIndexProcess
        command: [Backend.python, Qt.resolvedUrl("scripts/appimage.py").toString().replace("file://", ""), "--index"]

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
        command: [Backend.python, Qt.resolvedUrl("scripts/appimage.py").toString().replace("file://", ""), "--list"]

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
        appimageInstallProcess.command = [Backend.python, scriptPath.replace("enrich.py", "appimage.py")].concat(args);
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
        dnfProcess.command = [Backend.python, scriptPath, "--search-dnf", query];
        dnfProcess.running = true;
    }

    // One array instead of a fresh concat per keystroke. The two indexes are
    // replaced twice in a session — when each finishes loading — and copying
    // four thousand entries on every letter to express that is a waste.
    readonly property var searchPool: searchIndex.concat(appimageIndex)

    // Typing only ever narrows. Every test below is containment or a stronger
    // form of it, so an entry that cannot match "fire" cannot match "firef"
    // either, and the second letter can be scanned against the few hundred
    // that survived the first rather than against the whole catalog.
    //
    // Kept in a plain object rather than in properties on purpose: this is
    // written from inside a binding, and a property write would notify the
    // binding that reads it. Assigning to the fields of a var never does.
    // `source` is the pool identity, so an index arriving mid-word throws the
    // cache away rather than filtering a stale subset.
    readonly property var _searchCache: ({
            source: null,
            needle: "",
            pool: []
        })

    function localResults(query) {
        const needle = query.toLowerCase();
        const words = needle.split(/\s+/).filter(w => w !== "");
        const scored = [];
        const cache = _searchCache;
        const narrowed = cache.source === searchPool && cache.needle.length >= 2 && needle.startsWith(cache.needle);
        const pool = narrowed ? cache.pool : searchPool;
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
        // The whole match set, not the sixty that get shown: the next letter
        // has to be scanned against everything that could still match it
        cache.source = searchPool;
        cache.needle = needle;
        cache.pool = scored.map(entry => entry.item);
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

    // ── Sections ─────────────────────────────────────────────────────────────
    // The storefront is a row of teasers per category; naming one here opens it
    // and the tab shows that category alone. Searching outranks it rather than
    // clearing it: a search is a detour, and the section is still where the
    // reader was when they left.
    // A section outranks a search rather than the other way round: typing
    // while inside one narrows that section instead of abandoning it, which is
    // what "search further" means once you have chosen where to look. Leaving
    // is a chip away, and leaving is what widens the search back to everything.
    property string activeCategory: ""
    readonly property bool sectionMode: activeCategory !== ""

    function installsFor(item) {
        let best = 0;
        for (const source of item.sources) {
            if (source.kind === "flatpak") {
                const count = installsById[source.ref] || 0;
                if (count > best)
                    best = count;
            }
        }
        return best;
    }

    // Every app in the catalog, in exactly one section, most-downloaded first.
    // Whole sections rather than a sample of each: a section holds what a
    // section holds, the list shows as much of it as has been scrolled to, and
    // searching one searches all of it. Computed when an index or the download
    // figures arrive — twice in a session, not once per keystroke.
    readonly property var sections: {
        if (searchIndex.length === 0 || sectionOrder.length === 0)
            return [];
        for (const item of searchIndex)
            item._inst = installsFor(item);
        const byDownloads = (a, b) => {
            if (a._inst !== b._inst)
                return b._inst - a._inst;
            const countA = a.rating ? a.rating.count : 0;
            const countB = b.rating ? b.rating.count : 0;
            if (countA !== countB)
                return countB - countA;
            return a.name.localeCompare(b.name);
        };
        const buckets = {};
        for (const label of sectionOrder)
            buckets[label] = [];
        for (const item of searchIndex) {
            const bucket = buckets[item.section];
            if (bucket !== undefined)
                bucket.push(item);
        }
        // The chart is every app there is rather than a category, which also
        // makes it the section to open when what you want is to browse the lot
        const groups = [{
                category: "Most popular",
                items: searchIndex.slice().sort(byDownloads)
            }];
        for (const label of sectionOrder) {
            if (buckets[label].length === 0)
                continue;
            groups.push({
                category: label,
                items: buckets[label].sort(byDownloads)
            });
        }
        return groups;
    }
    readonly property var sectionNames: sections.map(group => group.category)

    function matchesQuery(item, query) {
        if (query.length < 2)
            return true;
        return item.nl.indexOf(query) !== -1 || item.ne.indexOf(query) !== -1 || item.il.indexOf(query) !== -1 || item.pl.indexOf(query) !== -1 || item.sl.indexOf(query) !== -1;
    }

    // Everything in the open section that matches, before anything is cut off
    // for the sake of the list. The heading counts this, and the search runs
    // over it — a section you have only scrolled a third of the way through is
    // still a section you searched in full.
    readonly property var sectionMatches: {
        const section = activeCategory !== "" ? sections.find(group => group.category === activeCategory) : null;
        if (!section)
            return [];
        const needle = searchText.trim().toLowerCase();
        const matches = [];
        for (const item of section.items) {
            // Browsing is for what you could install; the Installed tab
            // already answers the other question. Searching is not browsing
            // though — typing a name and being told there is no such app,
            // because you already have it, is a worse answer than the row.
            if (needle.length < 2 && isInstalled(item))
                continue;
            if (matchesSourceFilter(item) && matchesQuery(item, needle))
                matches.push(item);
        }
        return matches;
    }

    // How much of it has been asked for. Rows are cheap but not free, and a
    // section can be nine hundred apps long; the rest arrives on the way down.
    property int sectionRevealed: sectionPage
    readonly property int sectionPage: 60

    onSectionMatchesChanged: sectionRevealed = sectionPage

    function revealMoreOfSection() {
        if (sectionRevealed < sectionMatches.length)
            sectionRevealed += sectionPage;
    }

    function openSection(category) {
        activeCategory = category || "";
        sectionRevealed = sectionPage;
        resultsList.positionViewAtBeginning();
    }
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
    // {type: "header", label} | {type: "app", data} | {type: "coprPrompt"}
    readonly property var listModel: {
        const rows = [];
        // A section named but no longer delivered falls through to the
        // storefront rather than to an empty list — the sections are cut from
        // the catalogs, and those change under an update
        if (activeCategory !== "" && sections.some(group => group.category === activeCategory)) {
            // Already in download order, and filtering keeps an order rather
            // than making one, so there is nothing left to sort here
            for (const item of sectionMatches.slice(0, sectionRevealed))
                rows.push({
                    type: "app",
                    data: item
                });
            return rows;
        }
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
            // Copr, offered where the results run out rather than above them.
            // It is the one search that leaves the machine, so it stays a
            // thing to ask for — and the place to ask is after everything the
            // machine could answer by itself, which is also where "not here?"
            // is a question the reader has just arrived at. Anything Copr
            // returns is listed under this row, so the row can say so.
            if (Backend.hasCopr)
                rows.push({
                    type: "coprPrompt"
                });
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
        for (const [index, group] of sections.entries()) {
            // What is already on the machine is not on offer: that is what
            // the Installed tab is, and a storefront listing it is a
            // storefront of things you cannot do anything with here
            const items = group.items.filter(item => !isInstalled(item) && matchesSourceFilter(item));
            if (items.length === 0)
                continue;
            // A heading with a section behind it, so it can be opened. The
            // storefront shows the head of each; the rest is what opening one
            // is for. The chart keeps the eight it always had.
            rows.push({
                type: "header",
                label: group.category,
                category: group.category,
                total: items.length
            });
            for (const item of items.slice(0, index === 0 ? 8 : 6))
                rows.push({
                    type: "app",
                    data: item
                });
        }
        return rows;
    }

    // Per source rather than per app: an app carried by both Fedora and
    // Flathub is installed from one of them, and "installed" without saying
    // which is the answer to a question nobody asked
    function isSourceInstalled(item, source) {
        if (source.kind === "flatpak")
            return installedFlatpaks.has(source.ref.toLowerCase());
        if (source.kind === "dnf")
            return installedRpms.has(source.ref);
        if (source.kind === "copr")
            return source.installed === true;
        if (source.kind === "appimage")
            return installedAppimages.has(item.id);
        return false;
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
            installProcess.command = [Backend.python, scriptPath.replace("enrich.py", "flatpak_helper.py"), "install", source.source, source.ref];
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

    // Download figures, refreshed here and nowhere else. The index reads them
    // from cache and never waits for a server on another continent; this asks
    // that server, once a day, alongside the index rather than in front of it.
    // What comes back is used directly, so the first run on a machine is
    // ordered correctly a second later instead of at the next start.
    Process {
        id: installsProcess
        command: [Backend.python, view.scriptPath, "--flathub-installs"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    view.installsById = JSON.parse(text) || ({});
                } catch (e) {
                    view.installsById = ({});
                }
            }
        }
    }

    Process {
        id: indexProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const payload = JSON.parse(text);
                    view.sectionOrder = payload.sections || [];
                    view.searchIndex = payload.items || [];
                } catch (e) {
                    view.sectionOrder = [];
                    view.searchIndex = [];
                }
                view.indexLoading = false;
            }
        }

        command: [Backend.python, view.scriptPath, "--qml-index"]

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
                // The field says where it is pointing: inside a section it
                // searches that section, and typing without being told so
                // would look like a search that had lost most of the catalog
                placeholderText: view.sectionMode ? Tr.t("Search in %1…").arg(Tr.t(view.activeCategory)) : Tr.t("Search new software (%1 repos + Flathub)…").arg(Backend.systemRepoLabel)
                FieldPlaceholder {
                    text: view.sectionMode ? Tr.t("Search in %1…").arg(Tr.t(view.activeCategory)) : Tr.t("Search new software (%1 repos + Flathub)…").arg(Backend.systemRepoLabel)
                }
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

            // The fifth source of software, and the one this window does not
            // serve itself: browsing and installing plugins is DMS's own
            // screen, so the button opens that rather than pretending to be
            // a second registry client.
            DankActionButton {
                buttonSize: 34
                iconName: "extension"
                iconSize: 18
                iconColor: Theme.surfaceText
                tooltipText: Tr.t("Install a DMS plugin")
                onClicked: PopoutService.openSettingsWithTab("plugins")
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
                // A section has one order and it is not up for discussion
                visible: view.searchMode && !view.sectionMode
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

        // Which section this is. The heading that was clicked scrolled away
        // with the storefront, and the chips below say where else to go
        // rather than where you are.
        RowLayout {
            Layout.fillWidth: true
            visible: view.sectionMode
            spacing: Theme.spacingXS

            StyledText {
                text: Tr.t(view.activeCategory)
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.DemiBold
                color: Theme.surfaceText
            }

            // The whole section, not the part of it that has been scrolled to
            StyledText {
                text: (view.sectionMatches.length === 1 ? Tr.t("%1 result") : Tr.t("%1 results")).arg(view.sectionMatches.length)
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
            }

            StyledText {
                Layout.fillWidth: true
                text: Tr.t("Most downloaded first")
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.withAlpha(Theme.surfaceVariantText, 0.8)
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideRight
            }
        }

        // ── Where else to go from here ───────────────────────────────────────
        // Only inside a section: on the storefront every section is already on
        // screen with its own heading, and a row of chips saying the same
        // things again would be furniture. A Flow rather than a Row because
        // nine translated category names do not fit a narrow window on one
        // line, and a chip pushed off the edge is a section you cannot reach.
        Flow {
            Layout.fillWidth: true
            visible: view.sectionMode
            spacing: Theme.spacingXS

            Rectangle {
                height: 28
                width: backChipRow.implicitWidth + Theme.spacingM * 2
                radius: 14
                color: backChipArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.22) : Theme.withAlpha(Theme.surfaceContainerHigh, 0.6)

                Row {
                    id: backChipRow
                    anchors.centerIn: parent
                    spacing: Theme.spacingXS

                    DankIcon {
                        name: "arrow_back"
                        size: 14
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    StyledText {
                        text: Tr.t("All sections")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    id: backChipArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: view.openSection("")
                }
            }

            Repeater {
                model: view.sectionNames.filter(name => name !== view.activeCategory)

                delegate: Rectangle {
                    required property string modelData

                    height: 28
                    width: sectionChipLabel.implicitWidth + Theme.spacingM * 2
                    radius: 14
                    color: sectionChipArea.containsMouse ? Theme.withAlpha(Theme.primary, 0.18) : Theme.withAlpha(Theme.surfaceVariant, 0.5)

                    StyledText {
                        id: sectionChipLabel
                        anchors.centerIn: parent
                        text: Tr.t(modelData)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    MouseArea {
                        id: sectionChipArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: view.openSection(modelData)
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            // In a section the heading above already carries the count
            visible: view.searchMode && !view.sectionMode && !view.indexLoading
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
                            // A package with no icon of its own falls back to this glyph, and a
                            // list of them is most of what an installed-software list is. Left
                            // grey it made the setting look half-applied — the apps with
                            // artwork turned, the ones without stayed as they were.
                            color: Ui.tintAppIcons ? Theme.primary : Theme.surfaceVariantText
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
            // Counted in results, not in rows: the Copr prompt is a row too,
            // and a list holding nothing but the offer to search elsewhere is
            // still a search that found nothing
            visible: view.resultCount > 0 && !view.searching

            // The rest of a section, handed over on the way down rather than
            // all at once. Far enough from the bottom that the next batch is
            // built before it is reached, so scrolling never stops at a seam.
            onContentYChanged: {
                if (view.sectionMode && contentHeight - (contentY + height) < 600)
                    view.revealMoreOfSection();
            }

            delegate: Loader {
                required property var modelData

                width: resultsList.width
                sourceComponent: {
                    if (modelData.type === "header")
                        return categoryHeaderComponent;
                    if (modelData.type === "coprPrompt")
                        return coprPromptComponent;
                    return appRowComponent;
                }

                onLoaded: item.rowData = modelData
            }
        }

        // ── Copr, on request ─────────────────────────────────────────────────
        // Used twice: as the last row of a result list, and in the empty state
        // where there is no list to be the last row of. Nothing about it reads
        // its own position, so both are the same component.
        Component {
            id: coprPromptComponent

            Rectangle {
                property var rowData: ({})

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
                        wrapMode: Text.WordWrap
                    }

                    DankSpinner {
                        visible: view.coprSearching
                        size: 16
                    }

                    // Wrapper Item: DankButton sizes itself through `width`, which a layout does not read
                    //
                    // The condition lives here rather than on the button: a
                    // wrapper that reads its child's `visible` is asking a
                    // question it has already answered, since `visible` reads
                    // back as false whenever a parent's is. That is what kept
                    // this button off the screen from 0.8.0 on.
                    Item {
                        Layout.preferredWidth: coprSearchButton.width
                        Layout.preferredHeight: coprSearchButton.height
                        visible: !view.coprSearching && view.coprQuery !== view.searchText.trim()

                        DankButton {
                            id: coprSearchButton
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
            }
        }

        Component {
            id: categoryHeaderComponent

            Item {
                id: headerRoot

                property var rowData: ({})
                // Only a storefront category opens: the Copr heading in a
                // search result labels where rows came from, and there is no
                // section behind it to go to
                readonly property bool opens: (rowData.category || "") !== ""

                implicitHeight: headerLabel.implicitHeight + Theme.spacingM

                Row {
                    id: headerContent

                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 2
                    spacing: Theme.spacingXS

                    StyledText {
                        id: headerLabel
                        text: Tr.t(headerRoot.rowData.label || "")
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        font.underline: headerRoot.opens && headerArea.containsMouse
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    // The count is the invitation: a heading that says 60 is a
                    // heading worth clicking, where one that says 6 is the
                    // whole story already
                    StyledText {
                        visible: headerRoot.opens && (headerRoot.rowData.total || 0) > 0
                        text: headerRoot.rowData.total || ""
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.withAlpha(Theme.primary, 0.7)
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    DankIcon {
                        visible: headerRoot.opens
                        name: "chevron_right"
                        size: 14
                        color: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    id: headerArea

                    anchors.left: headerContent.left
                    anchors.right: headerContent.right
                    anchors.top: headerContent.top
                    anchors.bottom: headerContent.bottom
                    anchors.margins: -Theme.spacingXS
                    enabled: headerRoot.opens
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: view.openSection(headerRoot.rowData.category)
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
                            // Themed icons, tuned in TintedIconEffect
                            layer.enabled: Ui.tintAppIcons
                            layer.effect: TintedIconEffect {}
                        }

                        DankIcon {
                            anchors.centerIn: parent
                            visible: resultLogo.status !== Image.Ready
                            name: "apps"
                            size: 22
                            // A package with no icon of its own falls back to this glyph, and a
                            // list of them is most of what an installed-software list is. Left
                            // grey it made the setting look half-applied — the apps with
                            // artwork turned, the ones without stayed as they were.
                            color: Ui.tintAppIcons ? Theme.primary : Theme.surfaceVariantText
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
                                        color: resultRow.app.rating && (index + 0.25 <= resultRow.app.rating.stars) ? Theme.primary : Theme.withAlpha(Theme.surfaceVariantText, 0.5)
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
                        // One button when there is one thing it can mean, and
                        // one button when there are several — in that case it
                        // opens the picker instead of guessing. A row of two
                        // buttons is not two actions, it is the same action
                        // with a difference nobody wrote down; the picker is
                        // where that difference is written down.
                        model: {
                            if (resultRow.installed)
                                return [];
                            const sources = resultRow.app.sources || [];
                            return sources.length > 1 ? [null] : sources;
                        }

                        delegate: DankButton {
                            required property var modelData

                            readonly property bool picks: modelData === null

                            buttonHeight: 28
                            horizontalPadding: Theme.spacingM
                            iconName: picks ? "download" : (modelData.kind === "appimage" && !modelData.repo ? "open_in_new" : "download")
                            iconSize: 13
                            text: picks ? Tr.t("Install") : (modelData.kind === "flatpak" ? "Flathub" : (modelData.kind === "appimage" ? "AppImage" : (modelData.kind === "copr" ? "Copr" : Backend.systemRepoLabel)))
                            backgroundColor: picks ? Theme.buttonBg : (modelData.kind === "flatpak" ? Theme.buttonBg : (modelData.kind === "appimage" ? Theme.withAlpha(Theme.tertiary, 0.25) : (modelData.kind === "copr" ? Theme.withAlpha(Theme.primary, 0.22) : Theme.secondaryContainer)))
                            textColor: (picks || modelData.kind === "flatpak") ? Theme.buttonText : Theme.surfaceText
                            enabled: !resultRow.busy && view.busyAction === "" && view.appimageBusy === ""
                            onClicked: {
                                if (picks)
                                    view.openSourcePicker(resultRow.app);
                                else
                                    view.install(modelData, resultRow.app.name, resultRow.app.icon || "");
                            }
                        }
                    }
                }
            }
        }

        // States: idle hint / searching / no results
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: view.resultCount === 0 || view.searching

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

                // Nothing found is the case the offer was written for, and
                // it is the one case with no result list to sit at the end of
                Loader {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.min(520, view.width - Theme.spacingXL * 2)
                    active: view.searchMode && !view.searching && Backend.hasCopr
                    visible: active
                    sourceComponent: coprPromptComponent
                }
            }
        }
    }

}
