# Color Reducer (Aseprite extension)

Turns big raster images (AI images, renders, photos, "fake pixel art" with soft edges) into pixel art with a
contained palette of **distinct key colours and their shades**: noise and anti-aliasing colours are left out,
similar colours are merged, and the image can be shrunk to its real pixel grid.

**Install:** copy the `color-reducer` folder into Aseprite's extensions folder and restart Aseprite (see the
[main README](../README.md#install)).

## Use

**Sprite ▸ Reduce Colors...** (right under *Color Mode*; also in **Edit ▸ FX** and in the palette's options
menu). The dialog stays open: **Apply**, look, **Ctrl+Z** (one undo step, size included), change the values,
**Apply** again. **Reset** puts the default values back.

| Field | What it does |
|---|---|
| Apply To | Current cel / every cel of the layer / the whole sprite. One palette for all the targets, so frames stay consistent. Locked, tilemap and reference layers are skipped. With an active selection only the selected pixels change (not with *Block* > 1). |
| Color Distinction | Two colours closer than this (OKLab ΔE × 100, hue weighted) become one; the number of colours follows from the image. Default 6. Lower = more colours and shades (5 → ~33 on the test image), higher = fewer (7 → ~19). |
| Block (px) | 1 = keep the size. N = the sprite shrinks N times: each N×N square becomes one pixel with its most present colour. Use it on the ORIGINAL big image, N = the size of one fake pixel (e.g. 6 for a 1254 px AI image drawn as 209). |
| Small Details | With *Block* > 1: a minority colour very different from the majority (a nostril, a fang, a thin line) can win its block. 0 = clean outlines (default); higher = more details, more jagged outlines. |
| Convert to Indexed | Converts the sprite to Indexed with **exact** indices (not Aseprite's approximate lookup). |

**Recipe for AI "pixel art":** open the original big image, *Whole Sprite*, *Color Distinction* 6, *Block* =
fake-pixel size, *Small Details* 0. Then retouch by hand.

Fixed in the dialog (`FIXED` in `plugin.lua`, the values that gave the best results; the core still takes them as
options): automatic palette, palette measured on flat areas only (soft edges ignored), hue weight 2.5, 5-bit
boxes, no snapping, no pre-flattening, no dithering, transparency made binary at alpha 128, palette replaced.
Options tried and dropped from the dialog because they did not help on real images: fixed number of colours,
rare-colour weight, pre-flattening of similar zones / speck absorption, Bayer dithering, precision, snapping to
existing colours.

## How it works (`reduce_core.lua`)

0. Optional flattening (region growing in OKLab against the zone's running mean, one existing colour per zone,
   speck absorption with detail grouping).
1. Counts the exact colours — only of flat-area pixels with *ignore soft edges* (`M.EDGE` = 0.04).
2. Groups them in small RGB boxes averaged in **OKLab**, a/b (hue) axes scaled by the *hue weight*.
3. Palette:
   - *Automatic* (`M.autoPalette`): k-means to 64 candidates (√pixels weights, so small real colours get one),
     then **Ward agglomeration**: merge the pair with the lowest pixels_a·pixels_b/(pixels_a+pixels_b)·distance²
     while some pair is closer than the *minimum distinction*. Colours under `M.MINSHARE` (0.04%) of the pixels are also
     merged, but only into a colour within `M.FAR` (2.5) × the threshold: a small colour unlike anything else
     (fangs, an eye highlight) stays.
   - *Fixed count*: weighted k-means (k-means++ start, fixed seed), box weight = pixels^(1 − rare).
4. Every pixel takes the nearest palette colour (cached per exact colour), Bayer offset when dithering.
5. *Block* > 1 (`M.downscale`): block majority (+ contrast score `pixels·(1 + λ·distance)` with *Small
   Details*), sprite resized in the same undo step.

## Tests (batch mode)

- 512×384, 120k colours, fixed method → 16 in ~0.4 s, 256 in ~1.5 s: exactly N colours, Indexed identical to the
  RGB result, selection respected, one undo step.
- AI bat image 1254×1254 (blocks of 6): *Automatic* 6, edges ignored, *hue weight* 25, *Block* 6 → 209×209,
  25 colours in ramps (reds/browns, oranges + cream, blues, purples) in ~3.4 s; fangs and eye highlight keep
  their cream; one Ctrl+Z restores 1254×1254. *Small Details* 4 brings back nostrils and the mouth line but
  makes outlines jagged — the user preferred 0.
- Flattening on a noisy test image with a 1-px line and a 2×2 dot: isolated pixels 101 476 → 729 (tolerance 4,
  specks 1); the line survives every setting.
