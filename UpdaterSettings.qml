import QtQuick
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
        settingKey: "pillOpensWindow"
        label: Tr.t("Bar click opens window")
        description: Tr.t("Open the standalone updater window instead of the compact popout when clicking the bar pill.")
        defaultValue: false
    }
}
