with open("UpdaterSettings.qml", "r") as f:
    text = f.read()

# Insert the hidden settings right after PluginSettings { ... } and before the StyledRect
hidden_settings = """
    ToggleSetting { id: s_hide; settingKey: "hideWhenUpToDate"; defaultValue: false; visible: false; height: 0 }
    ToggleSetting { id: s_runtimes; settingKey: "showRuntimes"; defaultValue: true; visible: false; height: 0 }
    ToggleSetting { id: s_firmware; settingKey: "includeFirmware"; defaultValue: true; visible: false; height: 0 }
    ToggleSetting { id: s_confirm; settingKey: "confirmBeforeUpdate"; defaultValue: false; visible: false; height: 0 }
    ToggleSetting { id: s_tint; settingKey: "tintAppIcons"; defaultValue: true; visible: false; height: 0 }
    ToggleSetting { id: s_pill; settingKey: "pillOpensWindow"; defaultValue: false; visible: false; height: 0 }
    SelectionSetting { id: s_auto; settingKey: "autoUpdateMode"; defaultValue: "notify"; visible: false; height: 0; options: [{label:"", value:""}] }
"""
text = text.replace('pluginId: "dankSoftwareDepot"\n', 'pluginId: "dankSoftwareDepot"\n' + hidden_settings)

# Now replace the bindings in the toggles.
text = text.replace('root.pluginData.hideWhenUpToDate === true', 's_hide.value === true')
text = text.replace('PluginService.savePluginData("dankSoftwareDepot", "hideWhenUpToDate", checked)', 's_hide.value = checked')

text = text.replace('root.pluginData.showRuntimes === true', 's_runtimes.value === true')
text = text.replace('PluginService.savePluginData("dankSoftwareDepot", "showRuntimes", checked)', 's_runtimes.value = checked')

text = text.replace('root.pluginData.includeFirmware !== false', 's_firmware.value === true')
text = text.replace('PluginService.savePluginData("dankSoftwareDepot", "includeFirmware", checked)', 's_firmware.value = checked')

text = text.replace('root.pluginData.confirmBeforeUpdate === true', 's_confirm.value === true')
text = text.replace('PluginService.savePluginData("dankSoftwareDepot", "confirmBeforeUpdate", checked)', 's_confirm.value = checked')

text = text.replace('root.pluginData.pillOpensWindow === true', 's_pill.value === true')
text = text.replace('PluginService.savePluginData("dankSoftwareDepot", "pillOpensWindow", checked)', 's_pill.value = checked')

text = text.replace('root.pluginData.autoUpdateMode || "notify"', 's_auto.value')
text = text.replace('PluginService.savePluginData("dankSoftwareDepot", "autoUpdateMode", autoMap[label]);', 's_auto.value = autoMap[label];')

text = text.replace('root.pluginData.tintAppIcons !== false', 's_tint.value === true')
text = text.replace('PluginService.savePluginData("dankSoftwareDepot", "tintAppIcons", checked)', 's_tint.value = checked')

with open("UpdaterSettings.qml", "w") as f:
    f.write(text)
