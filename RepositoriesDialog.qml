import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

// Where software comes from, in one place: the repositories the system is
// configured with, the Flatpak remotes, and the handful of extra sources most
// people end up wanting anyway.
//
// Changes are deliberately narrow. Enabling and disabling an existing
// repository, adding the well-known third-party sources and adding or
// removing a Copr are the operations that are safe to express as a button;
// hand-writing a repository definition is not, and stays a job for a text
// editor.
Item {
    id: dialog

    property var logger: null

    property bool showing: false
    // Not `data`: that is Item's own default property, the one every child
    // element lands in, and shadowing it stops the component loading at all
    property var sourceData: ({})
    property bool loading: false
    property bool busy: false
    property string busyLabel: ""
    property string error: ""
    // Debug and source repositories outnumber the usable ones on Fedora and
    // are the reason a plain repository list is unreadable
    property bool showNoise: false
    // A distro repository is what the system is made of; switching one off is
    // asked twice rather than once
    property string confirmId: ""

    readonly property bool writable: sourceData.writable === true
    readonly property var repos: sourceData.repos || []
    readonly property var remotes: (sourceData.flatpak || []).filter(r => !r.local)
    readonly property var suggestions: (sourceData.suggestions || []).filter(s => !s.present)
    readonly property var flatpakCatalog: sourceData.flatpakCatalog || []

    readonly property var visibleRepos: repos.filter(r => dialog.showNoise || (!r.noise && !r.testing))

    function open() {
        showing = true;
        error = "";
        confirmId = "";
        refresh();
    }

    function close() {
        showing = false;
    }

    function refresh() {
        if (listProcess.running)
            return;
        loading = true;
        listProcess._output = "";
        listProcess.command = Backend.repoListCommand();
        listProcess.running = true;
    }

    // Every change runs the same way: a command, a spinner, a refreshed list.
    // The label is what the log and the busy line say it was.
    function _run(command, label, logTitle) {
        if (busy)
            return;
        error = "";
        busy = true;
        busyLabel = label;
        adminProcess._label = logTitle || "";
        adminProcess._detail = "";
        adminProcess._code = "";
        adminProcess._chroot = "";
        adminProcess.command = command;
        adminProcess.running = true;
    }

    function setRepoEnabled(repo, enabled) {
        _run(Backend.repoAdminCommand([enabled ? "enable" : "disable", repo.id]), enabled ? Tr.t("Enabling %1…").arg(repo.id) : Tr.t("Disabling %1…").arg(repo.id), enabled ? Tr.t("Enabled the %1 repository").arg(repo.id) : Tr.t("Disabled the %1 repository").arg(repo.id));
    }

    function addCopr(project) {
        const cleaned = project.trim();
        if (cleaned === "")
            return;
        _run(Backend.repoAdminCommand(["copr-enable", cleaned]), Tr.t("Adding %1…").arg(cleaned), Tr.t("Added the Copr %1").arg(cleaned));
    }

    function removeCopr(project) {
        _run(Backend.repoAdminCommand(["copr-remove", project]), Tr.t("Removing %1…").arg(project), Tr.t("Removed the Copr %1").arg(project));
    }

    function addRemote(url) {
        const cleaned = url.trim();
        if (cleaned === "")
            return;
        // The name is left to the helper: a .flatpakrepo file names the remote
        // it describes, so asking for one as well would be asking twice
        _run(Backend.repoUserCommand(["flatpak-add", "", cleaned]), Tr.t("Adding %1…").arg(cleaned), Tr.t("Added a Flatpak remote from %1").arg(cleaned));
    }

    function addCatalogRemote(entry) {
        _run(Backend.repoUserCommand(["flatpak-add", entry.name, entry.url]), Tr.t("Adding %1…").arg(entry.title), Tr.t("Added the Flatpak remote %1").arg(entry.title));
    }

    // Said here rather than in the helper, so it can be translated
    function remoteDetail(name) {
        switch (name) {
        case "flathub":
            return Tr.t("The Flatpak store most applications publish to.");
        case "flathub-beta":
            return Tr.t("Test builds of the same applications, before they reach Flathub.");
        case "fedora":
            return Tr.t("Fedora's own Flatpaks, built from the packages the distribution maintains.");
        case "gnome-nightly":
            return Tr.t("Daily builds of GNOME applications, straight from development.");
        case "kdeapps":
            return Tr.t("Daily builds of KDE applications, straight from development.");
        }
        return "";
    }

    function addSuggestion(entry) {
        const title = dialog.suggestionTitle(entry);
        _run(Backend.repoAdminCommand(["rpmfusion"].concat(entry.flavours || [])), Tr.t("Adding %1…").arg(title), Tr.t("Added %1").arg(title));
    }

    function removeRemote(remote) {
        _run(remote.scope === "system" ? Backend.repoAdminCommand(["flatpak-remove", remote.name, "system"]) : Backend.repoUserCommand(["flatpak-remove", remote.name, "user"]), Tr.t("Removing %1…").arg(remote.name), Tr.t("Removed the Flatpak remote %1").arg(remote.name));
    }

    function suggestionTitle(entry) {
        if (entry.id === "rpmfusion-free")
            return Tr.t("RPM Fusion (free)");
        if (entry.id === "rpmfusion-nonfree")
            return Tr.t("RPM Fusion (nonfree)");
        return Tr.t("RPM Fusion");
    }

    function suggestionDetail(entry) {
        if (entry.id === "rpmfusion-free")
            return Tr.t("Codecs and media software Fedora cannot ship itself.");
        if (entry.id === "rpmfusion-nonfree")
            return Tr.t("Hardware drivers and software with redistribution restrictions.");
        return Tr.t("Codecs, media software and hardware drivers Fedora cannot ship itself. Adds both repositories: most of nonfree builds on free.");
    }

    function repoLabel(repo) {
        if (repo.kind === "copr" && repo.project !== "")
            return repo.project;
        return repo.name !== "" ? repo.name : repo.id;
    }

    anchors.fill: parent
    visible: showing
    z: 120

    onShowingChanged: {
        if (showing)
            dialogFocus.forceActiveFocus();
    }

    Item {
        id: dialogFocus

        Keys.onEscapePressed: dialog.close()
    }

    Process {
        id: listProcess

        property string _output: ""

        stdout: SplitParser {
            onRead: line => listProcess._output += line
        }

        onExited: (exitCode, exitStatus) => {
            dialog.loading = false;
            if (exitCode !== 0) {
                dialog.error = Tr.t("The list of sources could not be read.");
                return;
            }
            try {
                dialog.sourceData = JSON.parse(listProcess._output);
            } catch (e) {
                dialog.error = Tr.t("The list of sources could not be read.");
            }
        }
    }

    // "fedora-44-x86_64" said the way people say it
    function chrootLabel(chroot) {
        const parts = /^fedora-([^-]+)-(.+)$/.exec(chroot);
        if (!parts)
            return chroot;
        return (parts[1] === "rawhide" ? Tr.t("Fedora Rawhide") : "Fedora " + parts[1]) + " (" + parts[2] + ")";
    }

    Process {
        id: adminProcess

        property string _label: ""
        property string _detail: ""
        property string _code: ""
        property string _chroot: ""

        stdout: SplitParser {
            onRead: line => {
                let event;
                try {
                    event = JSON.parse(line);
                } catch (e) {
                    return;
                }
                if (event.event === "op-error" || event.event === "error") {
                    adminProcess._detail = event.detail || event.message || "";
                    adminProcess._code = event.code || "";
                    adminProcess._chroot = event.chroot || "";
                }
            }
        }

        onExited: (exitCode, exitStatus) => {
            dialog.busy = false;
            dialog.busyLabel = "";
            dialog.confirmId = "";
            if (exitCode === 126 || exitCode === 127) {
                // pkexec's own refusal, which is not a failure of the change
                dialog.error = Tr.t("The authorisation was refused.");
            } else if (exitCode !== 0) {
                // dnf answers the chroot case with the project's entire chroot
                // list, mostly EPEL, which buries the one fact that matters
                if (adminProcess._code === "copr-no-chroot")
                    dialog.error = Tr.t("This Copr has no builds for %1.").arg(dialog.chrootLabel(adminProcess._chroot));
                else
                    dialog.error = adminProcess._detail !== "" ? adminProcess._detail : Tr.t("The change could not be made.");
            } else if (dialog.logger && adminProcess._label !== "") {
                dialog.logger.record("sources", adminProcess._label, []);
            }
            dialog.refresh();
        }
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)

        MouseArea {
            anchors.fill: parent
            onClicked: dialog.close()
            onWheel: wheel => wheel.accepted = true
        }
    }

    Rectangle {
        id: sheet

        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.spacingXL * 2, 760)
        height: Math.min(parent.height - Theme.spacingXL * 2, 640)
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh
        border.width: 1
        border.color: Theme.withAlpha(Theme.outline, 0.2)

        MouseArea {
            anchors.fill: parent
            onWheel: wheel => wheel.accepted = true
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacingM

                DankIcon {
                    name: "database"
                    size: 22
                    color: Theme.primary
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.t("Software sources")
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                }

                DankSpinner {
                    visible: dialog.busy || dialog.loading
                    size: 18
                }

                DankActionButton {
                    buttonSize: 30
                    iconName: "close"
                    iconSize: 16
                    iconColor: Theme.surfaceVariantText
                    onClicked: dialog.close()
                }
            }

            StyledText {
                Layout.fillWidth: true
                visible: dialog.busyLabel !== ""
                text: dialog.busyLabel
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
            }

            StyledText {
                Layout.fillWidth: true
                visible: dialog.error !== ""
                text: dialog.error
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.error
                wrapMode: Text.WordWrap
                maximumLineCount: 4
                elide: Text.ElideRight
            }

            // Distros other than Fedora are listed but not changed here
            StyledText {
                Layout.fillWidth: true
                visible: !dialog.writable && !dialog.loading
                text: Tr.t("Sources are shown for reference on this distribution. Changing them from here is only supported on the dnf family.")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            Flickable {
                id: scroll
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: width
                contentHeight: content.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: content
                    width: scroll.width
                    spacing: Theme.spacingL

                    // ── Sources worth having ────────────────────────────────
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: dialog.suggestions.length > 0
                        spacing: Theme.spacingS

                        StyledText {
                            text: Tr.t("Not configured yet")
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.DemiBold
                            color: Theme.surfaceVariantText
                        }

                        Repeater {
                            model: dialog.suggestions

                            delegate: Rectangle {
                                id: suggestionCard

                                required property var modelData

                                Layout.fillWidth: true
                                implicitHeight: suggestionRow.implicitHeight + Theme.spacingM * 2
                                radius: Theme.cornerRadius
                                color: Theme.withAlpha(Theme.secondary, 0.08)
                                border.width: 1
                                border.color: Theme.withAlpha(Theme.secondary, 0.25)

                                RowLayout {
                                    id: suggestionRow
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    spacing: Theme.spacingM

                                    DankIcon {
                                        name: "extension"
                                        size: 20
                                        color: Theme.secondary
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: dialog.suggestionTitle(suggestionCard.modelData)
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.DemiBold
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: dialog.suggestionDetail(suggestionCard.modelData)
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.WordWrap
                                        }
                                    }

                                    Item {
                                        implicitWidth: suggestionButton.width
                                        implicitHeight: suggestionButton.height

                                        DankButton {
                                            id: suggestionButton
                                            buttonHeight: 28
                                            horizontalPadding: Theme.spacingM
                                            iconName: "add"
                                            iconSize: 14
                                            text: Tr.t("Add")
                                            enabled: !dialog.busy
                                            backgroundColor: Theme.primary
                                            textColor: Theme.primaryText
                                            onClicked: dialog.addSuggestion(suggestionCard.modelData)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── Flatpak remotes ─────────────────────────────────────
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: dialog.remotes.length > 0
                        spacing: Theme.spacingS

                        StyledText {
                            text: Tr.t("Flatpak remotes (%1)").arg(dialog.remotes.length)
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.DemiBold
                            color: Theme.surfaceVariantText
                        }

                        Repeater {
                            model: dialog.remotes

                            delegate: RowLayout {
                                id: remoteRow

                                required property var modelData

                                Layout.fillWidth: true
                                spacing: Theme.spacingM

                                DankIcon {
                                    name: "deployed_code"
                                    size: 18
                                    color: Theme.surfaceVariantText
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: remoteRow.modelData.title !== "" ? remoteRow.modelData.title : remoteRow.modelData.name
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: remoteRow.modelData.url
                                        font.pixelSize: Theme.fontSizeSmall - 2
                                        color: Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                    }
                                }

                                Rectangle {
                                    implicitWidth: scopeLabel.implicitWidth + Theme.spacingS * 2
                                    implicitHeight: 20
                                    radius: height / 2
                                    color: Theme.withAlpha(Theme.surfaceVariantText, 0.15)

                                    StyledText {
                                        id: scopeLabel
                                        anchors.centerIn: parent
                                        text: remoteRow.modelData.scope === "user" ? Tr.t("user") : Tr.t("system")
                                        font.pixelSize: Theme.fontSizeSmall - 2
                                        color: Theme.surfaceVariantText
                                    }
                                }

                                DankActionButton {
                                    buttonSize: 28
                                    iconName: "delete"
                                    iconSize: 15
                                    enabled: !dialog.busy
                                    iconColor: dialog.confirmId === "remote:" + remoteRow.modelData.name + remoteRow.modelData.scope ? Theme.error : Theme.surfaceVariantText
                                    tooltipText: dialog.confirmId === "remote:" + remoteRow.modelData.name + remoteRow.modelData.scope ? Tr.t("Click again to confirm") : Tr.t("Remove")
                                    onClicked: {
                                        const key = "remote:" + remoteRow.modelData.name + remoteRow.modelData.scope;
                                        if (dialog.confirmId === key)
                                            dialog.removeRemote(remoteRow.modelData);
                                        else
                                            dialog.confirmId = key;
                                    }
                                }
                            }
                        }
                    }

                    // ── Well-known Flatpak sources ──────────────────────────
                    // As buttons rather than as addresses to look up: these
                    // five are what almost everyone means by "add a remote"
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: dialog.flatpakCatalog.length > 0
                        spacing: Theme.spacingS

                        StyledText {
                            text: Tr.t("Well-known Flatpak sources")
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.DemiBold
                            color: Theme.surfaceVariantText
                        }

                        Repeater {
                            model: dialog.flatpakCatalog

                            delegate: RowLayout {
                                id: catalogRow

                                required property var modelData

                                Layout.fillWidth: true
                                spacing: Theme.spacingM

                                DankIcon {
                                    name: "storefront"
                                    size: 18
                                    color: catalogRow.modelData.present ? Theme.success : Theme.secondary
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: catalogRow.modelData.title
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: dialog.remoteDetail(catalogRow.modelData.name)
                                        font.pixelSize: Theme.fontSizeSmall - 2
                                        color: Theme.surfaceVariantText
                                        wrapMode: Text.WordWrap
                                    }
                                }

                                StyledText {
                                    visible: catalogRow.modelData.present
                                    text: Tr.t("Added")
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.success
                                }

                                Item {
                                    visible: !catalogRow.modelData.present
                                    implicitWidth: catalogButton.width
                                    implicitHeight: catalogButton.height

                                    DankButton {
                                        id: catalogButton
                                        buttonHeight: 28
                                        horizontalPadding: Theme.spacingM
                                        iconName: "add"
                                        iconSize: 14
                                        text: Tr.t("Add")
                                        enabled: !dialog.busy
                                        backgroundColor: catalogRow.modelData.name === "flathub" ? Theme.primary : Theme.withAlpha(Theme.buttonBg, 0.9)
                                        textColor: catalogRow.modelData.name === "flathub" ? Theme.primaryText : Theme.buttonText
                                        onClicked: dialog.addCatalogRemote(catalogRow.modelData)
                                    }
                                }
                            }
                        }
                    }

                    // ── Add a Flatpak remote ────────────────────────────────
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingS

                        StyledText {
                            text: Tr.t("Add a Flatpak remote")
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.DemiBold
                            color: Theme.surfaceVariantText
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingM

                            DankTextField {
                                id: remoteField
                                Layout.fillWidth: true
                                placeholderText: Tr.t("Address of a .flatpakrepo file")
                                FieldPlaceholder {
                                    text: Tr.t("Address of a .flatpakrepo file")
                                }
                                leftIconName: "link"
                                onAccepted: {
                                    dialog.addRemote(text);
                                    text = "";
                                }
                            }

                            Item {
                                implicitWidth: remoteButton.width
                                implicitHeight: remoteButton.height

                                DankButton {
                                    id: remoteButton
                                    buttonHeight: 30
                                    horizontalPadding: Theme.spacingM
                                    iconName: "add"
                                    iconSize: 14
                                    text: Tr.t("Add")
                                    enabled: !dialog.busy && remoteField.text.trim() !== ""
                                    backgroundColor: Theme.primary
                                    textColor: Theme.primaryText
                                    onClicked: {
                                        dialog.addRemote(remoteField.text);
                                        remoteField.text = "";
                                    }
                                }
                            }
                        }

                        StyledText {
                            Layout.fillWidth: true
                            text: Tr.t("For anything not listed above. Added for you alone, so it needs no password.")
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }
                    }

                    // ── Configured repositories ─────────────────────────────
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacingS

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingM

                            StyledText {
                                Layout.fillWidth: true
                                text: Tr.t("Repositories (%1)").arg(dialog.visibleRepos.length)
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.DemiBold
                                color: Theme.surfaceVariantText
                            }

                            Item {
                                implicitWidth: noiseButton.width
                                implicitHeight: noiseButton.height

                                DankButton {
                                    id: noiseButton
                                    buttonHeight: 26
                                    horizontalPadding: Theme.spacingM
                                    text: dialog.showNoise ? Tr.t("Hide debug and source repositories") : Tr.t("Show debug and source repositories")
                                    backgroundColor: "transparent"
                                    textColor: Theme.surfaceVariantText
                                    onClicked: dialog.showNoise = !dialog.showNoise
                                }
                            }
                        }

                        Repeater {
                            model: dialog.visibleRepos

                            delegate: RowLayout {
                                id: repoRow

                                required property var modelData

                                readonly property bool isDistro: modelData.kind === "distro"
                                readonly property string confirmKey: "repo:" + modelData.id
                                readonly property bool awaitingConfirm: dialog.confirmId === confirmKey

                                Layout.fillWidth: true
                                spacing: Theme.spacingM

                                DankIcon {
                                    name: repoRow.modelData.kind === "copr" ? "person" : (repoRow.isDistro ? "verified" : "public")
                                    size: 18
                                    color: repoRow.isDistro ? Theme.primary : Theme.surfaceVariantText
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: dialog.repoLabel(repoRow.modelData)
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceText
                                        elide: Text.ElideRight
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        text: repoRow.awaitingConfirm ? Tr.t("This is part of the distribution — click the switch again to confirm.") : repoRow.modelData.id
                                        font.pixelSize: Theme.fontSizeSmall - 2
                                        color: repoRow.awaitingConfirm ? Theme.warning : Theme.surfaceVariantText
                                        elide: Text.ElideRight
                                    }
                                }

                                DankActionButton {
                                    visible: repoRow.modelData.kind === "copr" && repoRow.modelData.project !== ""
                                    buttonSize: 28
                                    iconName: "delete"
                                    iconSize: 15
                                    enabled: !dialog.busy && dialog.writable
                                    iconColor: dialog.confirmId === "copr:" + repoRow.modelData.project ? Theme.error : Theme.surfaceVariantText
                                    tooltipText: dialog.confirmId === "copr:" + repoRow.modelData.project ? Tr.t("Click again to confirm") : Tr.t("Remove")
                                    onClicked: {
                                        const key = "copr:" + repoRow.modelData.project;
                                        if (dialog.confirmId === key)
                                            dialog.removeCopr(repoRow.modelData.project);
                                        else
                                            dialog.confirmId = key;
                                    }
                                }

                                // Wrapped, because DankToggle sizes itself and
                                // a layout writing its width fights that
                                Item {
                                    implicitWidth: 52
                                    implicitHeight: 30

                                    DankToggle {
                                        anchors.fill: parent
                                        hideText: true
                                        checked: repoRow.modelData.enabled
                                        enabled: dialog.writable && !dialog.busy
                                        onToggled: checked => {
                                            // Switching off a repository the system
                                            // is built from is asked twice
                                            if (!checked && repoRow.isDistro && !repoRow.awaitingConfirm) {
                                                dialog.confirmId = repoRow.confirmKey;
                                                return;
                                            }
                                            dialog.setRepoEnabled(repoRow.modelData, checked);
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── Add a Copr ──────────────────────────────────────────
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: dialog.writable
                        spacing: Theme.spacingS

                        StyledText {
                            text: Tr.t("Add a Copr")
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.DemiBold
                            color: Theme.surfaceVariantText
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacingM

                            DankTextField {
                                id: coprField
                                Layout.fillWidth: true
                                placeholderText: Tr.t("owner/project")
                                FieldPlaceholder {
                                    text: Tr.t("owner/project")
                                }
                                leftIconName: "person_add"
                                onAccepted: {
                                    dialog.addCopr(text);
                                    text = "";
                                }
                            }

                            Item {
                                implicitWidth: coprButton.width
                                implicitHeight: coprButton.height

                                DankButton {
                                    id: coprButton
                                    buttonHeight: 30
                                    horizontalPadding: Theme.spacingM
                                    iconName: "add"
                                    iconSize: 14
                                    text: Tr.t("Add")
                                    enabled: !dialog.busy && coprField.text.trim() !== ""
                                    backgroundColor: Theme.primary
                                    textColor: Theme.primaryText
                                    onClicked: {
                                        dialog.addCopr(coprField.text);
                                        coprField.text = "";
                                    }
                                }
                            }
                        }

                        StyledText {
                            Layout.fillWidth: true
                            text: Tr.t("Copr repositories are built by individuals, not by the distribution. Their packages are as trustworthy as their owner.")
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }
                    }
                }
            }
        }
    }
}
