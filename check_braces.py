with open("UpdaterSettings.qml") as f:
    text = f.read()
    
# Let's find the last few lines
print(text[-200:])
