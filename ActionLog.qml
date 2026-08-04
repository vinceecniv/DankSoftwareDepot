import QtQuick
import Quickshell.Io

// Persistent action history: update runs, installs, uninstalls, downgrades.
// Entries live in ~/.local/share/dankSoftwareDepot/action-log.json; the python
// helper appends, prunes anything older than 90 days and echoes the log back.
Item {
    id: log

    // Newest last: [{ts, type, title, items: [{name, from, to, source, status}]}]
    property var entries: []

    readonly property string scriptPath: Qt.resolvedUrl("scripts/action_log.py").toString().replace("file://", "")

    property var _queue: []

    function record(type, title, items) {
        _run({
            type: type,
            title: title,
            items: items || []
        });
    }

    function reload() {
        _run(null);
    }

    function _run(entry) {
        if (proc.running) {
            _queue.push(entry);
            return;
        }
        proc.command = entry ? ["python3", scriptPath, JSON.stringify(entry)] : ["python3", scriptPath];
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
