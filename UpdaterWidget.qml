import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

// Dank Software Depot — DankBar widget.
// The pill shows the update count (or live progress during an update run).
// Clicking opens a compact popout; the full experience lives in the
// standalone window (UpdaterWindow).
PluginComponent {
    id: root

    // ── Settings ─────────────────────────────────────────────────────────────
    readonly property bool hideWhenUpToDate: pluginData.hideWhenUpToDate === true
    readonly property bool showRuntimes: pluginData.showRuntimes === true
    readonly property bool confirmBeforeUpdate: pluginData.confirmBeforeUpdate === true
    readonly property bool pillOpensWindow: pluginData.pillOpensWindow === true
    readonly property bool includeFirmware: pluginData.includeFirmware !== false
    // The offer to place a launcher entry is made once; declining it is a
    // decision, not something to be asked again on the next window open
    readonly property bool launcherPromptDone: pluginData.launcherPromptDone === true

    property bool confirmArmed: false

    // Last known update list, persisted across restarts: the daemon loses
    // its in-memory state when it restarts (reboot, dms restart) and only
    // repopulates at its next check — until the service has real state the
    // snapshot is shown, so previously found updates reappear immediately.
    readonly property bool _serviceHasState: SystemUpdateService.lastCheckUnix > 0 || (SystemUpdateService.availableUpdates || []).length > 0
    readonly property var pendingUpdates: _serviceHasState ? (SystemUpdateService.availableUpdates || []) : ((pluginData.updatesSnapshot || {}).packages || [])

    // Held packages (dnf versionlock/excludes) never count as real updates
    readonly property var heldSystemKeys: {
        const keys = [];
        for (const pkg of pendingUpdates) {
            if (store.isHeld(pkg))
                keys.push(store.keyFor(pkg));
        }
        return keys;
    }

    readonly property int effectiveCount: {
        let count = 0;
        for (const pkg of pendingUpdates) {
            if (!store.isHeld(pkg))
                count++;
        }
        if (includeFirmware)
            count += (firmware.updates || []).length;
        count += (appimageUpdates || []).length;
        return count;
    }

    FirmwareService {
        id: firmware
    }

    // Own app icon (Claude-designed), following the active light/dark theme
    readonly property url appIconSource: Qt.resolvedUrl("assets/icons/dank-software-depot-" + (Theme.isLightMode ? "light" : "dark") + ".svg")

    // DMS penguin logo from the running shell's assets (path changes per version)
    property string dankLogoPath: ""

    Process {
        id: dankLogoProcess
        running: true
        command: ["sh", "-c", "ls \"$XDG_RUNTIME_DIR\"/danklinux-shell/*/assets/danklogo.svg 2>/dev/null | head -1"]

        stdout: StdioCollector {
            onStreamFinished: root.dankLogoPath = text.trim()
        }
    }

    // ── Update-size estimate (upper bound; flatpak sizes are full downloads)
    property var updateSizes: null
    readonly property string updateSizeText: {
        let total = (updateSizes && updateSizes.totalBytes > 0) ? updateSizes.totalBytes : 0;
        for (const ai of appimageUpdates || [])
            total += ai.size || 0;
        return total > 0 ? ("≤ " + engine.formatBytes(total)) : "";
    }

    Timer {
        id: sizesDebounce
        interval: 3000
        onTriggered: root._refreshSizes()
    }

    function _refreshSizes() {
        const flatpaks = [];
        const rpms = [];
        for (const pkg of pendingUpdates) {
            if (store.isHeld(pkg))
                continue;
            if (pkg.repo === "flatpak")
                flatpaks.push(pkg.name);
            else
                rpms.push(store.stripArch(pkg.name));
        }
        if (flatpaks.length === 0 && rpms.length === 0) {
            updateSizes = null;
            return;
        }
        sizesProcess.command = ["python3", Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", ""), "--update-sizes", JSON.stringify({
            flatpak: flatpaks,
            rpm: rpms
        })];
        sizesProcess.running = true;
    }

    Process {
        id: sizesProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.updateSizes = JSON.parse(text);
                } catch (e) {
                    root.updateSizes = null;
                }
            }
        }
    }

    // ── Pending AppImage updates (GitHub releases via scripts/appimage.py) ──
    property var appimageUpdates: []

    Process {
        id: appimageCheckProcess
        command: ["python3", Qt.resolvedUrl("scripts/appimage.py").toString().replace("file://", ""), "--check-updates"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.appimageUpdates = JSON.parse(text);
                } catch (e) {
                    root.appimageUpdates = [];
                }
            }
        }
    }

    // ── End-of-life components (flatpak refs the remote stopped maintaining)
    property var eolRefs: []

    Process {
        id: eolProcess
        command: ["python3", Qt.resolvedUrl("scripts/flatpak_helper.py").toString().replace("file://", ""), "eol"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.eolRefs = JSON.parse(text);
                } catch (e) {
                    root.eolRefs = [];
                }
            }
        }
    }

    // ── Newer Fedora release available? (Bodhi, cached daily)
    property var distroUpgrade: null

    Process {
        id: distroProcess
        command: ["python3", Qt.resolvedUrl("scripts/enrich.py").toString().replace("file://", ""), "--distro-upgrade"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.distroUpgrade = JSON.parse(text);
                } catch (e) {
                }
            }
        }
    }

    Timer {
        interval: 4000
        running: true
        onTriggered: {
            eolProcess.running = true;
            distroProcess.running = true;
            appimageCheckProcess.running = true;
            root.refreshCleanup();
        }
    }

    // ── Automatic updates: off | notify | auto (auto-install flatpaks) ──────
    // A fresh install starts at "notify": finding updates and saying nothing
    // is the one behaviour nobody asks for. An explicit "off" is stored and
    // kept.
    readonly property string autoUpdateMode: pluginData.autoUpdateMode || "notify"
    property int _lastNotifiedCount: 0

    // One desktop notification, from the two places that have something to
    // announce. Clicking the body (action "default") or the Open button opens
    // the window: notify-send --action waits and prints the chosen action, and
    // the detached shell turns that into the plugin's own IPC call.
    function notify(summary, body) {
        const iconFile = Qt.resolvedUrl("assets/icons/dank-software-depot-" + (Theme.isLightMode ? "light" : "dark") + ".svg").toString().replace("file://", "");
        // One action, not two: `default` is what a click on the body triggers,
        // and naming a second one only added a duplicate button next to it.
        // The body line is optional — an empty argument would draw an empty
        // line, so the two shapes are separate calls.
        Quickshell.execDetached(["sh", "-c", "if [ -n \"$4\" ]; then chosen=$(notify-send -a 'Dank Software Depot' -i \"$1\" -A default=\"$2\" \"$3\" \"$4\"); else chosen=$(notify-send -a 'Dank Software Depot' -i \"$1\" -A default=\"$2\" \"$3\"); fi; [ -n \"$chosen\" ] && dms ipc call dankSoftwareDepot open", "notify", iconFile, Tr.t("Open"), summary, body || ""]);
    }

    // A new version of the plugin deserves the same courtesy as new packages:
    // the banner is only seen by someone who happens to open the window.
    // Announced once per version — the check runs at every shell start, and a
    // notification repeated on every restart is a notification switched off.
    function notifyPluginUpdate(version, releases) {
        if (version === "" || autoUpdateMode === "off")
            return;
        if ((pluginData.selfUpdateNotifiedVersion || "") === version)
            return;
        PluginService.savePluginData("dankSoftwareDepot", "selfUpdateNotifiedVersion", version);
        // The notification already carries the app's name and icon above the
        // text; repeating it in the summary only spent the width the summary
        // has, and it has little
        notify(Tr.t("Version %1 is available").arg(version), releases > 1 ? Tr.t("%1 releases since yours").arg(releases) : "");
    }

    function _afterCheck() {
        const count = effectiveCount;
        if (count === 0) {
            _lastNotifiedCount = 0;
            return;
        }
        if (autoUpdateMode === "off")
            return;
        if (count !== _lastNotifiedCount) {
            _lastNotifiedCount = count;
            notify((count === 1 ? Tr.t("%1 update available") : Tr.t("%1 updates available")).arg(count));
        }
        if (autoUpdateMode === "auto" && !engine.running && !SystemUpdateService.isUpgrading) {
            const hasFlatpaks = (SystemUpdateService.availableUpdates || []).some(pkg => pkg.repo === "flatpak");
            if (hasFlatpaks)
                engine.start({
                    dnf: false,
                    firmware: false
                });
        }
    }

    Connections {
        target: SystemUpdateService

        function onIsCheckingChanged() {
            // Piggy-back a firmware check on every daemon check
            if (!SystemUpdateService.isChecking && root.includeFirmware)
                firmware.check();
            if (!SystemUpdateService.isChecking) {
                appimageCheckProcess.running = true;
                Qt.callLater(() => root._afterCheck());
            }
        }
    }

    Ref {
        service: SystemUpdateService
    }

    MetadataStore {
        id: store
        persistedHeldMap: pluginData.heldPackages || ({})

        onEnriched: {
            // Persist the held map so held packages are known before the
            // async enrichment of the next check/session completes
            const current = store.currentHeldMap();
            if (JSON.stringify(current) !== JSON.stringify(pluginData.heldPackages || {}))
                PluginService.savePluginData("dankSoftwareDepot", "heldPackages", current);
        }
    }

    readonly property int lastUpdateUnix: pluginData.lastUpdateUnix || 0

    // ── Reboot recommendation ───────────────────────────────────────────────
    // Set when a run updated core system components (kernel/systemd/glibc/…)
    // or firmware; cleared automatically after a reboot (boot id changes).
    property string _bootId: ""
    readonly property bool rebootRecommended: {
        const flag = pluginData.rebootFlag;
        return !!(flag && flag.recommended && _bootId !== "" && flag.bootId === _bootId);
    }
    property bool confirmReboot: false

    readonly property var _rebootPackagePattern: Backend.rebootPackagePattern

    Process {
        id: bootIdProcess
        command: ["cat", "/proc/sys/kernel/random/boot_id"]
        running: true

        stdout: StdioCollector {
            onStreamFinished: root._bootId = text.trim()
        }
    }

    function _evaluateReboot() {
        let needed = false;
        for (const item of engine.runItems || []) {
            const state = engine.itemStates[item.key];
            if (!state || state.status !== "done")
                continue;
            if (item.pkg.repo === "firmware") {
                needed = true;
            } else if (item.pkg.repo !== "flatpak" && _rebootPackagePattern.test(store.stripArch(item.pkg.name))) {
                needed = true;
            }
        }
        if (needed && _bootId !== "") {
            PluginService.savePluginData("dankSoftwareDepot", "rebootFlag", {
                bootId: _bootId,
                recommended: true
            });
        }
    }

    // A transaction that only exists in the next deployment. On an atomic
    // system that is every install and every removal, so the tabs say so
    // rather than each inventing its own way to explain it.
    function noteStagedChange() {
        if (_bootId === "")
            return;
        PluginService.savePluginData("dankSoftwareDepot", "rebootFlag", {
            bootId: _bootId,
            recommended: true
        });
    }

    function dismissReboot() {
        PluginService.savePluginData("dankSoftwareDepot", "rebootFlag", {});
        confirmReboot = false;
    }

    function requestReboot() {
        if (!confirmReboot) {
            confirmReboot = true;
            rebootConfirmTimer.restart();
            return;
        }
        Quickshell.execDetached(["systemctl", "reboot"]);
    }

    Timer {
        id: rebootConfirmTimer
        interval: 6000
        onTriggered: root.confirmReboot = false
    }

    // ── Check progress estimate ─────────────────────────────────────────────
    // The daemon reports no granular progress while refreshing, so we
    // estimate from the (cached, smoothed) duration of previous checks.
    readonly property int estCheckSecs: pluginData.checkDurationSecs || 45
    property real checkFraction: 0
    property int checkElapsedSecs: 0
    property double _checkStartMs: 0

    Timer {
        id: checkProgressTimer
        interval: 500
        repeat: true
        onTriggered: {
            const elapsed = (Date.now() - root._checkStartMs) / 1000;
            root.checkElapsedSecs = Math.floor(elapsed);
            root.checkFraction = Math.min(0.95, elapsed / Math.max(5, root.estCheckSecs));
        }
    }

    Connections {
        target: SystemUpdateService

        function onIsCheckingChanged() {
            if (SystemUpdateService.isChecking) {
                root._checkStartMs = Date.now();
                root.checkElapsedSecs = 0;
                root.checkFraction = 0;
                checkProgressTimer.start();
            } else {
                checkProgressTimer.stop();
                if (root._checkStartMs > 0) {
                    const duration = (Date.now() - root._checkStartMs) / 1000;
                    if (duration > 3)
                        PluginService.savePluginData("dankSoftwareDepot", "checkDurationSecs", Math.round(0.7 * root.estCheckSecs + 0.3 * duration));
                    root._checkStartMs = 0;
                }
                root.checkFraction = 0;
            }
        }
    }

    function formatAgo(unix) {
        if (!unix)
            return "";
        const delta = Math.max(0, Math.floor(Date.now() / 1000) - unix);
        if (delta < 90)
            return Tr.t("just now");
        if (delta < 3600)
            return Tr.t("%1m ago").arg(Math.round(delta / 60));
        if (delta < 86400)
            return Tr.t("%1h ago").arg(Math.round(delta / 3600));
        return Tr.t("%1d ago").arg(Math.round(delta / 86400));
    }

    ActionLog {
        id: actionLog
    }

    readonly property var actionLogger: actionLog

    // ── Shell-pass log survival ─────────────────────────────────────────────
    // Updating dms/quickshell reloads the shell before the run can write its
    // log entry (and the per-app dms route has no completion hook at all).
    // Stash the planned entry beforehand; the next start verifies against
    // the rpm database what actually arrived and writes the swallowed entry
    // with its original timestamp.
    function _stashShellRunLog(shellPkgs, doneItems) {
        PluginService.savePluginData("dankSoftwareDepot", "pendingShellRunLog", {
            ts: Math.floor(Date.now() / 1000),
            items: doneItems || [],
            shell: shellPkgs.map(pkg => ({
                base: store.stripArch(pkg.name),
                name: store.displayName(pkg),
                from: pkg.fromVersion || "",
                to: pkg.toVersion || ""
            }))
        });
    }

    function _stashFromEngine() {
        const shellPkgs = [];
        const doneItems = [];
        for (const ri of engine.runItems || []) {
            const base = store.stripArch(ri.pkg.name);
            const isShell = ri.pkg.repo !== "flatpak" && ri.pkg.repo !== "firmware" && ri.pkg.repo !== "appimage" && engine.shellPackagePattern.test(base);
            if (isShell) {
                shellPkgs.push(ri.pkg);
                continue;
            }
            const st = engine.itemStates[ri.key] || {};
            const isSystem = ri.pkg.repo !== "flatpak" && ri.pkg.repo !== "firmware" && ri.pkg.repo !== "appimage";
            const item = {
                name: store.displayName(ri.pkg),
                // The id the package is known by, so the log can lead back to
                // it: the name above is for reading, not for looking up
                id: ri.pkg.name || "",
                repo: ri.pkg.repo || "",
                from: ri.pkg.fromVersion || "",
                to: ri.pkg.toVersion || "",
                source: ri.pkg.repo === "flatpak" ? "Flatpak" : (ri.pkg.repo === "firmware" ? "Firmware" : (ri.pkg.repo === "appimage" ? "AppImage" : "System")),
                status: st.status || "",
                reason: st.status === "error" ? (st.detail || "") : "",
                error: engine.runErrorDetails[ri.key] || ""
            };
            // The shell pass runs after this snapshot is taken; a system row
            // that failed before it may still arrive. Carry the package name
            // so the replay can ask the package database instead of
            // preserving a verdict that the rest of the run has outrun.
            if (isSystem)
                item.base = base;
            doneItems.push(item);
        }
        if (shellPkgs.length > 0)
            _stashShellRunLog(shellPkgs, doneItems);
    }

    // ── Reclaimable space ───────────────────────────────────────────────────
    // {unneeded: {count, bytes, names}, cache: {bytes}} — null until scanned
    property var cleanup: null
    property string cleanupBusy: ""   // "" | packages | cache

    function refreshCleanup() {
        if (cleanupScanProcess.running)
            return;
        cleanupScanProcess.command = Backend.cleanupScanCommand();
        cleanupScanProcess.running = true;
    }

    Process {
        id: cleanupScanProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.cleanup = JSON.parse(text);
                } catch (e) {
                    root.cleanup = null;
                }
                if (root._pendingCleanupLog === "")
                    return;
                const freed = root._cleanupBefore - root._cleanupTotal();
                const title = root._pendingCleanupLog;
                const items = root._pendingCleanupItems;
                root._pendingCleanupLog = "";
                root._pendingCleanupItems = [];
                if (freed > 0)
                    actionLog.record("uninstall", title + " · " + engine.formatBytes(freed), items);
            }
        }
    }

    // Cleanups are logged by what they freed, not by whether the command
    // exited cleanly: `dnf clean packages` returns 0 with nothing to clean,
    // and an action log that reports emptying an empty cache is lying.
    property real _cleanupBefore: 0
    property string _pendingCleanupLog: ""
    property var _pendingCleanupItems: []

    function _cleanupTotal() {
        if (!cleanup)
            return 0;
        return (cleanup.unneeded.bytes || 0) + (cleanup.cache.bytes || 0);
    }

    function removeUnneeded() {
        const names = (cleanup && cleanup.unneeded) ? cleanup.unneeded.names : [];
        if (names.length === 0 || cleanupBusy !== "")
            return;
        cleanupBusy = "packages";
        _cleanupBefore = _cleanupTotal();
        _pendingCleanupLog = Tr.t("Removed %1 unneeded packages").arg(names.length);
        _pendingCleanupItems = names.map(n => ({
                    name: n,
                    from: "",
                    to: "",
                    source: "System",
                    status: "done"
                }));
        cleanupProcess.command = Backend.helperCommand("remove", names);
        cleanupProcess.running = true;
    }

    function cleanCache() {
        if (cleanupBusy !== "")
            return;
        cleanupBusy = "cache";
        _cleanupBefore = _cleanupTotal();
        _pendingCleanupLog = Tr.t("Emptied the package cache");
        _pendingCleanupItems = [];
        cleanupProcess.command = Backend.cleanCacheCommand();
        cleanupProcess.running = true;
    }

    Process {
        id: cleanupProcess

        onExited: (exitCode, exitStatus) => {
            root.cleanupBusy = "";
            if (exitCode !== 0)
                root._pendingCleanupLog = "";
            // The rescan decides what actually happened
            root.refreshCleanup();
        }
    }

    // ── How long this usually takes here ────────────────────────────────────
    // Seconds per package, measured on this machine. Package counts vary far
    // more than per-package cost does, so the rate is what generalises — and
    // the median ignores the one run that hit a slow mirror.
    readonly property var runHistory: (pluginData.runHistory || [])

    function _recordRun(seconds, items) {
        if (items <= 0 || seconds <= 0)
            return;
        const history = runHistory.slice();
        history.push({
            seconds: seconds,
            items: items
        });
        // Ten runs is enough to be representative and few enough to follow a
        // machine that got faster
        PluginService.savePluginData("dankSoftwareDepot", "runHistory", history.slice(-10));
    }

    // Estimated seconds for a run of `items` packages, -1 when this machine
    // has not shown us enough yet
    function estimateRunSeconds(items) {
        const rates = runHistory.filter(r => r.items > 0).map(r => r.seconds / r.items).sort((a, b) => a - b);
        if (rates.length < 2 || items <= 0)
            return -1;
        const median = rates.length % 2 ? rates[(rates.length - 1) / 2] : (rates[rates.length / 2 - 1] + rates[rates.length / 2]) / 2;
        return Math.round(median * items);
    }

    // ── Update severity ─────────────────────────────────────────────────────
    // name -> {type, severity, ids}. Without this every update looks equally
    // urgent, which is another way of saying none of them do.
    property var advisories: ({})

    readonly property int securityCount: {
        let count = 0;
        for (const pkg of pendingUpdates) {
            const adv = advisories[store.stripArch(pkg.name)];
            if (adv && adv.type === "security")
                count++;
        }
        return count;
    }

    Timer {
        id: advisoryDebounce
        interval: 2000
        onTriggered: root._refreshAdvisories()
    }

    function _refreshAdvisories() {
        if (!Backend.hasAdvisories || advisoryProcess.running)
            return;
        const names = [];
        for (const pkg of pendingUpdates) {
            if (pkg.repo !== "flatpak" && pkg.repo !== "firmware" && pkg.repo !== "appimage")
                names.push(store.stripArch(pkg.name));
        }
        if (names.length === 0) {
            advisories = {};
            return;
        }
        advisoryProcess.command = Backend.advisoryCommand(names);
        advisoryProcess.running = true;
    }

    Process {
        id: advisoryProcess

        stdout: SplitParser {
            onRead: line => {
                let event;
                try {
                    event = JSON.parse(line);
                } catch (e) {
                    return;
                }
                if (event.event === "advisories")
                    root.advisories = event.packages || ({});
            }
        }
    }

    // ── Failure reasons outlive the run panel ───────────────────────────────
    // A package that failed is still a pending update, so it comes back in
    // the list — but the reason lived only in the engine, which the shell
    // reload after a dms pass throws away. Exactly the runs where knowing
    // why matters most. Persist the failures and hand them back to the
    // engine at the next start, so the card keeps carrying its own story.
    function _saveFailures() {
        const failures = [];
        for (const ri of engine.runItems || []) {
            const state = engine.itemStates[ri.key] || {};
            if (state.status !== "error")
                continue;
            failures.push({
                key: ri.key,
                name: ri.pkg.name || "",
                detail: state.detail || "",
                error: engine.runErrorDetails[ri.key] || ""
            });
        }
        PluginService.savePluginData("dankSoftwareDepot", "lastRunFailures", failures.length > 0 ? {
            ts: Math.floor(Date.now() / 1000),
            items: failures
        } : {});
    }

    property bool _restoredFailures: false
    // Keys restored from a previous run — pruned once the package stops
    // being a pending update, never touched while a run is live
    property var _restoredKeys: []

    function _restoreFailures() {
        if (_restoredFailures || Object.keys(pluginData || {}).length === 0)
            return;
        _restoredFailures = true;
        const saved = pluginData.lastRunFailures;
        const items = (saved && saved.items) || [];
        if (items.length === 0)
            return;
        const states = Object.assign({}, engine.itemStates);
        const details = Object.assign({}, engine.runErrorDetails);
        const keys = [];
        for (const item of items) {
            states[item.key] = {
                status: "error",
                fraction: 0,
                detail: item.detail || ""
            };
            if (item.error)
                details[item.key] = item.error;
            keys.push(item.key);
        }
        engine.itemStates = states;
        engine.runErrorDetails = details;
        _restoredKeys = keys;
    }

    // A restored failure is only true until the package is updated by
    // something else; once it is no longer pending, drop the verdict.
    function _pruneRestoredFailures() {
        if (_restoredKeys.length === 0 || engine.running || !_serviceHasState)
            return;
        const pending = new Set((pendingUpdates || []).map(pkg => store.keyFor(pkg)));
        // Only system and flatpak keys are answerable from this list;
        // firmware and AppImages have their own sources
        const stale = _restoredKeys.filter(key => (key.startsWith("system/") || key.startsWith("flatpak/")) && !pending.has(key));
        if (stale.length === 0)
            return;
        const states = Object.assign({}, engine.itemStates);
        const details = Object.assign({}, engine.runErrorDetails);
        for (const key of stale) {
            delete states[key];
            delete details[key];
        }
        engine.itemStates = states;
        engine.runErrorDetails = details;
        _restoredKeys = _restoredKeys.filter(key => pending.has(key));
        if (_restoredKeys.length === 0)
            PluginService.savePluginData("dankSoftwareDepot", "lastRunFailures", {});
    }

    property bool _replayedPendingLog: false

    onPluginDataChanged: {
        _replayPendingRunLog();
        _restoreFailures();
    }

    function _replayPendingRunLog() {
        // An empty object means the host hasn't delivered the settings yet
        if (_replayedPendingLog || Object.keys(pluginData || {}).length === 0)
            return;
        _replayedPendingLog = true;
        const stash = pluginData.pendingShellRunLog;
        if (!stash || !(stash.shell || []).length)
            return;
        // Ask about the shell packages and about every system row that was
        // still failing when the snapshot was taken — the shell pass sits
        // between the two moments and can have changed the answer.
        const names = stash.shell.map(s => s.base);
        for (const it of stash.items || []) {
            if (it.status === "error" && it.base)
                names.push(it.base);
        }
        replayVerifyProcess.command = Backend.installedVersionsCommand(names);
        replayVerifyProcess.running = true;
    }

    Process {
        id: replayVerifyProcess

        stdout: StdioCollector {
            onStreamFinished: {
                const stash = root.pluginData.pendingShellRunLog || {};
                const installed = {};
                for (const line of (text || "").split("\n")) {
                    const parts = line.split("\t");
                    if (parts.length === 2)
                        (installed[parts[0].trim()] = installed[parts[0].trim()] || []).push(parts[1].trim());
                }
                const noEpoch = v => (v || "").replace(/^\d+:/, "");
                const arrived = (base, to) => {
                    const want = noEpoch(to);
                    return want !== "" && (installed[base] || []).some(evr => noEpoch(evr) === want);
                };
                // A row that failed before the shell pass but carries its
                // target version now did arrive — the log records what the
                // system says, not what the run last believed.
                const items = (stash.items || []).map(it => {
                    if (it.status !== "error" || !it.base || !arrived(it.base, it.to))
                        return it;
                    const fixed = Object.assign({}, it, {
                        status: "done"
                    });
                    delete fixed.reason;
                    delete fixed.error;
                    return fixed;
                });
                for (const s of stash.shell || []) {
                    items.push({
                        name: s.name,
                        id: s.base || s.name,
                        repo: "system",
                        from: s.from,
                        to: s.to,
                        source: "System",
                        status: arrived(s.base, s.to) ? "done" : "error"
                    });
                }
                let done = 0;
                let failed = 0;
                for (const it of items) {
                    if (it.status === "done")
                        done++;
                    else if (it.status === "error")
                        failed++;
                }
                const type = failed > 0 ? "update-failed" : "update";
                const title = failed > 0 ? Tr.t("Update finished with issues (%1 failed)").arg(failed) : (done === 1 ? Tr.t("Updated %1 package") : Tr.t("Updated %1 packages")).arg(done);
                actionLog.record(type, title, items, stash.ts || 0);
                if (done > 0 && (stash.ts || 0) > (root.pluginData.lastUpdateUnix || 0))
                    PluginService.savePluginData("dankSoftwareDepot", "lastUpdateUnix", stash.ts);
                PluginService.savePluginData("dankSoftwareDepot", "pendingShellRunLog", {});
            }
        }
    }

    function _logRun() {
        if (!engine.runItems || engine.runItems.length === 0)
            return;
        const items = engine.runItems.map(ri => {
            const st = engine.itemStates[ri.key] || {};
            return {
                name: store.displayName(ri.pkg),
                from: ri.pkg.fromVersion || "",
                to: ri.pkg.toVersion || "",
                source: ri.pkg.repo === "flatpak" ? "Flatpak" : (ri.pkg.repo === "firmware" ? "Firmware" : (ri.pkg.repo === "appimage" ? "AppImage" : "System")),
                status: st.status || "",
                // Short reason for reading, tool output for reporting
                reason: st.status === "error" ? (st.detail || "") : "",
                error: engine.runErrorDetails[ri.key] || ""
            };
        });
        // A run always has items; an empty list means this is the tail of a
        // torn-down run (the shell reload), whose real entry the replay
        // writes. Logging it would leave a stray "0 packages updated".
        if (items.length === 0)
            return;
        let type = "update";
        let title = (engine.completedCount === 1 ? Tr.t("Updated %1 package") : Tr.t("Updated %1 packages")).arg(engine.completedCount);
        if (engine.phase === "cancelled") {
            type = "update-cancelled";
            title = Tr.t("Update cancelled (%1 of %2 done)").arg(engine.completedCount).arg(engine.plannedCount);
        } else if (engine.failedCount > 0) {
            type = "update-failed";
            title = Tr.t("Update finished with issues (%1 failed)").arg(engine.failedCount);
        }
        actionLog.record(type, title, items);
        // The run survived to its normal logging — the stashed entry for a
        // possible shell reload is not needed anymore
        PluginService.savePluginData("dankSoftwareDepot", "pendingShellRunLog", {});
    }

    UpdateEngine {
        id: engine
        heldKeys: root.heldSystemKeys
        pendingUpdates: root.pendingUpdates
        packageSizes: (root.updateSizes && root.updateSizes.rpmSizes) || ({})
        firmwareService: root.includeFirmware ? firmware : null
        appimageUpdates: root.appimageUpdates

        // The dms pass is about to reload the shell — stash the log entry
        // and the failure reasons it would otherwise swallow
        onPhaseChanged: {
            if (phase === "dms") {
                root._stashFromEngine();
                root._saveFailures();
            }
        }

        onRunMeasured: (seconds, items) => root._recordRun(seconds, items)

        onFinished: ok => {
            root.confirmArmed = false;
            root._saveFailures();
            root._logRun();
            eolProcess.running = true;
            if (engine.completedCount > 0) {
                PluginService.savePluginData("dankSoftwareDepot", "lastUpdateUnix", Math.floor(Date.now() / 1000));
                root._evaluateReboot();
            }
        }
    }

    UpdaterWindow {
        id: updaterWindow
        store: store
        engine: engine
        widgetRoot: root
        firmware: root.includeFirmware ? firmware : null
        showRuntimes: root.showRuntimes
        lastUpdateUnix: root.lastUpdateUnix
        checkFraction: root.checkFraction
        checkElapsedSecs: root.checkElapsedSecs
        estCheckSecs: root.estCheckSecs
    }

    IpcHandler {
        target: "dankSoftwareDepot"

        function open(): void {
            // Always land on the Updates tab — also when the window was
            // already open on another tab (notification click)
            updaterWindow.activate();
            updaterWindow.openTab(0);
        }

        function close(): void {
            updaterWindow.visible = false;
        }

        function toggle(): void {
            updaterWindow.toggle();
        }

        function tab(index: int): void {
            updaterWindow.activate();
            updaterWindow.openTab(index);
        }

        function updateFlatpakOne(appid: string): void {
            engine.start({
                dnf: false,
                flatpak: true,
                flatpakIds: [appid]
            });
        }

        function updateAll(): void {
            engine.start({});
        }

        function check(): void {
            store.refresh(SystemUpdateService.availableUpdates);
            SystemUpdateService.checkForUpdates();
            if (root.includeFirmware)
                firmware.check();
        }
    }

    // Persist the current list (only when it comes from real daemon state)
    // so it can be shown right away after the next restart. Triggered on
    // both signals because the service assigns availableUpdates before
    // lastCheckUnix — either alone can fire while the other is still stale.
    function _saveUpdatesSnapshot() {
        if (SystemUpdateService.lastCheckUnix <= 0)
            return;
        PluginService.savePluginData("dankSoftwareDepot", "updatesSnapshot", {
            ts: Math.floor(Date.now() / 1000),
            packages: (SystemUpdateService.availableUpdates || []).slice(0, 500)
        });
    }

    Connections {
        target: SystemUpdateService

        function onAvailableUpdatesChanged() {
            store.refresh(SystemUpdateService.availableUpdates);
            sizesDebounce.restart();
            root._saveUpdatesSnapshot();
        }

        function onLastCheckUnixChanged() {
            root._saveUpdatesSnapshot();
        }
    }

    Component.onCompleted: {
        if (pendingUpdates.length > 0)
            store.refresh(pendingUpdates);
    }

    // pluginData (and with it the persisted snapshot) loads after component
    // completion, so run enrichment (names, icons) whenever the restored
    // list actually lands — otherwise snapshot rows show generic icons.
    onPendingUpdatesChanged: {
        if (!_serviceHasState && pendingUpdates.length > 0) {
            store.refresh(pendingUpdates);
            _reconcileSnapshot();
        }
        _pruneRestoredFailures();
        advisoryDebounce.restart();
    }

    // A restored snapshot can contain updates installed in the last moments
    // before a shell reload (the DMS pass updates the daemon itself, so no
    // post-run save could happen). Drop every rpm whose target version is
    // already installed.
    function _reconcileSnapshot() {
        const pkgs = (pluginData.updatesSnapshot || {}).packages || [];
        const names = [];
        for (const pkg of pkgs) {
            if (pkg.repo !== "flatpak")
                names.push(store.stripArch(pkg.name));
        }
        if (names.length === 0)
            return;
        snapshotPruneProcess.command = ["rpm", "-q", "--qf", "%{NAME}\\t%{EVR}\\n"].concat(names);
        snapshotPruneProcess.running = true;
    }

    Process {
        id: snapshotPruneProcess

        stdout: StdioCollector {
            onStreamFinished: {
                const installed = {};
                for (const line of text.split("\n")) {
                    const parts = line.split("\t");
                    if (parts.length === 2)
                        installed[parts[0].trim()] = parts[1].trim();
                }
                const noEpoch = v => String(v || "").replace(/^\d+:/, "");
                const snap = root.pluginData.updatesSnapshot || {};
                const pkgs = snap.packages || [];
                const keep = pkgs.filter(pkg => {
                    if (pkg.repo === "flatpak")
                        return true;
                    const evr = installed[store.stripArch(pkg.name)];
                    return !evr || noEpoch(evr) !== noEpoch(pkg.toVersion);
                });
                if (keep.length !== pkgs.length)
                    PluginService.savePluginData("dankSoftwareDepot", "updatesSnapshot", {
                        ts: snap.ts || 0,
                        packages: keep
                    });
            }
        }
    }

    // And rebuild real daemon state without user action: when it comes up
    // empty (it forgets its list on restart), trigger a check ourselves.
    Timer {
        interval: 8000
        running: true

        onTriggered: {
            if (!root._serviceHasState && !SystemUpdateService.isChecking)
                SystemUpdateService.checkForUpdates();
        }
    }

    // The daemon already knows the update list but only pushes state on
    // changes; ask for it explicitly so the pill is correct right after a
    // shell (re)start instead of showing 0 until the next check.
    Timer {
        id: initialStateTimer
        interval: 2000
        running: true
        repeat: false
        onTriggered: SystemUpdateService.requestState()
    }

    Connections {
        target: SystemUpdateService

        function onSysupdateAvailableChanged() {
            if (SystemUpdateService.sysupdateAvailable)
                SystemUpdateService.requestState();
        }
    }

    function requestUpdateAll() {
        if (engine.running)
            return;
        if (confirmBeforeUpdate && !confirmArmed) {
            confirmArmed = true;
            confirmTimer.restart();
            return;
        }
        confirmArmed = false;
        engine.start({});
    }

    Timer {
        id: confirmTimer
        interval: 5000
        onTriggered: root.confirmArmed = false
    }

    pillClickAction: root.pillOpensWindow ? (() => updaterWindow.toggle()) : null

    // ── Bar pills ────────────────────────────────────────────────────────────
    readonly property bool _busy: SystemUpdateService.isChecking || engine.running
    readonly property string _pillText: {
        if (engine.running)
            return engine.plannedCount > 0 ? engine.completedCount + "/" + engine.plannedCount : "";
        if (SystemUpdateService.isChecking)
            return "";
        return root.effectiveCount.toString();
    }
    readonly property color _pillColor: {
        if (engine.running)
            return Theme.primary;
        if (root.rebootRecommended)
            return Theme.warning;
        if (SystemUpdateService.hasError)
            return Theme.error;
        return root.effectiveCount > 0 ? Theme.primary : Theme.surfaceVariantText;
    }
    readonly property string _pillIcon: {
        if (engine.running)
            return "downloading";
        if (SystemUpdateService.isChecking)
            return "refresh";
        if (root.rebootRecommended)
            return "restart_alt";
        if (SystemUpdateService.hasError)
            return "release_alert";
        return root.effectiveCount > 0 ? "deployed_code_update" : "check_circle";
    }

    visibilityCommand: ""
    conditionVisible: !hideWhenUpToDate || root.effectiveCount > 0 || engine.running || SystemUpdateService.isChecking

    popoutWidth: 420
    popoutHeight: 520

    // Popout list: run snapshot while running, otherwise pending minus held
    readonly property var popoutModel: {
        if (engine.phase !== "idle" && (engine.runItems || []).length > 0)
            return engine.runItems.map(item => item.pkg);
        const rows = pendingUpdates.filter(pkg => !store.isHeld(pkg));
        if (includeFirmware) {
            for (const fw of firmware.updates || []) {
                rows.push({
                    name: fw.name,
                    repo: "firmware",
                    fromVersion: fw.current,
                    toVersion: fw.next
                });
            }
        }
        for (const ai of appimageUpdates || []) {
            rows.push({
                name: ai.id,
                displayName: ai.name,
                repo: "appimage",
                fromVersion: ai.current,
                toVersion: ai.latest
            });
        }
        return rows;
    }
    readonly property int heldCount: heldSystemKeys.length

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DankIcon {
                id: hPillIcon
                // Spins during a check: distance-field rendering survives
                // rotation, the default pixel-grid hinting does not
                smoothTransform: true
                name: root._pillIcon
                color: root._pillColor
                size: root.iconSize
                anchors.verticalCenter: parent.verticalCenter

                RotationAnimator on rotation {
                    from: 0
                    to: 360
                    duration: 1000
                    loops: Animation.Infinite
                    running: SystemUpdateService.isChecking

                    onRunningChanged: {
                        if (!running)
                            hPillIcon.rotation = 0;
                    }
                }
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root._pillText
                color: root._pillColor
                font.pixelSize: Theme.fontSizeMedium
                visible: root._pillText !== "0" && root._pillText !== ""
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            DankIcon {
                id: vPillIcon
                // Spins during a check: distance-field rendering survives
                // rotation, the default pixel-grid hinting does not
                smoothTransform: true
                name: root._pillIcon
                color: root._pillColor
                size: root.iconSize
                anchors.horizontalCenter: parent.horizontalCenter

                RotationAnimator on rotation {
                    from: 0
                    to: 360
                    duration: 1000
                    loops: Animation.Infinite
                    running: SystemUpdateService.isChecking

                    onRunningChanged: {
                        if (!running)
                            vPillIcon.rotation = 0;
                    }
                }
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root._pillText
                color: root._pillColor
                font.pixelSize: Theme.fontSizeSmall
                visible: root._pillText !== "0" && root._pillText !== ""
            }
        }
    }

    // ── Compact popout ───────────────────────────────────────────────────────
    popoutContent: Component {
        Item {
            // PluginPopout derives the popup height from implicitHeight
            implicitHeight: 520
            height: implicitHeight

            // Header
            Item {
                id: popoutHeader
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: Theme.spacingL
                anchors.rightMargin: Theme.spacingL
                anchors.topMargin: Theme.spacingL
                height: 40

                Image {
                    id: popoutHeaderLogo
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: 32
                    height: 32
                    source: root.appIconSource
                    sourceSize.width: 64
                    sourceSize.height: 64
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                }

                Column {
                    anchors.left: popoutHeaderLogo.right
                    anchors.leftMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0

                    StyledText {
                        text: "Dank Software Depot"
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                    }

                    BusyText {
                        text: {
                            if (engine.running)
                                return engine.phaseLabel;
                            if (SystemUpdateService.isChecking)
                                return Tr.t("Checking…");
                            if (SystemUpdateService.hasError)
                                return Tr.t("Check failed");
                            const count = root.effectiveCount;
                            return count === 0 ? Tr.t("Up to date") : (count === 1 ? Tr.t("%1 update available") : Tr.t("%1 updates available")).arg(count);
                        }
                        pixelSize: Theme.fontSizeSmall
                        color: SystemUpdateService.hasError ? Ui.failColor : Theme.surfaceVariantText
                    }
                }

                DankActionButton {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    buttonSize: 30
                    iconName: "open_in_new"
                    iconSize: 18
                    iconColor: Theme.surfaceText
                    tooltipText: Tr.t("Open updater window")
                    onClicked: {
                        root.closePopout();
                        updaterWindow.visible = true;
                    }
                }
            }

            // Reboot recommendation banner
            Rectangle {
                id: popoutRebootBanner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: popoutHeader.bottom
                anchors.leftMargin: Theme.spacingL
                anchors.rightMargin: Theme.spacingL
                anchors.topMargin: Theme.spacingS
                visible: root.rebootRecommended
                height: visible ? 40 : 0
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Theme.warning, 0.14)
                border.width: 1
                border.color: Theme.withAlpha(Theme.warning, 0.35)

                RowLayout {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.spacingS
                    anchors.rightMargin: Theme.spacingXS
                    spacing: Theme.spacingS

                    DankIcon {
                        name: "restart_alt"
                        size: 17
                        color: Theme.warning
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: Tr.t("Computer restart recommended")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    Item {
                        Layout.preferredWidth: popoutRebootButton.width
                        Layout.preferredHeight: popoutRebootButton.height

                        DankButton {
                            id: popoutRebootButton
                            buttonHeight: 26
                            horizontalPadding: Theme.spacingM
                            text: root.confirmReboot ? Tr.t("Confirm?") : Tr.t("Restart")
                            backgroundColor: root.confirmReboot ? Theme.error : Theme.buttonBg
                            textColor: root.confirmReboot ? Ui.onColor(Theme.error) : Theme.buttonText
                            onClicked: root.requestReboot()
                        }
                    }
                }
            }

            // Progress block while running
            Rectangle {
                id: popoutProgress
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: popoutRebootBanner.bottom
                anchors.leftMargin: Theme.spacingL
                anchors.rightMargin: Theme.spacingL
                anchors.topMargin: Theme.spacingM
                visible: engine.phase !== "idle"
                height: visible ? progressContent.implicitHeight + Theme.spacingM * 2 : 0
                radius: Theme.cornerRadius
                color: Theme.surfaceContainer

                Column {
                    id: progressContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM
                    spacing: Theme.spacingXS

                    PhaseIndicator {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: engine.running
                        step: engine.phaseStep
                        running: engine.running
                        failed: engine.failedCount > 0
                        compact: true
                    }

                    // No overall bar/percentage: an aggregate fraction over
                    // parallel downloads and mixed phases misleads more than
                    // it informs — per-item rows carry the progress.
                    StyledText {
                        width: parent.width
                        text: {
                            if (engine.running) {
                                const current = engine.currentItem ? " · " + store.prettyId(engine.currentItem) : "";
                                return engine.phaseLabel + current;
                            }
                            if (engine.phase === "done")
                                return Tr.t("%1 updated").arg(engine.completedCount) + (engine.failedCount > 0 ? ", " + Tr.t("%1 failed").arg(engine.failedCount) : "");
                            return engine.phaseLabel;
                        }
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                        elide: Text.ElideMiddle
                        horizontalAlignment: Text.AlignHCenter
                    }

                    StyledText {
                        width: parent.width
                        visible: engine.running && engine.progressDetail !== ""
                        text: engine.progressDetail
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignHCenter
                    }
                }
            }

            // Compact list
            DankListView {
                id: compactList
                Component.onCompleted: Ui.softenScrollbar(compactList)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: popoutProgress.visible ? popoutProgress.bottom : popoutHeader.bottom
                anchors.bottom: popoutButtons.visible ? popoutButtons.top : parent.bottom
                anchors.leftMargin: Theme.spacingL
                anchors.rightMargin: Theme.spacingL
                anchors.topMargin: Theme.spacingM
                anchors.bottomMargin: Theme.spacingM
                clip: true
                spacing: 2
                model: root.popoutModel
                visible: root.popoutModel.length > 0

                delegate: Rectangle {
                    id: compactRow

                    required property var modelData

                    readonly property var info: store.infoFor(modelData)
                    readonly property var itemState: engine.stateFor(modelData)
                    readonly property string displayName: store.displayName(modelData)

                    width: compactList.width
                    height: 40
                    radius: Theme.cornerRadius
                    color: rowHover.hovered ? Theme.surfaceHover : "transparent"

                    HoverHandler {
                        id: rowHover
                    }

                    Row {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: Theme.spacingS
                        anchors.rightMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS

                        Item {
                            width: 26
                            height: 26
                            anchors.verticalCenter: parent.verticalCenter

                            Image {
                                id: rowLogo
                                anchors.fill: parent
                                source: (compactRow.info && compactRow.info.icon) ? "file://" + compactRow.info.icon : ""
                                sourceSize.width: 52
                                sourceSize.height: 52
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                                visible: status === Image.Ready
                            }

                            DankIcon {
                                anchors.centerIn: parent
                                visible: rowLogo.status !== Image.Ready
                                name: compactRow.modelData.repo === "flatpak" ? "apps" : "memory"
                                size: 18
                                color: Theme.surfaceVariantText
                            }
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: compactRow.displayName
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                            width: parent.width - 26 - statusIndicator.width - Theme.spacingS * 2
                        }

                        Item {
                            id: statusIndicator
                            width: 104
                            height: 20
                            anchors.verticalCenter: parent.verticalCenter

                            StyledText {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !compactRow.itemState || compactRow.itemState.status === "pending"
                                text: compactRow.modelData.toVersion || (compactRow.info && compactRow.info.releases && compactRow.info.releases.length > 0 && compactRow.info.releases[0].newer ? compactRow.info.releases[0].version : "")
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: Theme.primary
                                elide: Text.ElideMiddle
                                width: parent.width
                                horizontalAlignment: Text.AlignRight
                            }

                            StyledText {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                visible: compactRow.itemState && compactRow.itemState.status === "active"
                                text: compactRow.itemState ? Math.round((compactRow.itemState.fraction || 0) * 100) + "%" : ""
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.weight: Font.Medium
                                color: Theme.primary
                            }

                            DankIcon {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                visible: compactRow.itemState && compactRow.itemState.status === "done"
                                name: "check_circle"
                                size: 16
                                color: Theme.success
                            }

                            DankIcon {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                visible: compactRow.itemState && compactRow.itemState.status === "error"
                                name: "error"
                                size: 16
                                color: Ui.failColor
                            }
                        }
                    }
                }
            }

            // Empty state: the big icon doubles as a check-for-updates button
            Item {
                anchors.fill: compactList
                visible: root.popoutModel.length === 0

                MouseArea {
                    id: emptyStateArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: SystemUpdateService.isChecking ? Qt.ArrowCursor : Qt.PointingHandCursor
                    onClicked: {
                        if (!SystemUpdateService.isChecking && !engine.running)
                            SystemUpdateService.checkForUpdates();
                    }
                }

                Column {
                    anchors.centerIn: parent
                    spacing: Theme.spacingS

                    // Room for the pulse rings around the 48px disc, at the
                    // same ratio the window's hero uses
                    Item {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.round(48 * 1.87)
                        height: Math.round(48 * 1.87)

                        Rectangle {
                            anchors.centerIn: parent
                            width: 48
                            height: 48
                            radius: 24
                            // Light mode: solid primary disc so the white penguin stays visible
                            color: {
                                if (Theme.isLightMode)
                                    return emptyStateArea.containsMouse && !SystemUpdateService.isChecking ? Qt.darker(Theme.primary, 1.15) : Theme.primary;
                                return emptyStateArea.containsMouse && !SystemUpdateService.isChecking ? Theme.withAlpha(Theme.primary, 0.12) : "transparent";
                            }

                            Behavior on color {
                                ColorAnimation {
                                    duration: Theme.shortDuration
                                }
                            }
                        }

                        // Same treatment as the window's hero: the logo stays
                        // and the check pulses around it
                        PulseRings {
                            id: popoutPulse
                            anchors.fill: parent
                            running: SystemUpdateService.isChecking
                        }

                        Image {
                            id: popoutLogoImage
                            anchors.centerIn: parent
                            width: 34
                            height: 34
                            source: root.dankLogoPath !== "" ? "file://" + root.dankLogoPath : ""
                            sourceSize.width: 68
                            sourceSize.height: 68
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            scale: popoutPulse.breath
                            visible: status === Image.Ready && (SystemUpdateService.isChecking || !emptyStateArea.containsMouse)
                        }

                        DankIcon {
                            id: popoutEmptyIcon
                            anchors.centerIn: parent
                            visible: !popoutLogoImage.visible
                            scale: popoutPulse.breath
                            name: (SystemUpdateService.isChecking || emptyStateArea.containsMouse) ? "refresh" : "task_alt"
                            size: 40
                            color: {
                                if (Theme.isLightMode)
                                    return "white";
                                if (SystemUpdateService.isChecking || emptyStateArea.containsMouse)
                                    return Theme.primary;
                                return Theme.success;
                            }
                        }
                    }

                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: {
                            if (SystemUpdateService.isChecking)
                                return Tr.t("Checking for updates…");
                            if (emptyStateArea.containsMouse)
                                return Tr.t("Check for updates");
                            return Tr.t("Your system is up to date!");
                        }
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceText
                    }

                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: emptyStateArea.containsMouse && !SystemUpdateService.isChecking && root.lastUpdateUnix > 0
                        text: Tr.t("Updated %1").arg(root.formatAgo(root.lastUpdateUnix))
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }
            }

            // Footer buttons
            Row {
                id: popoutButtons
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: Theme.spacingL
                anchors.rightMargin: Theme.spacingL
                anchors.bottomMargin: Theme.spacingL
                height: 40
                spacing: Theme.spacingM
                // Hidden while a finished run's trailing check still lists
                // the just-updated packages
                visible: (root.effectiveCount > 0 && !(engine.phase !== "idle" && !engine.running && SystemUpdateService.isChecking)) || engine.running

                DankButton {
                    width: (parent.width - Theme.spacingM) / 2
                    buttonHeight: parent.height

                    readonly property bool busyRun: engine.running || engine.deferred

                    text: {
                        if (busyRun)
                            return Tr.t("Cancel");
                        if (root.confirmArmed)
                            return Tr.t("Confirm?");
                        return Tr.t("Update All") + (root.updateSizeText !== "" ? " · " + root.updateSizeText : "");
                    }
                    backgroundColor: {
                        if (busyRun)
                            return Theme.errorPressed;
                        if (root.confirmArmed)
                            return Theme.warning;
                        return Theme.buttonBg;
                    }
                    textColor: busyRun ? Theme.surfaceText : Theme.buttonText
                    onClicked: {
                        if (busyRun) {
                            engine.cancel();
                        } else {
                            root.requestUpdateAll();
                        }
                    }
                }

                DankButton {
                    width: (parent.width - Theme.spacingM) / 2
                    buttonHeight: parent.height
                    text: Tr.t("Details")
                    backgroundColor: Theme.surfaceContainerHigh
                    textColor: Theme.surfaceText
                    onClicked: {
                        root.closePopout();
                        updaterWindow.visible = true;
                    }
                }
            }
        }
    }
}
