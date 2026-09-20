#!/usr/bin/env python3
"""Generate TorchOS desktop wallpapers (dark + light) from torch-mark.png.

Base look stays what the owner locked in on 2026-08-26 (flat bg + centered
mark) — this just adds a subtle ember/gradient texture on top, per the
2026-08-26 follow-up request. Kept in the repo (unlike the one-off session
scripts that made torch-mark.png itself) since wallpaper tweaks are a
recurring need.

Usage: python3 scripts/branding/generate_wallpaper.py [outdir]
"""
import math
import random
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

W, H = 1920, 1080
MARK_PATH = Path(__file__).resolve().parent.parent.parent / "assets" / "branding" / "torch-mark.png"
SEED = 20260826  # deterministic — rerun reproduces the same embers


def radial_glow(size, color, max_alpha, radius_frac, scale=8):
    """Soft radial gradient, `color` at center fading to transparent.

    Built at 1/scale resolution and upscaled with bicubic resampling —
    doing this at full res makes the (1 - d)**2 falloff visibly band into
    rings once quantized to 8-bit alpha (the gradient is too subtle for
    that many discrete steps to look continuous); upscaling interpolates
    past the banding instead.
    """
    w, h = size
    sw, sh = w // scale, h // scale
    cx, cy = sw / 2, sh / 2
    radius = max(sw, sh) * radius_frac
    small = Image.new("RGBA", (sw, sh), (0, 0, 0, 0))
    px = small.load()
    for y in range(sh):
        dy = (y - cy) ** 2
        for x in range(sw):
            d = math.sqrt((x - cx) ** 2 + dy) / radius
            a = int(max_alpha * (1 - d) ** 2) if d < 1 else 0
            px[x, y] = (*color, a)
    return small.resize(size, Image.BICUBIC)


def wavy_shimmer(size, color, amplitude, seed):
    """Very low-amplitude horizontal bands, like a barely-there sunset
    gradient — two overlaid sine periods so it doesn't read as a repeating
    stripe. Computed one value per row (not per-pixel, it's a horizontal
    band not a diagonal ripple) then resized back up so the amplitude,
    which is only a few levels, doesn't quantize into visible steps."""
    rng = random.Random(seed)
    w, h = size
    sh = h // 4
    phase1, phase2 = rng.uniform(0, math.tau), rng.uniform(0, math.tau)
    mask = Image.new("L", (1, sh), 0)
    mpx = mask.load()
    for y in range(sh):
        wave = math.sin(y / 35.0 + phase1) * 0.6 + math.sin(y / 14.0 + phase2) * 0.4
        mpx[0, y] = int(abs(wave) * amplitude)
    mask = mask.resize((w, h), Image.BICUBIC)
    tint = Image.new("RGBA", size, (*color, 0))
    tint.putalpha(mask)
    return tint


def embers(size, seed, warm_colors, count, alpha_range, core_range, blur_range):
    """Small blurred glow dots, biased toward the lower portion of the frame
    (embers drifting up from a fire), avoiding a dead-center cluster."""
    rng = random.Random(seed)
    w, h = size
    cx, cy = w / 2, h / 2
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    for _ in range(count):
        while True:
            x = rng.uniform(0, w)
            y = h * (1 - rng.random() ** 1.8)  # skewed toward the bottom
            if math.hypot(x - cx, y - cy) > 70:  # keep clear of the mark itself
                break
        color = rng.choice(warm_colors)
        alpha = rng.randint(*alpha_range)
        core = rng.uniform(*core_range)
        blur = rng.uniform(*blur_range)
        dot = Image.new("RGBA", size, (0, 0, 0, 0))
        d = ImageDraw.Draw(dot)
        d.ellipse([x - core, y - core, x + core, y + core], fill=(*color, alpha))
        dot = dot.filter(ImageFilter.GaussianBlur(blur))
        layer = Image.alpha_composite(layer, dot)
    return layer


def build(dark: bool) -> Image.Image:
    base_color = (0, 0, 0) if dark else (255, 255, 255)
    canvas = Image.new("RGBA", (W, H), (*base_color, 255))

    if dark:
        glow = radial_glow((W, H), (43, 10, 0), max_alpha=90, radius_frac=0.42)  # #2b0a00 ember
        shimmer = wavy_shimmer((W, H), (255, 106, 0), amplitude=4, seed=SEED)
        ember_colors = [(255, 69, 0), (255, 106, 0), (204, 85, 0)]
        ember_layer = embers((W, H), SEED, ember_colors, count=22,
                              alpha_range=(35, 90), core_range=(1.5, 4.0),
                              blur_range=(2.5, 6.0))
    else:
        glow = radial_glow((W, H), (255, 218, 185), max_alpha=70, radius_frac=0.42)  # warm cream
        shimmer = wavy_shimmer((W, H), (255, 160, 90), amplitude=3, seed=SEED)
        ember_colors = [(255, 200, 150), (255, 180, 120)]
        ember_layer = embers((W, H), SEED, ember_colors, count=16,
                              alpha_range=(18, 40), core_range=(2.0, 4.5),
                              blur_range=(3.5, 7.0))

    canvas = Image.alpha_composite(canvas, glow)
    canvas = Image.alpha_composite(canvas, shimmer)
    canvas = Image.alpha_composite(canvas, ember_layer)

    mark = Image.open(MARK_PATH).convert("RGBA")
    if not dark:
        # torch-mark.png is a white silhouette — recolor to black for the light wallpaper
        r, g, b, a = mark.split()
        mark = Image.merge("RGBA", (Image.new("L", mark.size, 0),) * 3 + (a,))
    mx = (W - mark.width) // 2
    my = (H - mark.height) // 2
    canvas.alpha_composite(mark, (mx, my))

    return canvas.convert("RGB")


def check(img: Image.Image, expect_bg):
    """Sanity check, not a full test suite: right size, corners are close to
    background (the shimmer band reaches the edges by design, but nothing
    else should — a stray bright ember or full-strength glow there would
    mean the placement/radius logic broke), and the image isn't just a flat
    fill (would catch a compositing no-op)."""
    assert img.size == (W, H), f"wrong size: {img.size}"
    for corner in [(5, 5), (W - 5, 5), (5, H - 5), (W - 5, H - 5)]:
        got = img.getpixel(corner)
        delta = sum(abs(a - b) for a, b in zip(got, expect_bg))
        assert delta <= 12, f"corner {corner} too far from background {expect_bg}: got {got}"
    flat = Image.new("RGB", img.size, expect_bg)
    bbox = ImageChops.difference(img, flat).getbbox()
    assert bbox is not None, "output is a flat fill — glow/embers didn't composite"


def main():
    outdir = Path(sys.argv[1]) if len(sys.argv) > 1 else MARK_PATH.parent
    outdir.mkdir(parents=True, exist_ok=True)
    dark_img = build(dark=True)
    light_img = build(dark=False)
    check(dark_img, expect_bg=(0, 0, 0))
    check(light_img, expect_bg=(255, 255, 255))
    dark_img.save(outdir / "wallpaper.png")
    light_img.save(outdir / "wallpaper-light.png")
    print(f"wrote {outdir/'wallpaper.png'} and {outdir/'wallpaper-light.png'}")


if __name__ == "__main__":
    main()
