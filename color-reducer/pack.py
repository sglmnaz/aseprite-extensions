"""Builds dist/color-reducer.aseprite-extension (a zip of package.json + the .lua files).
Run after editing the extension: python color-reducer/pack.py
Install: double-click the built file, or Aseprite > Edit > Preferences > Extensions > Add Extension."""
import os
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DIST = os.path.join(os.path.dirname(HERE), 'dist')
os.makedirs(DIST, exist_ok=True)
OUT = os.path.join(DIST, 'color-reducer.aseprite-extension')

with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED) as z:
    for name in ('package.json', 'plugin.lua', 'reduce_core.lua'):
        z.write(os.path.join(HERE, name), name)
print(OUT)
