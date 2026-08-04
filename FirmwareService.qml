import QtQuick
import Quickshell.Io

// Firmware updates via fwupd (LVFS). Detection through `fwupdmgr
// get-updates --json`; applying runs through the engine (polkit-authed).
Item {
    id: svc

    property bool available: true
    property bool checking: false
    // {deviceId, name, current, next, summary, notesHtml, homepage, urgency}
    property var updates: []

    readonly property int count: updates.length

    // fwupd release descriptions are appstream-ish XML from LVFS metadata.
    // Reduce to escaped plain text with line breaks — same safety rules as
    // the AppStream release notes.
    function _sanitize(text) {
        if (!text)
            return "";
        let t = text
            .replace(/<li>/gi, "\n• ")
            .replace(/<\/(p|li|ul|ol)>/gi, "\n")
            .replace(/<[^>]*>/g, "");
        t = t.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">");
        t = t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
        return t.split("\n").map(line => line.trim()).filter(line => line.length > 0).join("<br>");
    }

    function check() {
        if (!available || checkProcess.running)
            return;
        checking = true;
        checkProcess.running = true;
    }

    function _parse(text) {
        try {
            const data = JSON.parse(text);
            const found = [];
            for (const device of data.Devices || []) {
                const releases = device.Releases || [];
                if (releases.length === 0)
                    continue;
                const release = releases[0];
                let homepage = "";
                for (const url of release.Urls || []) {
                    homepage = url;
                    break;
                }
                found.push({
                    deviceId: device.DeviceId || "",
                    name: device.Name || "Unknown device",
                    current: device.Version || "",
                    next: release.Version || "",
                    summary: release.Summary || "",
                    notesHtml: _sanitize(release.Description || ""),
                    homepage: homepage,
                    urgency: release.Urgency || ""
                });
            }
            updates = found;
        } catch (e) {
            updates = [];
        }
    }

    Process {
        id: checkProcess
        command: ["fwupdmgr", "get-updates", "--json"]

        stdout: StdioCollector {
            onStreamFinished: svc._parse(text)
        }

        onExited: (exitCode, exitStatus) => {
            svc.checking = false;
            // 127/-1: binary missing → disable quietly. fwupd exits 2 for
            // "nothing to do", which is fine.
            if (exitCode === 127) {
                svc.available = false;
            }
        }
    }
}
