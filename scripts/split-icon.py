#!/usr/bin/env python3
"""Builds Resources/AppIcon.icon (Icon Composer) from the flat artwork, Resources/AppIcon-artwork.png,
by splitting it into layers so macOS can treat them separately (the Dark, Clear and Tinted icon
styles, shadows):

    Signals   waveform, blips      the lit-up things on the screen, with their glow
    Bezel     bezel                the metal ring, with a system shadow
    Screen    sweep, screen        the radar sweep, and the glass with its grid
    fill                           the plate behind the ring, as a gradient

Stacked, the layers give back the artwork pixel for pixel (the script checks). Glows are cut out
with colour-to-alpha against the screen as it would look without them, which is rebuilt around
the screen's centre so its grid circles and lines carry on underneath. Positions and colours are
read off this artwork; new artwork needs them measured again.

    python3 scripts/split-icon.py        # needs Pillow and NumPy (pip3 install pillow numpy)
"""
import json
import pathlib
import warnings

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / 'Resources/AppIcon-artwork.png'
OUT = ROOT / 'Resources/AppIcon.icon'
N = 1024

art = Image.open(SRC).convert('RGB').resize((N, N), Image.LANCZOS)
C = np.asarray(art, dtype=np.float64) / 255
L = C @ np.array([0.2126, 0.7152, 0.0722])
yy, xx = np.mgrid[0:N, 0:N].astype(np.float64)

# The ring's centre, a little below the canvas centre (measured). The screen's is fitted below.
CX, CY = 514.8, 521.0
R = np.hypot(xx - CX, yy - CY)
TH = np.arctan2(yy - CY, xx - CX)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)


def bilinear(img, x, y):
    x = np.clip(x, 0, N - 1.001)
    y = np.clip(y, 0, N - 1.001)
    x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
    fx, fy = x - x0, y - y0
    if img.ndim == 3:
        fx, fy = fx[..., None], fy[..., None]
    return (img[y0, x0] * (1 - fx) * (1 - fy) + img[y0, x0 + 1] * fx * (1 - fy)
            + img[y0 + 1, x0] * (1 - fx) * fy + img[y0 + 1, x0 + 1] * fx * fy)


def circular_smooth(v, median=9, mean=7):
    """Median then box filter around the circle, to drop the odd misdetection."""
    n = len(v)
    h = median // 2
    padded = np.r_[v[-h:], v, v[:h]]
    med = np.array([np.median(padded[i:i + median]) for i in range(n)])
    h = mean // 2
    padded = np.r_[med[-h:], med, med[:h]]
    return np.convolve(padded, np.ones(mean) / mean, mode='valid')


def edge(lo, hi, pick, angles=1440):
    """Per-angle edge radius between lo and hi, picked from each luminance profile, as a map over
    the canvas (interpolated by angle), so the masks follow the artwork rather than a perfect circle."""
    th = np.linspace(-np.pi, np.pi, angles, endpoint=False)
    rs = np.arange(lo, hi, 0.25)
    prof = bilinear(L, CX + np.cos(th)[:, None] * rs, CY + np.sin(th)[:, None] * rs)
    radius = circular_smooth(np.array([pick(rs, p) for p in prof]))
    return np.interp(TH, th, radius, period=2 * np.pi)


def outermost_dark(rs, p):
    dark = np.nonzero(p < 0.035)[0]
    return rs[dark[-1]] if len(dark) else rs[-1]


def darkest(rs, p):
    k = np.convolve(p, np.ones(9) / 9, mode='same')
    return rs[np.argmin(k)]


ring_outer = edge(445, 492, outermost_dark)   # outside of the ring's black outer rim
gap = edge(356, 398, darkest)                  # black gap between the bezel and the screen

bezel_alpha = smoothstep(gap - 1, gap + 1, R) * (1 - smoothstep(ring_outer - 0.75, ring_outer + 0.75, R))
# The screen runs on under the bezel so the seam between them composites back to the original.
screen_alpha = 1 - smoothstep(gap + 6, gap + 8, R)


# ---- Things lit up on the screen: cut out with colour-to-alpha against the screen behind them ----

def polyline_distance(points):
    d = np.full((N, N), np.inf)
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        vx, vy = x1 - x0, y1 - y0
        t = np.clip(((xx - x0) * vx + (yy - y0) * vy) / (vx * vx + vy * vy), 0, 1)
        d = np.minimum(d, np.hypot(xx - (x0 + t * vx), yy - (y0 + t * vy)))
    return d


WAVE = [(158, 520), (275, 520), (310, 590), (345, 553), (382, 582), (438, 410), (490, 575),
        (530, 500), (585, 605), (625, 535), (865, 535)]
wave_dist = polyline_distance(WAVE)
wave_region = wave_dist < 56

BLIPS = [(352, 352), (723, 426), (742, 640), (353, 684), (614, 750)]
sat = C.max(-1) - C.min(-1)
blip_regions = []
for bx, by in BLIPS:
    near = (np.hypot(xx - bx, yy - by) < 34) & (sat > 0.35) & (C.max(-1) > 0.75)
    w = near.astype(float)
    bx, by = (xx * w).sum() / w.sum(), (yy * w).sum() / w.sum()
    blip_regions.append(np.hypot(xx - bx, yy - by) < 76)
blip_region = np.any(blip_regions, 0)

# The sweep: a wedge from the centre, its bright leading edge pointing up and to the right,
# fading out anticlockwise towards twelve o'clock.
deg = np.degrees(TH)
sweep_region = (deg > -95) & (deg < -34)

# Front to back; each pixel goes to the frontmost element whose region holds it. Nothing past the
# screen's edge: glow that spills onto the bezel stays in the bezel.
on_screen = R < gap - 1
# The sweep's leading edge starts where the waveform peaks; off the waveform's core it's the sweep's.
sweep_edge = polyline_distance([(530, 497), (785, 270)]) < 9
wave_m = wave_region & on_screen & ~(sweep_edge & (wave_dist > 12))
blip_m = blip_region & on_screen & ~wave_m & ~sweep_region & ~sweep_edge
sweep_m = (sweep_region | sweep_edge) & on_screen & ~wave_m & ~blip_m
lit = wave_m | blip_m | sweep_m


def fill(rgb, known):
    """Fills the pixels where `known` is 0 by push-pull: average the known pixels down a pyramid,
    then blend each level back up over the holes."""
    h, w = known.shape
    if h == 1 and w == 1:
        return rgb
    weighted = np.pad(rgb * known[..., None], ((0, h % 2), (0, w % 2), (0, 0)))
    weights = np.pad(known, ((0, h % 2), (0, w % 2)))
    hh, hw = weights.shape[0] // 2, weights.shape[1] // 2
    total = weights.reshape(hh, 2, hw, 2).sum((1, 3))
    coarse = weighted.reshape(hh, 2, hw, 2, 3).sum((1, 3)) / np.maximum(total, 1e-9)[..., None]
    coarse = fill(coarse, np.minimum(total, 1))
    up = np.stack([np.asarray(Image.fromarray(coarse[..., c].astype(np.float32), 'F')
                              .resize((w, h), Image.BILINEAR)) for c in range(3)], -1)
    return rgb * known[..., None] + up * (1 - known[..., None])


def polar_fill(hole, cx, cy, rmax, nr=400, nt=2048, arc=23):
    """The screen under `hole`, rebuilt around its centre: its grid is circles and lines through
    the centre, so each circle is carried on across the hole along its own radius, and the lines
    are put back by angle. Rows a hole covers right round (near the centre) are left to `fill`."""
    rs = (np.arange(nr) + 0.5) * rmax / nr
    ts = np.linspace(-np.pi, np.pi, nt, endpoint=False)
    X = cx + np.cos(ts)[None, :] * rs[:, None]
    Y = cy + np.sin(ts)[None, :] * rs[:, None]
    P = bilinear(C, X, Y).astype(np.float32)
    H = bilinear(hole.astype(np.float64), X, Y) > 0.01
    # Each circle without the lines crossing it: a median along the arc, ignoring the hole.
    masked = np.where(H[..., None], np.nan, P)
    h = arc // 2
    wrapped = np.concatenate([masked[:, -h:], masked, masked[:, :h]], 1)
    windows = np.lib.stride_tricks.sliding_window_view(wrapped, arc, axis=1)
    with warnings.catch_warnings():
        warnings.simplefilter('ignore', RuntimeWarning)   # all-NaN windows, inside the hole
        base = np.nanmedian(windows, -1)
    # The lines: what's left over, by angle, taken over the radii where the angle isn't in the hole.
    resid = np.where(H[..., None], np.nan, P - base)
    with warnings.catch_warnings():
        warnings.simplefilter('ignore', RuntimeWarning)
        lines = np.nanmedian(resid[nr // 8:nr - nr // 16], 0)
    # The lines run right through the centre, so an angle the hole covers takes the opposite one.
    lines = np.where(np.isnan(lines), np.roll(lines, nt // 2, 0), lines)
    lines = np.maximum(np.nan_to_num(lines), 0)
    # Across the hole, each circle is interpolated between the arcs either side of it.
    solved = np.zeros(nr, bool)
    out = P.copy()
    for i in range(nr):
        known = ~H[i] & ~np.isnan(base[i]).any(-1)
        if known.sum() < nt // 8:
            continue
        solved[i] = True
        for c in range(3):
            out[i, :, c] = np.where(H[i], np.interp(ts, ts[known], base[i, known, c], period=2 * np.pi) + lines[:, c],
                                    P[i, :, c])
    # Back onto the canvas, for the hole's pixels.
    rr = np.hypot(xx - cx, yy - cy) / rmax * nr - 0.5
    tt = (np.arctan2(yy - cy, xx - cx) + np.pi) / (2 * np.pi) * nt
    ok = hole & (rr >= 0) & (rr < nr - 1) & solved[np.clip(np.round(rr).astype(int), 0, nr - 1)]
    r0 = np.clip(np.floor(rr).astype(int), 0, nr - 2)
    t0 = np.floor(tt).astype(int) % nt
    fr, ft = (rr - r0)[..., None], (tt - np.floor(tt))[..., None]
    t1 = (t0 + 1) % nt
    sample = (out[r0, t0] * (1 - fr) * (1 - ft) + out[r0, t1] * (1 - fr) * ft
              + out[r0 + 1, t0] * fr * (1 - ft) + out[r0 + 1, t1] * fr * ft)
    line_img = (lines[t0] * (1 - ft) + lines[t1] * ft) * (np.hypot(xx - cx, yy - cy) < rmax)[..., None]
    return np.where(ok[..., None], sample, np.nan), line_img


# The screen's own centre: the gap round it isn't quite concentric with the ring.
ring_px = (R >= gap - 0.5) & (R < gap + 0.5)
A = np.c_[2 * xx[ring_px], 2 * yy[ring_px], np.ones(ring_px.sum())]
(SX, SY, k), *_ = np.linalg.lstsq(A, xx[ring_px] ** 2 + yy[ring_px] ** 2, rcond=None)
SR = np.sqrt(k + SX ** 2 + SY ** 2)

# The screen with nothing lit on it, then never brighter than the artwork, so what's lit is light
# added on top of it.
B, line_img = polar_fill(lit, SX, SY, SR + 4)
rest = lit & np.isnan(B).any(-1)
# Near the centre: smooth fill from the rebuilt screen around it, plus the lines.
known = np.where(np.isnan(B), C, B)
known = np.where((lit & ~rest)[..., None], known, np.where(rest[..., None], 0, C))
B = np.where(rest[..., None], fill(known, (~rest).astype(np.float64)) + line_img, known)
B = np.where(lit[..., None], np.minimum(B, C), C)

# Colour-to-alpha: the least opaque colour that, over B, gives back the artwork.
alpha = np.where(C > B, (C - B) / np.maximum(1 - B, 1e-6), 0).max(-1)
alpha = np.where(lit & (alpha >= 0.04), alpha, 0)
F = np.clip(B + (C - B) / np.maximum(alpha, 1e-6)[..., None], 0, 1)
screen_rgb = np.where((alpha > 0)[..., None], B, C)


def save(name, rgb, a):
    rgba = np.dstack([rgb, a])
    rgba[a <= 0] = 0
    Image.fromarray(np.round(rgba * 255).astype(np.uint8), 'RGBA').save(assets / name, optimize=True)


assets = OUT / 'Assets'
assets.mkdir(parents=True, exist_ok=True)
for old in assets.iterdir():
    old.unlink()
save('bezel.png', C, bezel_alpha)
save('screen.png', screen_rgb, screen_alpha)
save('sweep.png', F, alpha * sweep_m)
save('waveform.png', F, alpha * wave_m)
save('blips.png', F, alpha * blip_m)


def srgb(c):
    return 'srgb:' + ','.join(f'{v:.5f}' for v in (*c, 1))


def layer(name, image, glass=False):
    return {'name': name, 'image-name': image, 'glass': glass}


def group(name, layers, shadow='none'):
    return {'name': name, 'layers': layers,
            'shadow': {'kind': shadow, 'opacity': 0.5},
            'translucency': {'enabled': False, 'value': 0.5}}


icon = {
    # The plate behind the ring: lit from above, darkening towards the bottom.
    'fill': {'linear-gradient': [srgb((0.235, 0.259, 0.302)), srgb((0.051, 0.055, 0.071))]},
    'groups': [
        group('Signals', [layer('Waveform', 'waveform.png'), layer('Blips', 'blips.png')]),
        # Stands in for the shadow the artwork drew around the ring, cut off with the plate.
        group('Bezel', [layer('Bezel', 'bezel.png')], shadow='neutral'),
        group('Screen', [layer('Sweep', 'sweep.png'), layer('Screen', 'screen.png')]),
    ],
    'supported-platforms': {'squares': ['macOS']},
}
(OUT / 'icon.json').write_text(json.dumps(icon, indent=2) + '\n')

# The layers, back to front over the artwork's own plate, should give back the artwork.
comp = C.copy()
for rgb, a in [(screen_rgb, screen_alpha), (F, alpha * sweep_m), (C, bezel_alpha),
               (F, alpha * wave_m), (F, alpha * blip_m)]:
    comp = rgb * a[..., None] + comp * (1 - a[..., None])
err = np.abs(comp - C).max(-1)[R < ring_outer - 2] * 255
print(f'› Wrote {OUT.relative_to(ROOT)}; restacked, the layers are within {err.max():.1f}/255 of the artwork')
if err.max() > 1:
    raise SystemExit('split-icon: the layers no longer add back up to the artwork')
