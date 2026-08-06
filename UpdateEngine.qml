import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

// Drives the actual update run and models progress honestly:
//  - system (dnf) packages go through the DMS daemon (polkit auth, cancel
//    support); progress is derived from the daemon's log stream ("[x/y]"
//    step lines, locale-independent).
//  - flatpaks run through scripts/flatpak_helper.py (libflatpak) which
//    reports exact per-operation byte progress.
// Overall progress is weighted by download bytes (flatpak: exact, dnf:
// nominal per-package weight), so the bar tracks real work instead of
// jumping to 99%. ETA comes from an exponentially smoothed completion rate.
Item {
    id: engine

    // ── Public state ─────────────────────────────────────────────────────────
    property bool running: false
    // idle | starting | dnf-download | dnf-install | flatpak | done | failed | cancelled
    property string phase: "idle"
    property real overallFraction: 0
    property int etaSeconds: -1
    property string currentItem: ""
    property string currentDetail: ""
    property int failedCount: 0
    property int completedCount: 0
    property int plannedCount: 0
    // key ("flatpak/<appid>" | "system/<basename>") -> {status, fraction, detail}
    // status: pending | active | done | error
    property var itemStates: ({})
    // Snapshot of the items included in the current/last run: [{pkg, key}]
    property var runItems: []
    // Download-phase details
    property real flatpakBytesDone: 0
    property real flatpakSpeed: 0
    property int opsDone: 0
    property int opsTotal: 0

    // Rich per-phase detail line: sizes, speed and counts
    readonly property string progressDetail: {
        switch (phase) {
        case "dnf-download":
            // Before the first [x/y] series dnf is refreshing repo metadata —
            // say so instead of sitting on a silent 0%
            return _dnfStageY > 0 ? Tr.t("package %1 of %2").arg(Math.min(_dnfStageX + 1, _dnfStageY)).arg(_dnfStageY) : Tr.t("Loading repositories…");
        case "dnf-install":
        case "dms":
            return _dnfStageY > 0 ? Tr.t("step %1 of %2").arg(Math.min(_dnfStageX + 1, _dnfStageY)).arg(_dnfStageY) : "";
        case "flatpak": {
            if (!_flatpakPlanKnown)
                return "";
            let text = Tr.t("%1 of %2").arg(formatBytes(flatpakBytesDone)).arg(formatBytes(_flatpakPlannedBytes));
            if (flatpakSpeed > 10 * 1024)
                text += " · " + formatBytes(flatpakSpeed) + "/s";
            if (opsTotal > 1)
                text += " · " + Tr.t("%1 of %2").arg(Math.min(opsDone + 1, opsTotal)).arg(opsTotal);
            return text;
        }
        default:
            return "";
        }
    }

    signal finished(bool ok)

    // Keys ("system/<basename>") of packages held back by dnf config
    // (versionlock/excludepkgs); they are skipped in runs. Bound by the widget.
    property var heldKeys: []
    // Effective pending-update list from the host (live daemon data, or the
    // persisted snapshot right after a restart) — start() must not read the
    // service directly or a run from snapshot state sees an empty list and
    // loses the delayed/held exclusions.
    property var pendingUpdates: []

    // Keys of updates still inside the configured delay window (maturity
    // period); excluded from runs unless explicitly selected. Bound by the
    // widget.
    property var delayedKeys: []

    // Updating DMS/Quickshell packages makes Quickshell live-reload the shell,
    // which tears down this UI mid-run. They are excluded from the first dnf
    // pass and updated in a separate final pass once everything else is done;
    // that transaction runs inside the daemon, so it completes even if the
    // shell reloads while it runs.
    readonly property var shellPackagePattern: /^(dms|dms-cli|dms-greeter|quickshell(-git)?)$/

    // FirmwareService instance (bound by the widget); firmware updates run
    // as the last phase via fwupdmgr.
    property var firmwareService: null

    // Pending AppImage updates [{id, name, current, latest, url, size}],
    // bound by the widget; they run in their own phase via scripts/appimage.py.
    property var appimageUpdates: []
    // rpm base name -> exact download size in bytes (from dnf repoquery),
    // used for per-package byte detail during the download stage
    property var packageSizes: ({})

    // Clear the finished/failed result panel
    function dismiss() {
        if (!running)
            phase = "idle";
    }

    // Auto-dismiss a fully successful result; failures stay until dismissed
    Timer {
        id: autoDismissTimer
        interval: 8000
        onTriggered: {
            if (!engine.running && engine.phase === "done" && engine.failedCount === 0)
                engine.phase = "idle";
        }
    }

    onPhaseChanged: {
        if (phase === "done" && failedCount === 0)
            autoDismissTimer.restart();
    }

    // Stepper position for the phase indicator: 0 check, 1 download, 2 install, 3 done
    readonly property int phaseStep: {
        switch (phase) {
        case "dnf-download":
            return 1;
        case "dnf-install":
            return 2;
        case "flatpak":
            return _flatpakMostlyDownloading ? 1 : 2;
        case "appimage":
            return 1;
        case "firmware":
        case "dms":
            return 2;
        case "done":
        case "failed":
        case "cancelled":
            return 3;
        default:
            return 0;
        }
    }

    readonly property string phaseLabel: {
        switch (phase) {
        case "starting":
            return Tr.t("Preparing update…");
        case "dnf-download":
            return Tr.t("Downloading system packages…");
        case "dnf-install":
            return Tr.t("Installing system packages…");
        case "flatpak":
            return _flatpakMostlyDownloading ? Tr.t("Downloading Flatpak updates…") : Tr.t("Installing Flatpak updates…");
        case "appimage":
            return Tr.t("Updating AppImages…");
        case "firmware":
            return Tr.t("Updating firmware…");
        case "dms":
            return Tr.t("Updating DankMaterialShell… (shell may reload)");
        case "done":
            return failedCount > 0 ? Tr.t("Finished with issues") : Tr.t("Everything up to date");
        case "failed":
            return Tr.t("Update failed");
        case "cancelled":
            return Tr.t("Update cancelled");
        default:
            return "";
        }
    }

    // ── Tuning ───────────────────────────────────────────────────────────────
    readonly property real dnfPkgWeight: 12 * 1024 * 1024   // nominal bytes per rpm
    readonly property real dnfDownloadShare: 0.45
    readonly property real flatpakFallbackOpWeight: 30 * 1024 * 1024

    // ── Internals ────────────────────────────────────────────────────────────
    property bool _wantDnf: false
    property bool _wantFlatpak: false
    property bool _wantFirmware: false
    property bool _wantShell: false
    property bool _shellDone: true
    property int _shellCount: 0
    property var _shellNames: []
    property var _shellNameToKey: ({})
    // base name -> target EVR, for post-pass verification against rpm
    property var _daemonExpectedEvr: ({})
    property var _delayedRpmNames: []
    property bool _firmwareFiltered: false
    property bool _wantAppimage: false
    property var _appimageItems: []
    property var _aiOps: ({})            // id -> {weight, fraction, done}
    property string _aiCurrentId: ""
    property string _daemonKind: "dnf"    // which daemon pass is active: dnf | shell
    property var _firmwareItems: []
    property real _firmwareFraction: 0
    property int _firmwareDone: 0
    readonly property real firmwareItemWeight: 50 * 1024 * 1024
    property var _flatpakIds: []
    property bool _dnfDone: false
    property int _dnfCount: 0
    property int _dnfStage: 0            // 0 not started, 1 download, 2 install
    property int _dnfStageX: 0
    property int _dnfStageY: 0
    property int _dnfLogCursor: 0
    property var _dnfNameToKey: ({})
    property bool _dnfSawUpgrading: false
    property var _flatpakOps: ({})       // ref -> {appid, weight, fraction, done}
    property real _flatpakPlannedBytes: 0
    property bool _flatpakPlanKnown: false
    property int _flatpakOpCount: 0
    property bool _flatpakMostlyDownloading: true
    property real _rate: 0               // weight units per second (EWMA)
    property real _lastWeightDone: 0
    property int _elapsedSeconds: 0

    function formatBytes(bytes) {
        if (bytes >= 1024 * 1024 * 1024)
            return (bytes / (1024 * 1024 * 1024)).toFixed(1) + " GB";
        if (bytes >= 1024 * 1024)
            return Math.round(bytes / (1024 * 1024)) + " MB";
        return Math.max(1, Math.round(bytes / 1024)) + " kB";
    }

    function formatEta(seconds) {
        if (seconds < 0)
            return "";
        if (seconds < 60)
            return Tr.t("less than a minute left");
        const mins = Math.round(seconds / 60);
        if (mins < 60)
            return Tr.t("about %1 min left").arg(mins);
        return Tr.t("about %1 h %2 min left").arg(Math.floor(mins / 60)).arg(mins % 60);
    }

    function stateFor(pkg) {
        let key;
        if (pkg.repo === "flatpak")
            key = "flatpak/" + pkg.name;
        else if (pkg.repo === "firmware")
            key = "firmware/" + pkg.name;
        else if (pkg.repo === "appimage")
            key = "appimage/" + pkg.name;
        else
            key = "system/" + _stripArch(pkg.name);
        return itemStates[key] || null;
    }

    function _stripArch(name) {
        return (name || "").replace(/\.(x86_64|i686|noarch|aarch64|armv7hl|ppc64le|s390x)$/, "");
    }

    function _setItem(key, patch) {
        const updated = Object.assign({}, itemStates);
        updated[key] = Object.assign({}, updated[key] || {
            status: "pending",
            fraction: 0,
            detail: ""
        }, patch);
        itemStates = updated;
    }

    // A run requested while the daemon has no package state (right after its
    // restart) would be a silent no-op: the upgrade command needs a check
    // first. Defer the run, trigger the check (the UI shows its spinner) and
    // start for real when it lands.
    property var _deferredOpts: null
    // True while a requested run waits for the pre-run check — buttons show
    // their cancel state during this window too
    readonly property bool deferred: _deferredOpts !== null

    Connections {
        target: SystemUpdateService
        enabled: engine._deferredOpts !== null

        function onIsCheckingChanged() {
            if (SystemUpdateService.isChecking)
                return;
            const opts = engine._deferredOpts;
            engine._deferredOpts = null;
            if (!SystemUpdateService.hasError)
                Qt.callLater(() => engine.start(opts));
        }
    }

    // ── Run control ──────────────────────────────────────────────────────────
    function start(opts) {
        if (running)
            return;
        const options = opts || {};
        const daemonHasState = SystemUpdateService.lastCheckUnix > 0 || (SystemUpdateService.availableUpdates || []).length > 0;
        if (!daemonHasState && options.dnf !== false && (pendingUpdates || []).some(p => p.repo !== "flatpak")) {
            _deferredOpts = options;
            SystemUpdateService.checkForUpdates();
            return;
        }
        const held = new Set(heldKeys || []);
        const delayed = new Set(delayedKeys || []);
        const updates = pendingUpdates || [];
        const explicitFlatpak = (options.flatpakIds || []).length > 0;
        const dnfLive = updates.filter(p => p.repo !== "flatpak" && !held.has("system/" + _stripArch(p.name)));
        // An explicit rpm selection (per-app update button) runs alone:
        // every other pending rpm — delayed or not — joins the daemon's
        // ignore list for this run.
        const onlyRpm = (options.dnfNames && options.dnfNames.length > 0) ? new Set(options.dnfNames) : null;
        const dnfAll = onlyRpm ? dnfLive.filter(p => onlyRpm.has(p.name)) : dnfLive.filter(p => !delayed.has("system/" + _stripArch(p.name)));
        _delayedRpmNames = dnfLive.filter(p => onlyRpm ? !onlyRpm.has(p.name) : delayed.has("system/" + _stripArch(p.name))).map(p => p.name);
        const shellPkgs = (options.dnf !== false) ? dnfAll.filter(p => shellPackagePattern.test(_stripArch(p.name))) : [];
        const dnfPkgs = dnfAll.filter(p => !shellPackagePattern.test(_stripArch(p.name)));
        // An explicit selection (per-app update button) bypasses the delay
        const flatpakPkgs = updates.filter(p => p.repo === "flatpak" && (explicitFlatpak || !delayed.has("flatpak/" + p.name)));
        const delayedFlatpakCount = updates.filter(p => p.repo === "flatpak" && delayed.has("flatpak/" + p.name)).length;

        _wantDnf = (options.dnf !== false) && dnfPkgs.length > 0;
        _wantShell = shellPkgs.length > 0;
        _flatpakIds = options.flatpakIds || [];
        _wantFlatpak = (options.flatpak !== false) && flatpakPkgs.length > 0;
        if (_wantFlatpak && !explicitFlatpak && delayedFlatpakCount > 0) {
            // The helper updates everything when given no ids, so pass the
            // non-delayed set explicitly
            _flatpakIds = flatpakPkgs.map(p => p.name);
        }
        // AppImages join full runs and explicit selections; a flatpak-only
        // selection (flatpakIds) leaves them out
        let appimageItems = [];
        if (options.appimageIds && options.appimageIds.length > 0) {
            const wanted = new Set(options.appimageIds);
            appimageItems = (appimageUpdates || []).filter(u => wanted.has(u.id));
        } else if (options.appimage !== false && !explicitFlatpak) {
            appimageItems = (appimageUpdates || []).filter(u => !delayed.has("appimage/" + u.id));
        }
        _wantAppimage = appimageItems.length > 0;
        _appimageItems = appimageItems;
        const firmwareAll = (options.firmware !== false && firmwareService && firmwareService.available) ? (firmwareService.updates || []) : [];
        const firmwareItems = firmwareAll.filter(fw => !delayed.has("firmware/" + fw.name));
        _firmwareFiltered = firmwareItems.length !== firmwareAll.length;
        _wantFirmware = firmwareItems.length > 0;
        _firmwareItems = firmwareItems;

        if (!_wantDnf && !_wantFlatpak && !_wantFirmware && !_wantShell && !_wantAppimage)
            return;

        _dnfDone = !_wantDnf;
        _shellDone = !_wantShell;
        _shellCount = shellPkgs.length;
        _shellNames = shellPkgs.map(p => p.name);
        _daemonKind = "dnf";
        _dnfCount = dnfPkgs.length;
        _dnfStage = 0;
        _dnfStageX = 0;
        _dnfStageY = 0;
        _dnfLogCursor = 0;
        _dnfSawUpgrading = false;
        _flatpakOps = {};
        _flatpakPlannedBytes = 0;
        _flatpakPlanKnown = false;
        _flatpakOpCount = 0;
        _flatpakMostlyDownloading = true;
        _rate = 0;
        _lastWeightDone = 0;
        _elapsedSeconds = 0;
        failedCount = 0;
        completedCount = 0;
        etaSeconds = -1;
        overallFraction = 0;
        currentItem = "";
        currentDetail = "";

        const states = {};
        const nameMap = {};
        const expectedEvr = {};
        const items = [];
        const selectedFlatpak = new Set(_flatpakIds);
        plannedCount = 0;
        for (const pkg of dnfPkgs) {
            if (_wantDnf) {
                const base = _stripArch(pkg.name);
                if (states["system/" + base])
                    continue;
                states["system/" + base] = {
                    status: "pending",
                    fraction: 0,
                    detail: ""
                };
                nameMap[base] = "system/" + base;
                expectedEvr[base] = pkg.toVersion || "";
                items.push({
                    pkg: pkg,
                    key: "system/" + base
                });
                plannedCount++;
            }
        }
        for (const pkg of flatpakPkgs) {
            if (!_wantFlatpak)
                continue;
            if (_flatpakIds.length > 0 && !selectedFlatpak.has(pkg.name))
                continue;
            if (states["flatpak/" + pkg.name])
                continue;
            states["flatpak/" + pkg.name] = {
                status: "pending",
                fraction: 0,
                detail: ""
            };
            items.push({
                pkg: pkg,
                key: "flatpak/" + pkg.name
            });
            plannedCount++;
        }
        const aiOps = {};
        for (const ai of appimageItems) {
            states["appimage/" + ai.id] = {
                status: "pending",
                fraction: 0,
                detail: ""
            };
            aiOps[ai.id] = {
                weight: Math.max(ai.size || 0, 5 * 1024 * 1024),
                fraction: 0,
                done: false
            };
            items.push({
                pkg: {
                    name: ai.id,
                    displayName: ai.name,
                    repo: "appimage",
                    fromVersion: ai.current,
                    toVersion: ai.latest
                },
                key: "appimage/" + ai.id
            });
            plannedCount++;
        }
        _aiOps = aiOps;
        _aiCurrentId = "";
        for (const fw of firmwareItems) {
            states["firmware/" + fw.name] = {
                status: "pending",
                fraction: 0,
                detail: ""
            };
            items.push({
                pkg: {
                    name: fw.name,
                    repo: "firmware",
                    fromVersion: fw.current,
                    toVersion: fw.next
                },
                key: "firmware/" + fw.name
            });
            plannedCount++;
        }
        const shellMap = {};
        for (const pkg of shellPkgs) {
            const base = _stripArch(pkg.name);
            if (states["system/" + base])
                continue;
            states["system/" + base] = {
                status: "pending",
                fraction: 0,
                detail: Tr.t("runs last · reloads the shell")
            };
            shellMap[base] = "system/" + base;
            expectedEvr[base] = pkg.toVersion || "";
            items.push({
                pkg: pkg,
                key: "system/" + base
            });
            plannedCount++;
        }
        _shellNameToKey = shellMap;
        _dnfNameToKey = nameMap;
        _daemonExpectedEvr = expectedEvr;
        itemStates = states;
        runItems = items;
        flatpakBytesDone = 0;
        flatpakSpeed = 0;
        opsDone = 0;
        opsTotal = 0;
        _firmwareFraction = 0;
        _firmwareDone = 0;

        running = true;
        phase = "starting";
        etaTimer.start();

        if (_wantDnf) {
            _startDaemon("dnf");
        } else if (_wantFlatpak) {
            _startFlatpak();
        } else if (_wantAppimage) {
            _startAppimage();
        } else if (_wantFirmware) {
            _startFirmware();
        } else {
            _startDaemon("shell");
        }
    }

    function _afterAppimage() {
        if (_wantFirmware) {
            _startFirmware();
        } else if (_wantShell && !_shellDone) {
            _startDaemon("shell");
        } else {
            _finish(failedCount > 0 ? "failed" : "done");
        }
    }

    function _startAppimage() {
        phase = "appimage";
        const cmd = ["python3", Qt.resolvedUrl("scripts/appimage.py").toString().replace("file://", ""), "--update-ids"];
        for (const ai of _appimageItems)
            cmd.push(ai.id);
        appimageProcess.command = cmd;
        appimageProcess.running = true;
    }

    function _startDaemon(kind) {
        _daemonKind = kind;
        _dnfStage = 0;
        _dnfStageX = 0;
        _dnfStageY = 0;
        _dnfSawUpgrading = false;
        _daemonAttempts = 0;
        _sendDaemonUpgrade();
    }

    // The daemon can silently refuse an upgrade command fired right after
    // the previous pass finished (it is still winding down). Retry with a
    // short delay until it reports upgrading; give up visibly instead of
    // hanging on a phase that never starts.
    property int _daemonAttempts: 0

    function _sendDaemonUpgrade() {
        // Never fire an upgrade into a running check: the daemon kills the
        // dnf child mid-resolve when the two collide (observed as a pass
        // that "completes" without installing anything). The retry timer
        // re-enters here once the check settles.
        if (SystemUpdateService.isChecking) {
            daemonRetryTimer.restart();
            return;
        }
        const kind = _daemonKind;
        // Delayed rpms stay excluded in every daemon pass; shell packages
        // additionally sit out the first pass and run in the final one.
        let extraIgnored = _delayedRpmNames || [];
        if (kind === "shell") {
            phase = "dms";
        } else if (_wantShell) {
            extraIgnored = extraIgnored.concat(_shellNames);
        }
        _daemonAttempts++;
        daemonRetryTimer.restart();
        if (extraIgnored.length > 0) {
            DMSService.sysupdateUpgrade({
                includeFlatpak: false,
                ignored: (SettingsData.updaterIgnoredPackages || []).concat(extraIgnored)
            }, null);
        } else {
            SystemUpdateService.runUpdates({
                includeFlatpak: false
            });
        }
    }

    Timer {
        id: daemonRetryTimer
        // Generous on purpose: a re-send while the daemon's dnf child is
        // still refreshing metadata or resolving (easily 5-15s) kills that
        // child mid-run. Only nudge when the daemon has been silent long
        // past any normal resolve time.
        interval: 20000

        onTriggered: {
            if (!engine.running || engine._dnfSawUpgrading || SystemUpdateService.isUpgrading)
                return;
            // The daemon runs its own refresh after an upgrade pass and
            // refuses commands meanwhile — wait it out without burning
            // attempts
            if (SystemUpdateService.isChecking) {
                daemonRetryTimer.restart();
                return;
            }
            if (engine._daemonAttempts < 6) {
                engine._sendDaemonUpgrade();
                return;
            }
            // Daemon never picked the pass up: fail it visibly, with the why
            const reason = SystemUpdateService.errorMessage || Tr.t("the update service did not start this pass — try again");
            const map = engine._daemonKind === "shell" ? engine._shellNameToKey : engine._dnfNameToKey;
            for (const base in map)
                engine._setItem(map[base], {
                    status: "error",
                    detail: reason
                });
            if (engine._daemonKind === "shell") {
                engine._shellDone = true;
                engine.failedCount += engine._shellCount;
                engine._finish("failed");
            } else {
                engine._dnfDone = true;
                engine.failedCount += engine._dnfCount;
                if (engine._wantFlatpak)
                    engine._startFlatpak();
                else if (engine._wantAppimage)
                    engine._startAppimage();
                else if (engine._wantFirmware)
                    engine._startFirmware();
                else
                    engine._finish("failed");
            }
        }
    }

    function _afterFlatpak() {
        if (_wantAppimage) {
            _startAppimage();
        } else if (_wantFirmware) {
            _startFirmware();
        } else if (_wantShell && !_shellDone) {
            _startDaemon("shell");
        } else {
            _finish(failedCount > 0 ? "failed" : "done");
        }
    }

    function _startFirmware() {
        phase = "firmware";
        if (_firmwareFiltered) {
            // A subset is delayed: update the remaining devices one by one
            const ids = _firmwareItems.map(fw => fw.deviceId).filter(Boolean);
            firmwareProcess.command = ["sh", "-c", ids.map(id => "fwupdmgr update -y --no-reboot-check '" + id.replace(/'/g, "") + "'").join("; ")];
        } else {
            firmwareProcess.command = ["fwupdmgr", "update", "-y", "--no-reboot-check"];
        }
        firmwareProcess.running = true;
    }

    function cancel() {
        _deferredOpts = null;
        daemonRetryTimer.stop();
        if (!running)
            return;
        if (!_dnfDone || (_daemonKind === "shell" && !_shellDone)) {
            SystemUpdateService.cancelUpdates();
        }
        if (flatpakProcess.running && flatpakProcess.processId > 0) {
            Quickshell.execDetached(["kill", "-TERM", String(flatpakProcess.processId)]);
        }
        if (firmwareProcess.running && firmwareProcess.processId > 0) {
            Quickshell.execDetached(["kill", "-TERM", String(firmwareProcess.processId)]);
        }
        if (appimageProcess.running && appimageProcess.processId > 0) {
            Quickshell.execDetached(["kill", "-TERM", String(appimageProcess.processId)]);
        }
        _finish("cancelled");
    }

    function _startFlatpak() {
        phase = "flatpak";
        const cmd = ["python3", Qt.resolvedUrl("scripts/flatpak_helper.py").toString().replace("file://", ""), "update"];
        for (const id of _flatpakIds)
            cmd.push(id);
        flatpakProcess.command = cmd;
        flatpakProcess.running = true;
    }

    function _finish(finalPhase) {
        running = false;
        etaTimer.stop();
        cachePollProcess.running = false;
        phase = finalPhase;
        etaSeconds = -1;
        currentItem = "";
        currentDetail = "";
        if (finalPhase === "done" && failedCount === 0)
            overallFraction = 1;
        SystemUpdateService.checkForUpdates();
        finished(finalPhase === "done" && failedCount === 0);
    }

    // ── Weighted progress model ──────────────────────────────────────────────
    readonly property real _firmwareWeightTotal: _wantFirmware ? _firmwareItems.length * firmwareItemWeight : 0
    readonly property real _dnfWeightTotal: _wantDnf ? _dnfCount * dnfPkgWeight : 0
    readonly property real _shellWeightTotal: _wantShell ? _shellCount * dnfPkgWeight : 0
    readonly property real _appimageWeightTotal: {
        if (!_wantAppimage)
            return 0;
        let total = 0;
        for (const id in _aiOps)
            total += _aiOps[id].weight;
        return total;
    }

    function _appimageWeightDone() {
        let done = 0;
        for (const id in _aiOps) {
            const op = _aiOps[id];
            done += op.weight * (op.done ? 1 : op.fraction);
        }
        return done;
    }
    readonly property real _flatpakWeightTotal: {
        if (!_wantFlatpak)
            return 0;
        if (_flatpakPlanKnown)
            return Math.max(_flatpakPlannedBytes, _flatpakOpCount * 1024 * 1024);
        const guess = _flatpakIds.length > 0 ? _flatpakIds.length : (pendingUpdates || []).filter(p => p.repo === "flatpak").length;
        return Math.max(1, guess) * flatpakFallbackOpWeight;
    }

    function _stageFractionNow() {
        if (_dnfStage === 0 || _dnfStageY === 0)
            return 0;
        const stageFraction = Math.min(1, _dnfStageX / _dnfStageY);
        if (_dnfStage === 1)
            return dnfDownloadShare * stageFraction;
        return dnfDownloadShare + (1 - dnfDownloadShare) * stageFraction;
    }

    function _dnfFractionNow() {
        if (!_wantDnf)
            return 0;
        if (_dnfDone)
            return 1;
        return _daemonKind === "dnf" ? _stageFractionNow() : 0;
    }

    function _shellFractionNow() {
        if (!_wantShell)
            return 0;
        if (_shellDone)
            return 1;
        return _daemonKind === "shell" ? _stageFractionNow() : 0;
    }

    function _flatpakWeightDone() {
        let done = 0;
        for (const ref in _flatpakOps) {
            const op = _flatpakOps[ref];
            done += op.weight * (op.done ? 1 : op.fraction);
        }
        return done;
    }

    function _updateOverall() {
        const total = _dnfWeightTotal + _flatpakWeightTotal + _firmwareWeightTotal + _shellWeightTotal + _appimageWeightTotal;
        if (total <= 0)
            return;
        const fbDone = _flatpakWeightDone();
        flatpakBytesDone = fbDone;
        let doneOps = 0, totalOps = 0;
        for (const ref in _flatpakOps) {
            totalOps++;
            if (_flatpakOps[ref].done)
                doneOps++;
        }
        opsDone = doneOps;
        opsTotal = totalOps;
        const done = _dnfFractionNow() * _dnfWeightTotal + fbDone + _firmwareFraction * _firmwareWeightTotal + _shellFractionNow() * _shellWeightTotal + _appimageWeightDone();
        overallFraction = Math.min(running ? 0.995 : 1, done / total);
    }

    property real _lastFlatpakBytes: 0

    Timer {
        id: etaTimer
        interval: 1000
        repeat: true
        onTriggered: {
            engine._elapsedSeconds++;
            const fbDelta = Math.max(0, engine.flatpakBytesDone - engine._lastFlatpakBytes);
            engine._lastFlatpakBytes = engine.flatpakBytesDone;
            engine.flatpakSpeed = engine.flatpakSpeed <= 0 ? fbDelta : (0.8 * engine.flatpakSpeed + 0.2 * fbDelta);
            const total = engine._dnfWeightTotal + engine._flatpakWeightTotal + engine._firmwareWeightTotal + engine._shellWeightTotal + engine._appimageWeightTotal;
            const done = engine._dnfFractionNow() * engine._dnfWeightTotal + engine._flatpakWeightDone() + engine._firmwareFraction * engine._firmwareWeightTotal + engine._shellFractionNow() * engine._shellWeightTotal + engine._appimageWeightDone();
            const delta = Math.max(0, done - engine._lastWeightDone);
            engine._lastWeightDone = done;
            engine._rate = engine._rate <= 0 ? delta : (0.85 * engine._rate + 0.15 * delta);
            if (engine._elapsedSeconds >= 5 && engine._rate > total * 0.00005) {
                engine.etaSeconds = Math.round((total - done) / engine._rate);
            } else if (engine._elapsedSeconds > 30 && engine._rate <= 0) {
                engine.etaSeconds = -1;
            }
            engine._updateOverall();
        }
    }

    // ── DNF via the DMS daemon ───────────────────────────────────────────────
    Connections {
        target: SystemUpdateService
        enabled: engine.running && (!engine._dnfDone || !engine._shellDone)

        function onIsUpgradingChanged() {
            if (SystemUpdateService.isUpgrading) {
                engine._dnfSawUpgrading = true;
                daemonRetryTimer.stop();
                if (engine.phase === "starting")
                    engine.phase = "dnf-download";
                return;
            }
            if (!engine._dnfSawUpgrading)
                return;
            // Daemon finished this upgrade pass. On a reported error, fail
            // everything with the reason; on reported success don't take
            // its word for it — a killed or no-op dnf child also exits
            // cleanly. Verify against the rpm database which packages
            // actually reached their target version.
            if (SystemUpdateService.hasError) {
                const map = engine._daemonKind === "shell" ? engine._shellNameToKey : engine._dnfNameToKey;
                for (const base in map)
                    engine._setItem(map[base], {
                        status: "error",
                        detail: SystemUpdateService.errorMessage || Tr.t("failed")
                    });
                engine._daemonPassDone(0, engine._daemonKind === "shell" ? engine._shellCount : engine._dnfCount);
            } else {
                engine._verifyDaemonPass();
            }
        }

        function onRecentLogChanged() {
            // Streaming log lines prove the daemon is working on this pass
            // even while isUpgrading is still false (metadata refresh and
            // dependency resolution). Re-sending the upgrade command then
            // makes the daemon kill its dnf child mid-resolve — push the
            // retry out as long as output keeps flowing.
            if (daemonRetryTimer.running)
                daemonRetryTimer.restart();
            engine._parseDnfLog();
        }
    }

    // ── Post-pass verification ──────────────────────────────────────────────
    Process {
        id: verifyProcess

        stdout: StdioCollector {
            onStreamFinished: engine._applyDaemonVerify(text)
        }
    }

    function _verifyDaemonPass() {
        const map = _daemonKind === "shell" ? _shellNameToKey : _dnfNameToKey;
        const names = Object.keys(map);
        if (names.length === 0) {
            _daemonPassDone(0, 0);
            return;
        }
        verifyProcess.command = ["rpm", "-q", "--qf", "%{NAME}\\t%{EVR}\\n"].concat(names);
        verifyProcess.running = true;
    }

    function _applyDaemonVerify(text) {
        if (!running)
            return;
        const installed = {};
        for (const line of (text || "").split("\n")) {
            const parts = line.split("\t");
            if (parts.length === 2)
                (installed[parts[0].trim()] = installed[parts[0].trim()] || []).push(parts[1].trim());
        }
        const noEpoch = v => (v || "").replace(/^\d+:/, "");
        const map = _daemonKind === "shell" ? _shellNameToKey : _dnfNameToKey;
        let okCount = 0;
        let failCount = 0;
        for (const base in map) {
            const want = noEpoch(_daemonExpectedEvr[base] || "");
            // Unknown target version: nothing to compare against, keep the
            // daemon's success verdict for this row
            const arrived = want === "" || (installed[base] || []).some(evr => noEpoch(evr) === want);
            if (arrived) {
                okCount++;
                _setItem(map[base], {
                    status: "done",
                    fraction: 1,
                    detail: ""
                });
            } else {
                failCount++;
                _setItem(map[base], {
                    status: "error",
                    detail: Tr.t("the package was not updated — try again")
                });
            }
        }
        _daemonPassDone(okCount, failCount);
    }

    function _daemonPassDone(okCount, failCount) {
        completedCount += okCount;
        failedCount += failCount;
        if (_daemonKind === "shell") {
            _shellDone = true;
            _finish(failedCount > 0 ? "failed" : "done");
            return;
        }
        _dnfDone = true;
        if (_wantFlatpak) {
            _startFlatpak();
        } else if (_wantAppimage) {
            _startAppimage();
        } else if (_wantFirmware) {
            _startFirmware();
        } else if (_wantShell && !_shellDone) {
            _startDaemon("shell");
        } else {
            _finish(failedCount > 0 ? "failed" : "done");
        }
    }

    // ── Live download bytes from the dnf cache ──────────────────────────────
    // dnf5's piped output only prints a line when a package finishes
    // downloading, so the log cannot show progress inside a package. The
    // daemon downloads into the world-readable dnf cache though: during the
    // download stage the growing .rpm files there give real per-package
    // bytes. Only fresh files count (-mmin -1) so leftovers from earlier
    // runs don't masquerade as progress.
    Process {
        id: cachePollProcess

        command: ["sh", "-c", "while true; do find /var/cache/libdnf5 -name '*.rpm' -mmin -1 -printf '%f\\t%s\\t%T@\\n' 2>/dev/null; echo ---; sleep 1; done"]

        stdout: SplitParser {
            onRead: line => engine._onCachePollLine(line)
        }
    }

    property var _cacheBatch: []

    function _onCachePollLine(line) {
        if (line.trim() === "---") {
            const batch = _cacheBatch;
            _cacheBatch = [];
            _applyCacheBatch(batch);
            return;
        }
        const parts = line.split("\t");
        if (parts.length === 3)
            _cacheBatch.push({
                file: parts[0],
                bytes: parseInt(parts[1], 10) || 0,
                mtime: parseFloat(parts[2]) || 0
            });
    }

    function _applyCacheBatch(batch) {
        if (!running || _dnfStage !== 1)
            return;
        const map = _daemonKind === "shell" ? _shellNameToKey : _dnfNameToKey;
        // Newest matching file per package: the cache can hold several
        // versions of the same rpm, only the growing one is the download.
        const newest = {};
        for (const entry of batch) {
            let base = "";
            for (const b in map) {
                if (b.length > base.length && entry.file.indexOf(b + "-") === 0)
                    base = b;
            }
            if (base && (!newest[base] || entry.mtime > newest[base].mtime))
                newest[base] = entry;
        }
        for (const base in newest) {
            const key = map[base];
            const size = (packageSizes || {})[base] || 0;
            if (!key || size <= 0)
                continue;
            const state = itemStates[key];
            if (state && state.status !== "pending" && state.status !== "active")
                continue;
            const pct = Math.min(1, newest[base].bytes / size);
            const fraction = 0.7 * pct;
            if (state && state.fraction >= fraction)
                continue;
            let detail = Tr.t("downloading") + " · " + Math.round(pct * 100) + "%";
            if (size > 1024 * 1024)
                detail += " · " + formatBytes(Math.min(newest[base].bytes, size)) + " / " + formatBytes(size);
            _setItem(key, {
                status: "active",
                fraction: fraction,
                detail: detail
            });
        }
    }

    // Rows whose download completed would keep saying "downloading · 100%"
    // through the silent transaction-test minutes; relabel them once the
    // install stage starts.
    function _markDownloadedRows() {
        for (const key in itemStates) {
            const st = itemStates[key];
            if (st && st.status === "active" && (st.detail || "").indexOf(Tr.t("downloading")) === 0)
                _setItem(key, {
                    detail: Tr.t("downloaded")
                });
        }
    }

    function _parseDnfLog() {
        const log = SystemUpdateService.recentLog || [];
        // The daemon keeps a rolling window; only look at fresh lines.
        const bracketRe = /\[\s*(\d+)\s*\/\s*(\d+)\s*\]\s*(.*)/;
        for (const line of log.slice(-30)) {
            const match = bracketRe.exec(line);
            if (!match)
                continue;
            const x = parseInt(match[1], 10);
            const y = parseInt(match[2], 10);
            const rest = (match[3] || "").trim();
            if (y <= 0)
                continue;
            if (_dnfStage === 0) {
                _dnfStage = 1;
                _dnfStageY = y;
                if (_daemonKind !== "shell")
                    phase = "dnf-download";
                _cacheBatch = [];
                cachePollProcess.running = true;
            } else if (y !== _dnfStageY && _dnfStage === 1 && _dnfStageX >= Math.max(1, _dnfStageY - 1)) {
                // Step total changed after the download series completed → transaction stage
                _dnfStage = 2;
                _dnfStageY = y;
                if (_daemonKind !== "shell")
                    phase = "dnf-install";
                cachePollProcess.running = false;
                _markDownloadedRows();
            } else if (y !== _dnfStageY) {
                _dnfStageY = y;
            }
            if (x >= _dnfStageX || y !== _dnfStageY) {
                _dnfStageX = Math.min(x, y);
            }
            // Try to map the step line to a package for per-item status
            const map = _daemonKind === "shell" ? _shellNameToKey : _dnfNameToKey;
            const base = _dnfMatchPackage(rest, map);
            if (base) {
                const key = map[base];
                if (currentItem !== base) {
                    currentItem = base;
                }
                currentDetail = _dnfStage === 1 ? Tr.t("downloading") : Tr.t("installing");
                if (key) {
                    // dnf5 step lines carry this item's own percent; map the
                    // row bar to the package's full journey: download fills
                    // 0–70%, the transaction step 70–100%. Lines without a
                    // percent (scriptlets, verify) keep a mid-stage estimate.
                    const pctMatch = /(\d{1,3})\s*%/.exec(rest);
                    const pct = pctMatch ? Math.min(100, parseInt(pctMatch[1], 10)) / 100 : -1;
                    let fraction = _dnfStage === 1 ? (pct >= 0 ? 0.7 * pct : 0.3) : (pct >= 0 ? 0.7 + 0.3 * pct : 0.8);
                    // recentLog is a rolling window that gets rescanned, so
                    // older lines reappear — never move a bar backwards.
                    const prev = itemStates[key];
                    if (prev && prev.fraction > fraction)
                        fraction = prev.fraction;
                    let detail = currentDetail;
                    const size = (packageSizes || {})[base] || 0;
                    if (_dnfStage === 1 && pct >= 1) {
                        // A stage-1 log line only prints when that package's
                        // download completed — say so instead of leaving a
                        // "downloading · 100%" that sits through the wait.
                        detail = Tr.t("downloaded") + (size > 1024 * 1024 ? " · " + formatBytes(size) : "");
                    } else if (pct >= 0) {
                        detail += " · " + Math.round(pct * 100) + "%";
                        // Byte detail like the flatpak rows: repoquery gave the
                        // exact download size, the percent gives the progress.
                        if (_dnfStage === 1 && size > 1024 * 1024)
                            detail += " · " + formatBytes(size * pct) + " / " + formatBytes(size);
                    }
                    _setItem(key, {
                        status: "active",
                        fraction: fraction,
                        detail: detail
                    });
                }
            }
        }
        _updateOverall();
    }

    function _dnfMatchPackage(text, map) {
        // Prefer the longest matching name: with subpackage families in the
        // run ("abrt" next to "abrt-addon-ccpp") the short base also occurs
        // in the long package's lines, which would drive the wrong row.
        let best = "";
        for (const base in map) {
            if (base.length > best.length && text.indexOf(base) !== -1)
                best = base;
        }
        return best;
    }

    // ── Flatpak via libflatpak helper ────────────────────────────────────────
    Process {
        id: flatpakProcess

        stdout: SplitParser {
            onRead: line => engine._onFlatpakEvent(line)
        }

        onExited: (exitCode, exitStatus) => {
            if (!engine.running)
                return;
            if (exitCode !== 0 && exitCode !== 130) {
                engine.failedCount++;
            }
            engine._afterFlatpak();
        }
    }

    // ── AppImages via scripts/appimage.py ────────────────────────────────────
    Process {
        id: appimageProcess

        stdout: SplitParser {
            onRead: line => engine._onAppimageEvent(line)
        }

        onExited: (exitCode, exitStatus) => {
            if (!engine.running)
                return;
            // Mark anything the helper never reported on as failed
            for (const ai of engine._appimageItems) {
                const state = engine.itemStates["appimage/" + ai.id];
                if (state && state.status !== "done" && state.status !== "error") {
                    engine._setItem("appimage/" + ai.id, {
                        status: "error",
                        detail: Tr.t("failed")
                    });
                    engine.failedCount++;
                }
            }
            engine._afterAppimage();
        }
    }

    function _onAppimageEvent(line) {
        let event;
        try {
            event = JSON.parse(line);
        } catch (e) {
            return;
        }
        switch (event.event) {
        case "ai-start": {
            _aiCurrentId = event.id;
            currentItem = event.name || event.id;
            _setItem("appimage/" + event.id, {
                status: "active",
                detail: Tr.t("downloading")
            });
            break;
        }
        case "progress": {
            if (_aiCurrentId === "" || phase !== "appimage")
                return;
            const ops = _aiOps;
            if (ops[_aiCurrentId])
                ops[_aiCurrentId].fraction = Math.min(1, (event.percent || 0) / 100);
            currentDetail = (event.percent || 0) + "%";
            _setItem("appimage/" + _aiCurrentId, {
                status: "active",
                fraction: Math.min(1, (event.percent || 0) / 100),
                detail: (event.percent || 0) + "%" + (event.total > 0 ? " · " + formatBytes(event.bytes || 0) + " / " + formatBytes(event.total) : "")
            });
            _updateOverall();
            break;
        }
        case "ai-done": {
            const ops = _aiOps;
            if (ops[event.id]) {
                ops[event.id].done = true;
                ops[event.id].fraction = 1;
            }
            if (event.ok === true) {
                completedCount++;
                _setItem("appimage/" + event.id, {
                    status: "done",
                    fraction: 1,
                    detail: ""
                });
            } else {
                failedCount++;
                _setItem("appimage/" + event.id, {
                    status: "error",
                    detail: event.message || Tr.t("failed")
                });
            }
            _updateOverall();
            break;
        }
        }
    }

    // ── Firmware via fwupdmgr ────────────────────────────────────────────────
    Process {
        id: firmwareProcess

        stdout: SplitParser {
            onRead: line => engine._onFirmwareLine(line)
        }

        onExited: (exitCode, exitStatus) => {
            if (!engine.running)
                return;
            const ok = exitCode === 0 || exitCode === 2;
            for (const fw of engine._firmwareItems) {
                engine._setItem("firmware/" + fw.name, ok ? {
                    status: "done",
                    fraction: 1,
                    detail: ""
                } : {
                    status: "error",
                    detail: Tr.t("fwupdmgr exit %1").arg(exitCode)
                });
            }
            if (ok) {
                engine.completedCount += engine._firmwareItems.length;
                engine._firmwareFraction = 1;
            } else {
                engine.failedCount += engine._firmwareItems.length;
            }
            if (engine._wantShell && !engine._shellDone) {
                engine._startDaemon("shell");
            } else {
                engine._finish(engine.failedCount > 0 ? "failed" : "done");
            }
        }
    }

    function _onFirmwareLine(line) {
        // Match the current device by name and track coarse percent progress
        for (const fw of _firmwareItems) {
            if (fw.name && line.indexOf(fw.name) !== -1) {
                currentItem = fw.name;
                _setItem("firmware/" + fw.name, {
                    status: "active",
                    detail: Tr.t("updating")
                });
            }
        }
        const percentMatch = /(\d{1,3})\s*%/.exec(line);
        if (percentMatch) {
            const pct = Math.min(100, parseInt(percentMatch[1], 10)) / 100;
            const total = Math.max(1, _firmwareItems.length);
            if (pct < _firmwareFraction * total - _firmwareDone && _firmwareDone < total - 1) {
                _firmwareDone++;
            }
            _firmwareFraction = Math.min(1, (_firmwareDone + pct) / total);
            if (currentItem) {
                _setItem("firmware/" + currentItem, {
                    status: "active",
                    fraction: pct,
                    detail: percentMatch[1] + "%"
                });
            }
            _updateOverall();
        }
    }

    function _flatpakKeyFor(appid) {
        if (itemStates["flatpak/" + appid] !== undefined)
            return "flatpak/" + appid;
        // Extensions (org.x.App.Locale) roll up into their base app row if
        // the extension itself is not listed separately.
        const parts = appid.split(".");
        while (parts.length > 2) {
            parts.pop();
            const candidate = "flatpak/" + parts.join(".");
            if (itemStates[candidate] !== undefined)
                return candidate;
        }
        return "";
    }

    function _onFlatpakEvent(line) {
        let event;
        try {
            event = JSON.parse(line);
        } catch (e) {
            return;
        }
        switch (event.event) {
        case "plan": {
            const ops = Object.assign({}, _flatpakOps);
            for (const op of event.ops || []) {
                ops[op.ref] = {
                    appid: op.appid,
                    weight: Math.max(op.downloadBytes || 0, 1024 * 1024),
                    fraction: 0,
                    done: false
                };
            }
            _flatpakOps = ops;
            _flatpakOpCount = Object.keys(ops).length;
            let total = 0;
            for (const ref in ops)
                total += ops[ref].weight;
            _flatpakPlannedBytes = total;
            _flatpakPlanKnown = true;
            break;
        }
        case "op-start": {
            currentItem = event.appid;
            const key = _flatpakKeyFor(event.appid);
            if (key)
                _setItem(key, {
                    status: "active",
                    detail: Tr.t("starting")
                });
            break;
        }
        case "progress": {
            const ops = _flatpakOps;
            if (ops[event.ref]) {
                ops[event.ref].fraction = Math.min(1, (event.percent || 0) / 100);
            }
            const isInstallPhase = (event.status || "").toLowerCase().indexOf("install") !== -1 || (event.status || "").toLowerCase().indexOf("deploy") !== -1;
            _flatpakMostlyDownloading = !isInstallPhase;
            currentItem = event.appid;
            currentDetail = (event.percent || 0) + "%";
            const key = _flatpakKeyFor(event.appid);
            if (key) {
                _setItem(key, {
                    status: "active",
                    fraction: Math.min(1, (event.percent || 0) / 100),
                    detail: (event.percent || 0) + "%" + (ops[event.ref] && ops[event.ref].weight > 2 * 1024 * 1024 ? " · " + formatBytes(event.bytesTransferred || 0) + " / " + formatBytes(ops[event.ref].weight) : "")
                });
            }
            _updateOverall();
            break;
        }
        case "op-done": {
            const ops = _flatpakOps;
            if (ops[event.ref]) {
                ops[event.ref].done = true;
                ops[event.ref].fraction = 1;
            }
            const key = _flatpakKeyFor(event.appid);
            if (key) {
                // Only mark the row done when all ops mapping to it are done
                let allDone = true;
                for (const ref in ops) {
                    if (_flatpakKeyFor(ops[ref].appid) === key && !ops[ref].done)
                        allDone = false;
                }
                if (allDone) {
                    _setItem(key, {
                        status: "done",
                        fraction: 1,
                        detail: ""
                    });
                    completedCount++;
                }
            }
            _updateOverall();
            break;
        }
        case "op-error": {
            failedCount++;
            const key = _flatpakKeyFor(event.appid);
            if (key)
                _setItem(key, {
                    status: "error",
                    detail: event.message || Tr.t("failed")
                });
            break;
        }
        case "done": {
            // Final exit handling happens in onExited
            break;
        }
        }
    }
}
