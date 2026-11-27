# Aseprite Extensions

My Aseprite extensions, versioned in one repo. A new extension is one more folder.

| Folder | What |
|---|---|
| `color-reducer/` | Reduces an image to distinct key colours and shrinks AI "fake pixel art" to its real grid (*Sprite ▸ Riduci colori...*). |
| `live-outline/` | Keeps a live outline (up to 10 rings, any width, Aseprite-style corners) on a layer under the art (*Layer ▸ Live Outline...*). |

## Where the extensions live

The extensions run from Aseprite's folder, `%APPDATA%\Aseprite\extensions\<name>\`. To copy the installed versions
back here, run `sync.ps1`, review `git diff`, then commit:

```powershell
.\sync.ps1
```

`sync.ps1` copies only the `.lua` and `package.json` files. Each extension's `README.md` and `pack.py` exist only
in this repo.

## Installing an extension

```powershell
python color-reducer/pack.py
```

This builds `dist/color-reducer.aseprite-extension`. To install it, double-click the file or use
Aseprite ▸ Edit ▸ Preferences ▸ Extensions ▸ Add Extension, then restart Aseprite. `dist/` is not versioned.

## Adding an extension

1. Put it in `<name>/` with a `README.md` and a `pack.py` (copy the ones of an existing extension).
2. Add its name to the list at the top of `sync.ps1`.
3. Add a row to the table above.
