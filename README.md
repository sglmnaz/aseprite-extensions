# Aseprite Extensions

Two extensions for [Aseprite](https://www.aseprite.org/) 1.3 or later.

| Extension | What it does | Where to find it |
|---|---|---|
| [Color Reducer](color-reducer/README.md) | Reduces an image to distinct key colours and shrinks AI "fake pixel art" to its real grid. | *Sprite ▸ Reduce Colors...* |
| [Live Outline](live-outline/README.md) | Keeps a live outline (up to 10 rings, any width, Aseprite-style corners) on a layer under the art. | *Layer ▸ Live Outline...* |

## Install

Each extension is just its folder: copy the folder into Aseprite's extensions folder and restart Aseprite.

1. Download this repo (**Code ▸ Download ZIP**) and unzip it.
2. Open Aseprite's extensions folder (create the `extensions` folder if it is not there):
   - **Windows:** `%APPDATA%\Aseprite\extensions` (paste it in the File Explorer address bar)
   - **macOS:** `~/Library/Application Support/Aseprite/extensions`
   - **Linux:** `~/.config/aseprite/extensions`
3. Copy the `color-reducer` folder, the `live-outline` folder, or both into it.
4. Restart Aseprite. The extensions are listed in *Edit ▸ Preferences ▸ Extensions*, where you can also disable or
   uninstall them.

To update, replace the folder with the new one and restart Aseprite.

## For developers

You don't need any of this to use the extensions.

- **`pack.py`** (one per extension) builds a single installable file, `dist/<name>.aseprite-extension`: a zip of
  the folder that Aseprite installs on double-click, or via *Edit ▸ Preferences ▸ Extensions ▸ Add Extension*.
  It is the handy way to send one file to someone; copying the folder does the same thing.
  Run it with `python live-outline/pack.py`.
- **`sync.ps1`** copies the extensions installed in `%APPDATA%\Aseprite\extensions` back into this repo, for when
  you edit the installed files directly while trying them in Aseprite. Then review `git diff` and commit.

To add an extension: put it in its own folder with a `package.json`, a `README.md` and a `pack.py` (copy those of an
existing one), add its name to the list at the top of `sync.ps1` and a row to the table above.
