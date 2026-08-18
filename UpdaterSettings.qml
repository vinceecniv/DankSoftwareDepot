import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root

    pluginId: "dankSoftwareDepot"

    StyledText {
        width: parent.width
        text: "Dank Software Depot"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: Tr.t("Visual updater built on the DMS system update service. Check interval and ignored packages are managed in Settings → System Updater.")
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    // Someone reading this panel is one click from the settings and several
    // from the thing they configure. The window is opened over the same IPC
    // the desktop entry uses, through the same shim — this panel is a
    // separate component from the widget that owns the window, so there is no
    // reference to reach for, and open.sh already knows how to find `dms` on
    // a narrower PATH and how to say so when it cannot.
    DankButton {
        buttonHeight: 30
        horizontalPadding: Theme.spacingM
        iconName: "open_in_new"
        iconSize: 14
        text: Tr.t("Open Dank Software Depot")
        backgroundColor: Theme.secondaryContainer
        textColor: Theme.surfaceText
        onClicked: Quickshell.execDetached(["sh", Qt.resolvedUrl("scripts/open.sh").toString().replace("file://", "")])
    }

    ToggleSetting {
        settingKey: "hideWhenUpToDate"
        label: Tr.t("Hide when up to date")
        description: Tr.t("Hide the bar pill while there are no pending updates.")
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "showRuntimes"
        label: Tr.t("Show runtimes and extensions")
        description: Tr.t("List Flatpak runtimes, locales and codec extensions in the updater window. They are always included in Update All.")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "includeFirmware"
        label: Tr.t("Include firmware updates")
        description: Tr.t("Check for device firmware updates via fwupd (LVFS) and include them in Update All.")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "confirmBeforeUpdate"
        label: Tr.t("Confirm before updating")
        description: Tr.t("Require a second click on Update All before the run starts.")
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "tintAppIcons"
        label: Tr.t("Tint app icons with the theme colour")
        description: Tr.t("Draw app icons in greyscale and colour them with the active DMS accent, instead of showing each app's own colours.")
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "pillOpensWindow"
        label: Tr.t("Bar click opens window")
        description: Tr.t("Open the standalone updater window instead of the compact popout when clicking the bar pill.")
        defaultValue: false
    }

    // The same choice the window's own settings panel offers. Both panels
    // write the same keys, so whichever one someone finds first is the whole
    // set — a setting that exists in only one of them is a setting most
    // people do not have.
    SelectionSetting {
        settingKey: "autoUpdateMode"
        label: Tr.t("Automatic updates")
        description: Tr.t("Notify when updates are found, and optionally install Flatpak updates automatically. System packages always ask first.")
        defaultValue: "notify"
        options: [
            {
                label: Tr.t("Off"),
                value: "off"
            },
            {
                label: Tr.t("Notify only"),
                value: "notify"
            },
            {
                label: Tr.t("Auto-install Flatpaks"),
                value: "auto"
            }
        ]
    }

    // Not a stored setting but a file on disk, so what it shows comes from
    // Backend rather than from the plugin's data. ToggleSetting assigns its
    // own `value` once the stored data loads, which would overwrite a plain
    // binding — hence the Binding, which reasserts itself afterwards. The
    // guard in the handler is what keeps that reassertion from being read as
    // someone flipping the switch.
    ToggleSetting {
        id: launcherToggle

        settingKey: "showInLauncher"
        label: Tr.t("Show in app launcher")
        description: Tr.t("Place a desktop entry so this window can be opened from the application launcher, like a standalone app.")
        defaultValue: false

        Binding {
            target: launcherToggle
            property: "value"
            value: Backend.launcherEntryPresent
            when: Backend.launcherEntryChecked
            restoreMode: Binding.RestoreNone
        }

        onValueChanged: {
            if (!Backend.launcherEntryChecked || value === Backend.launcherEntryPresent)
                return;
            if (value)
                Backend.installLauncherEntry();
            else
                Backend.removeLauncherEntry();
        }
    }
}
