import re

with open('UpdaterWindow.qml', 'r') as f:
    window_content = f.read()

# Extract the Column with id: prefColumn
match = re.search(r'(Column\s*{\s*id:\s*prefColumn.*?)(\n\s*}\s*// ═════════════════════════════════════════════════════\n\s*// 2\. ABOUT / INFO VIEW)', window_content, re.DOTALL)
if not match:
    print("Column not found")
    exit(1)

pref_column = match.group(1) + "\n        }"

# Fix the bindings in pref_column
pref_column = pref_column.replace('prefColumn.width', 'parent.width')
pref_column = pref_column.replace('win.widgetRoot ? win.widgetRoot.hideWhenUpToDate : false', 'root.pluginData.hideWhenUpToDate === true')
pref_column = pref_column.replace('win.widgetRoot ? win.widgetRoot.showRuntimes : false', 'root.pluginData.showRuntimes === true')
pref_column = pref_column.replace('win.widgetRoot ? win.widgetRoot.includeFirmware : true', 'root.pluginData.includeFirmware !== false')
pref_column = pref_column.replace('win.widgetRoot ? win.widgetRoot.confirmBeforeUpdate : false', 'root.pluginData.confirmBeforeUpdate === true')
pref_column = pref_column.replace('win.widgetRoot ? win.widgetRoot.pillOpensWindow : false', 'root.pluginData.pillOpensWindow === true')
pref_column = pref_column.replace('win.widgetRoot ? win.widgetRoot.autoUpdateMode : "notify"', 'root.pluginData.autoUpdateMode || "notify"')
pref_column = pref_column.replace('Ui.tintAppIcons', 'root.pluginData.tintAppIcons !== false')

# Ensure Backend accesses are fine (Backend.useSudo, Backend.launcherEntryPresent, etc)
# They should be fine because Backend is a singleton in this plugin.

# Replace in UpdaterSettings.qml
with open('UpdaterSettings.qml', 'r') as f:
    settings_content = f.read()

# We want to replace everything from "ToggleSetting {" at line 134 to the end, except the last "}"
start_idx = settings_content.find('    ToggleSetting {\n        settingKey: "hideWhenUpToDate"')
end_idx = settings_content.rfind('}')
if start_idx == -1 or end_idx == -1:
    print("ToggleSettings not found")
    exit(1)

new_settings_content = settings_content[:start_idx] + "    " + pref_column.replace('\n', '\n    ') + "\n" + settings_content[end_idx:]

with open('UpdaterSettings.qml', 'w') as f:
    f.write(new_settings_content)

print("Done")
