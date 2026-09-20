with open("UpdaterSettings.qml") as f:
    text = f.read()

print("Open:", text.count("{"))
print("Close:", text.count("}"))
