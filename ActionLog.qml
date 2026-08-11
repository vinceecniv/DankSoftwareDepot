import QtQuick
import Quickshell.Io

// Persistent action history: update runs, installs, uninstalls, downgrades.
// Entries live in ~/.local/share/dankSoftwareDepot/action-log.json; the python
// helper appends, prunes anything older than the retention window (two
// years, long enough for the Log tab to look back over one) and echoes the
// log back.
Item {
    id: log

    // Newest last: [{ts, type, title, items: [{name, from, to, source, status}]}]
    property var entries: []

    readonly property string scriptPath: Qt.resolvedUrl("scripts/action_log.py").toString().replace("file://", "")

    property var _queue: []

    // ts is optional: replayed entries (a run whose logging was swallowed
    // by a shell reload) carry their original timestamp.
    function record(type, title, items, ts) {
        const entry = {
            type: type,
            title: title,
            items: items || []
        };
        if (ts)
            entry.ts = ts;
        _run(entry);
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
