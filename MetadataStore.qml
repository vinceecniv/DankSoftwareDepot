import QtQuick
import Quickshell.Io

// Enriches the raw update list from SystemUpdateService with AppStream data:
// pretty names, summaries, homepages, icons and release notes. All heavy
// lifting (catalog parsing, caching, sanitizing) happens in scripts/enrich.py.
Item {
    id: store

    // "flatpak/<appid>" or "system/<basename>" -> info object
    property var meta: ({})
    // Persisted held map (key -> reason), set by the widget from plugin
    // settings. Bridges the gap between a fresh package list and the async
    // enrichment result, so held packages never flash into view.
    property var persistedHeldMap: ({})

    signal enriched
    // "<basename>" -> plain-text rpm changelog (lazy-loaded)
    property var changelogs: ({})
    property bool loading: false

    readonly property string scriptDir: Qt.resolvedUrl("scripts/").toString().replace("file://", "")

    property var _pendingRequest: null

    function stripArch(name) {
        return (name || "").replace(/\.(x86_64|i686|noarch|aarch64|armv7hl|ppc64le|s390x)$/, "");
    }

    function keyFor(pkg) {
        if (!pkg)
            return "";
        return pkg.repo === "flatpak" ? ("flatpak/" + pkg.name) : ("system/" + stripArch(pkg.name));
    }

    function infoFor(pkg) {
        const info = meta[keyFor(pkg)] || null;
        if (info && info.name)
            return info;
        // Derive a friendly name for flatpak extensions from their base app
        if (pkg && pkg.repo === "flatpak") {
            const extMatch = /^(.*)\.(Locale|Debug|Sources)$/.exec(pkg.name || "");
            if (extMatch) {
                const base = meta["flatpak/" + extMatch[1]];
                if (base && base.name) {
                    const suffix = extMatch[2] === "Locale" ? "translations" : extMatch[2].toLowerCase();
                    return {
                        name: base.name + " (" + suffix + ")",
                        summary: base.summary || "",
                        developer: base.developer || "",
                        homepage: base.homepage || "",
                        icon: base.icon || "",
                        releases: []
                    };
                }
            }
        }
        return info;
    }

    function isHeld(pkg) {
        const key = keyFor(pkg);
        const info = meta[key];
        if (info)
            return !!info.held;
        return persistedHeldMap[key] !== undefined;
    }

    function holdReason(pkg) {
        const key = keyFor(pkg);
        const info = meta[key];
        if (info && info.holdReason)
            return info.holdReason;
        return persistedHeldMap[key] || "";
    }

    function currentHeldMap() {
        const map = {};
        for (const key in meta) {
            if (meta[key] && meta[key].held)
                map[key] = meta[key].holdReason || "held";
        }
        return map;
    }

    function displayName(pkg) {
        if (pkg && pkg.displayName)
            return pkg.displayName;
        const info = infoFor(pkg);
        if (info && info.name)
            return info.name;
        return pkg.repo === "flatpak" ? pkg.name : stripArch(pkg.name);
    }

    // Friendly name for an engine currentItem value (appid or rpm base name)
    function prettyId(id) {
        if (!id)
            return "";
        const flat = meta["flatpak/" + id];
        if (flat && flat.name)
            return flat.name;
        const extMatch = /^(.*)\.(Locale|Debug|Sources)$/.exec(id);
        if (extMatch) {
            const base = meta["flatpak/" + extMatch[1]];
            if (base && base.name)
                return base.name + " (" + (extMatch[2] === "Locale" ? "translations" : extMatch[2].toLowerCase()) + ")";
        }
        const sys = meta["system/" + id];
        if (sys && sys.name)
            return sys.name;
        return id;
    }

    function refresh(updates) {
        if (!updates || updates.length === 0)
            return;
        const rpm = [];
        const flatpak = [];
        const seen = new Set();
        for (const pkg of updates) {
            const key = keyFor(pkg);
            if (seen.has(key))
                continue;
            seen.add(key);
            const entry = {
                name: pkg.repo === "flatpak" ? pkg.name : stripArch(pkg.name),
                from: pkg.fromVersion || "",
                to: pkg.toVersion || ""
            };
            (pkg.repo === "flatpak" ? flatpak : rpm).push(entry);
        }
        const request = JSON.stringify({
            rpm: rpm,
            flatpak: flatpak
        });
        if (enrichProcess.running) {
            _pendingRequest = request;
            return;
        }
        _runEnrich(request);
    }

    function _runEnrich(request) {
        loading = true;
        enrichProcess.command = ["python3", scriptDir + "enrich.py", request];
        enrichProcess.running = true;
    }

    function fetchChangelog(pkgName) {
        const base = stripArch(pkgName);
        if (changelogs[base] !== undefined || changelogProcess.running)
            return;
        changelogProcess._target = base;
        changelogProcess.command = ["python3", scriptDir + "enrich.py", "--changelog", base];
        changelogProcess.running = true;
    }

    Process {
        id: enrichProcess

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const data = JSON.parse(text);
                    const merged = {};
                    for (const name in (data.rpm || {}))
                        merged["system/" + name] = data.rpm[name];
                    for (const name in (data.flatpak || {}))
                        merged["flatpak/" + name] = data.flatpak[name];
                    store.meta = merged;
                    store.enriched();
                } catch (e) {
                    console.warn("dankSoftwareDepot: enrich parse failed:", e);
                }
                store.loading = false;
                if (store._pendingRequest) {
                    const next = store._pendingRequest;
                    store._pendingRequest = null;
                    store._runEnrich(next);
                }
            }
        }
    }

    Process {
        id: changelogProcess

        property string _target: ""

        stdout: StdioCollector {
            onStreamFinished: {
                const updated = Object.assign({}, store.changelogs);
                updated[changelogProcess._target] = text.trim() || "";
                store.changelogs = updated;
            }
        }
    }
}
