with open("UpdaterSettings.qml") as f:
    text = f.read()

# Let's count { and } precisely and remove the extra } from the end.
lines = text.split('\n')
open_cnt = 0
close_cnt = 0
extra_idx = -1

for i, line in enumerate(lines):
    open_cnt += line.count('{')
    close_cnt += line.count('}')
    if close_cnt > open_cnt:
        extra_idx = i
        break

print(f"Mismatch at line {extra_idx}: open={open_cnt} close={close_cnt}")

# Actually, the simplest is to just remove one '}' from the end of the file.
# The file should end with exactly ONE '}' that closes `PluginSettings {`.
# Since there is one extra '}', the last two non-empty lines are probably '}' and '}'.

if text.count('{') + 1 == text.count('}'):
    # find the last '}' and remove it
    last_brace_idx = text.rfind('}')
    text = text[:last_brace_idx] + text[last_brace_idx+1:]
    with open("UpdaterSettings.qml", "w") as f:
        f.write(text)
    print("Removed the last '}'. Now counts:", text.count('{'), text.count('}'))
else:
    print("Multiple mismatches or something else is wrong.")
