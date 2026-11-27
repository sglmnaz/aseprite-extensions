# Live Outline (Aseprite extension)

A live pixel-art outline on a layer **under** the art: draw the character on the layers above and the
outline redraws itself. No more erasing and redrawing the outline after every change of the silhouette.

**Install:** copy the `live-outline` folder into Aseprite's extensions folder and restart Aseprite (see the
[main README](../README.md#install)).

## Use

1. Select the art layer, then **Layer ▸ Live Outline...** (also on the timeline right-click menu of a layer).
2. Set the rings and press **Create**. A locked layer `Outline (live)` appears right under the active layer.
   While the dialog is open the outline of the current frame is previewed live; **Create** / **Apply** is one
   undo step, **Cancel** leaves the sprite as it was.
   - **Rings** (inside to outside): one at the start, **+ Add Ring** adds another (up to 10), **-** removes one.
     Each ring has a colour, a width in px (1–64, default 1) and **Corners**.
   - **Corners** opens the same 3×3 neighbour matrix as *Edit ▸ FX ▸ Outline*, with the presets *Round*,
     *Square*, *Horizontal* and *Vertical*. At width 1 it is exactly Aseprite's outline; wider rings grow it:
     a side neighbour adds an arm as long as the width, a corner neighbour fills its whole quadrant, and an empty
     corner between two side neighbours is filled rounded (Round at width 2 = 5×5 minus its corners).
   - **Source**: **all visible layers above** it (default) or **only the first layer above**.
   - **Preset**: empty by default. **Save...** stores the current rings and source under a name, picking a preset
     loads it, **Delete** removes it. Presets are yours: they are kept in the extension preferences on this PC
     and are not part of the extension.
3. Draw. When you release the stroke the outline of the current frame follows. **Ctrl+Z undoes only your
   stroke** (the outline is rewritten without undo steps and follows the undo too).
4. Settings: select the outline layer and open **Live Outline...** again. **Detach (Normal Layer)** turns it into
   a normal layer (it stays locked: unlock it in the timeline to retouch it by hand).

Other frames are rebuilt when you move to them (also during playback), and **every frame is rebuilt before Save /
Save As / Export / Export Sprite Sheet**, so the file and the exported PNGs are always right. **Layer ▸ Refresh
Live Outline (All Frames)** forces it.

## Rules

- Silhouette = union of the opaque pixels of the source layers (hidden, reference, tilemap and background
  layers and other outline layers never count; a hidden group hides its children).
- Each ring dilates the shape so far with its kernel (width + corners, see above). Layers made with version 1
  (width 1 or 2, no corners setting) read as *Round* and give the same pixels as before.
- RGB, Grayscale and Indexed sprites (Indexed takes the nearest palette colour). Outline beyond the canvas is cut.
- Settings live in the layer's extension properties (`sglmnaz/live-outline` ▸ `config`, e.g.
  `080808:2,ff00ff:10:111101111|above` = hex:width[:corners]), so they are saved in the `.aseprite`.

## Limits

- It updates on stroke release, not while the mouse is down.
- Onion skin shows other frames' outline as of the last time you visited them (or the last save).
- Creating a missing cel (a frame the outline layer had no cel in) is one undoable step named *Live Outline*;
  it never happens while you are undoing.
- Cost per rebuild: ~2 ms at 64×64, ~25 ms at 256×256 (two 2 px rings); wide rings cost more.
