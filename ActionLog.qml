import QtQuick
import Quickshell.Io
import qs.Common

// Persistent action history: update runs, installs, uninstalls, downgrades.
// Entries live in ~/.local/share/dankSoftwareDepot/action-log.json; the python
// helper appends, prunes anything older than the retention window (two
// years, long enough for the Log tab to look back over one) and echoes the
// log back.
Item {
    id: log

    // Newest last:
    //   [{ts, type, title, label, items: [{name, from, to, source, status}]}]
    property var entries: []

    readonly property string scriptPath: Qt.resolvedUrl("scripts/action_log.py").toString().replace("file://", "")

    property var _queue: []

    // ts is optional: replayed entries (a run whose logging was swallowed
    // by a shell reload) carry their original timestamp.
    //
    // `label` is what makes the log follow the interface language. A title
    // translated on the way in is a translation frozen at the moment it was
    // written: switch language and every line already on disk stays in the
    // language it happened in, which is how this log ended up half Dutch.
    // Recording {key, args} instead means the sentence is assembled when it
    // is read. The translated `title` is still written beside it, as what an
    // older version of this plugin — and the entries already on disk — can
    // still show.
    function record(type, title, items, ts, label) {
        const entry = {
            type: type,
            title: title,
            items: items || []
        };
        if (label && label.key)
            entry.label = label;
        if (ts)
            entry.ts = ts;
        _run(entry);
    }

    // Holding a package is a decision, and until now the only decision this
    // app could make that left no trace: the list simply stopped counting it
    // one day, and a month later there was nothing to say why. It records the
    // release of a hold too — that is the half you want when an update you
    // were waiting for turns out to have been sitting behind your own lock.
    function recordHold(name, displayName, held) {
        const shown = displayName || name;
        const label = {
            key: held ? "Held %1" : "Released the hold on %1",
            args: [shown]
        };
        record(held ? "hold" : "unhold", titleOf({
            label: label
        }), [
            {
                name: shown,
                id: name,
                from: "",
                to: "",
                source: "",
                status: "done"
            }
        ], 0, label);
    }

    // The one place that turns an entry into a sentence, so the list, the
    // search and anything else cannot disagree about what a line says.
    function titleOf(entry) {
        if (!entry)
            return "";
        const label = entry.label;
        if (!label || !label.key)
            return entry.title || "";
        let text = Tr.t(label.key);
        for (const arg of (label.args || []))
            text = text.arg(arg);
        // A size or a package name that was never translated to begin with
        return (label.suffix || "") !== "" ? text + " · " + label.suffix : text;
    }

    function reload() {
        _run(null);
    }

    function _run(entry) {
        if (proc.running) {
            _queue.push(entry);
            return;
        }
        proc.command = entry ? [Backend.python, scriptPath, JSON.stringify(entry)] : [Backend.python, scriptPath];
        proc.running = true;
    }

    Process {
        id: proc

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    log.entries = JSON.parse(text);
                } catch (e) {
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (log._queue.length > 0) {
                const next = log._queue.shift();
                log._run(next);
            }
        }
    }

    Component.onCompleted: reload()
}
