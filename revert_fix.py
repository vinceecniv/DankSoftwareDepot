with open("UpdaterSettings.qml", "r") as f:
    text = f.read()

text = text.replace('PluginService.loadPluginData("dankSoftwareDepot", "hideWhenUpToDate", false) === true', 'root.pluginData.hideWhenUpToDate === true')
text = text.replace('PluginService.loadPluginData("dankSoftwareDepot", "showRuntimes", true) === true', 'root.pluginData.showRuntimes === true')
text = text.replace('PluginService.loadPluginData("dankSoftwareDepot", "includeFirmware", true) !== false', 'root.pluginData.includeFirmware !== false')
text = text.replace('PluginService.loadPluginData("dankSoftwareDepot", "confirmBeforeUpdate", false) === true', 'root.pluginData.confirmBeforeUpdate === true')
text = text.replace('PluginService.loadPluginData("dankSoftwareDepot", "pillOpensWindow", false) === true', 'root.pluginData.pillOpensWindow === true')
text = text.replace('PluginService.loadPluginData("dankSoftwareDepot", "autoUpdateMode", "notify")', 'root.pluginData.autoUpdateMode || "notify"')
text = text.replace('PluginService.loadPluginData("dankSoftwareDepot", "tintAppIcons", true) !== false', 'root.pluginData.tintAppIcons !== false')

with open("UpdaterSettings.qml", "w") as f:
    f.write(text)
