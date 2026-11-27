# Color Reducer (Aseprite extension)

Turns big raster images (AI images, renders, photos, "fake pixel art" with soft edges) into pixel art with a
contained palette of **distinct key colours and their shades**: noise and anti-aliasing colours are left out,
similar colours are merged, and the image can be shrunk to its real pixel grid.

**Install:** double-click `dist/color-reducer.aseprite-extension` (built by `pack.py`) (or Aseprite ▸ Edit ▸
Preferences ▸ Extensions ▸ Add Extension). Rebuild it after editing the sources:
`python color-reducer/pack.py`.

## Use

**Sprite ▸ Riduci colori...** (right under *Color Mode*; also in **Edit ▸ FX** and in the palette's options
menu). The dialog stays open: **Applica**, look, **Ctrl+Z** (one undo step, size included), change the values,
**Applica** again. **Ripristina** puts the default values back.

| Field | What it does |
|---|---|
| Applica a | Current cel / every cel of the layer / the whole sprite. One palette for all the targets, so frames stay consistent. Locked, tilemap and reference layers are skipped. With an active selection only the selected pixels change (not with *Blocco* > 1). |
| Distinzione colori | Two colours closer than this (OKLab ΔE × 100, hue weighted) become one; the number of colours follows from the image. Default 6. Lower = more colours and shades (5 → ~33 on the test image), higher = fewer (7 → ~19). |
| Blocco (px) | 1 = keep the size. N = the sprite shrinks N times: each N×N square becomes one pixel with its most present colour. Use it on the ORIGINAL big image, N = the size of one fake pixel (e.g. 6 for a 1254 px AI image drawn as 209). |
| Dettagli piccoli | With *Blocco* > 1: a minority colour very different from the majority (a nostril, a fang, a thin line) can win its block. 0 = clean outlines (default); higher = more details, more jagged outlines. |
| Converti in Indexed | Converts the sprite to Indexed with **exact** indices (not Aseprite's approximate lookup). |

**Recipe for AI "pixel art":** open the original big image, *Tutto lo sprite*, *Distinzione colori* 6, *Blocco* =
fake-pixel size, *Dettagli piccoli* 0. Then retouch by hand.

Fixed in the dialog (`FIXED` in `plugin.lua`, the values that gave the best results; the core still takes them as
options): automatic palette, palette measured on flat areas only (soft edges ignored), hue weight 2.5, 5-bit
boxes, no snapping, no pre-flattening, no dithering, transparency made binary at alpha 128, palette replaced.
Options tried and dropped from the dialog because they did not help on real images: fixed number of colours,
rare-colour weight, pre-flattening of similar zones / speck absorption, Bayer dithering, precision, snapping to
existing colours.

## How it works (`reduce_core.lua`)

0. Optional flattening (region growing in OKLab against the zone's running mean, one existing colour per zone,
   speck absorption with detail grouping).
1. Counts the exact colours — only of flat-area pixels with *Ignora i bordi sfumati* (`M.EDGE` = 0.04).
2. Groups them in small RGB boxes averaged in **OKLab**, a/b (hue) axes scaled by *Peso tinta*.
3. Palette:
   - *Automatico* (`M.autoPalette`): k-means to 64 candidates (√pixels weights, so small real colours get one),
     then **Ward agglomeration**: merge the pair with the lowest pixels_a·pixels_b/(pixels_a+pixels_b)·distance²
     while some pair is closer than *Distinzione minima*. Colours under `M.MINSHARE` (0.04%) of the pixels are also
     merged, but only into a colour within `M.FAR` (2.5) × the threshold: a small colour unlike anything else
     (fangs, an eye highlight) stays.
   - *Numero fisso*: weighted k-means (k-means++ start, fixed seed), box weight = pixels^(1 − rare).
4. Every pixel takes the nearest palette colour (cached per exact colour), Bayer offset when dithering.
5. *Blocco* > 1 (`M.downscale`): block majority (+ contrast score `pixels·(1 + λ·distance)` with *Dettagli
   piccoli*), sprite resized in the same undo step.

## Tests (batch mode)

- 512×384, 120k colours, fixed method → 16 in ~0.4 s, 256 in ~1.5 s: exactly N colours, Indexed identical to the
  RGB result, selection respected, one undo step.
- AI bat image 1254×1254 (blocks of 6): *Automatico* 6, edges ignored, *Peso tinta* 25, *Blocco* 6 → 209×209,
  25 colours in ramps (reds/browns, oranges + cream, blues, purples) in ~3.4 s; fangs and eye highlight keep
  their cream; one Ctrl+Z restores 1254×1254. *Dettagli piccoli* 4 brings back nostrils and the mouth line but
  makes outlines jagged — the user preferred 0.
- Flattening on a noisy test image with a 1-px line and a 2×2 dot: isolated pixels 101 476 → 729 (tolerance 4,
  specks 1); the line survives every setting.
