with open("UpdaterSettings.qml", "r") as f:
    text = f.read()

text = text.replace('root.pluginData.hideWhenUpToDate === true', 'PluginService.loadPluginData("dankSoftwareDepot", "hideWhenUpToDate", false) === true')
text = text.replace('root.pluginData.showRuntimes === true', 'PluginService.loadPluginData("dankSoftwareDepot", "showRuntimes", true) === true')
text = text.replace('root.pluginData.includeFirmware !== false', 'PluginService.loadPluginData("dankSoftwareDepot", "includeFirmware", true) !== false')
text = text.replace('root.pluginData.confirmBeforeUpdate === true', 'PluginService.loadPluginData("dankSoftwareDepot", "confirmBeforeUpdate", false) === true')
text = text.replace('root.pluginData.pillOpensWindow === true', 'PluginService.loadPluginData("dankSoftwareDepot", "pillOpensWindow", false) === true')
text = text.replace('root.pluginData.autoUpdateMode || "notify"', 'PluginService.loadPluginData("dankSoftwareDepot", "autoUpdateMode", "notify")')
text = text.replace('root.pluginData.tintAppIcons !== false', 'PluginService.loadPluginData("dankSoftwareDepot", "tintAppIcons", true) !== false')

with open("UpdaterSettings.qml", "w") as f:
    f.write(text)
