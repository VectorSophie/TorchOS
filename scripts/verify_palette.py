#!/usr/bin/env python3
"""Sample specific pixels from a screenshot and assert they match the locked
TorchOS palette within tolerance. Companion to the grim screenshots taken
during Group A palette verification — sample points are picked by eye
against each real screenshot since UI layout isn't fixed here, so they're
passed as arguments rather than hardcoded.

Usage: python3 scripts/verify_palette.py shot.png x1,y1,#ff4500 x2,y2,#2b0a00 ...
"""
import sys
from PIL import Image

TOLERANCE = 12  # sum of per-channel abs delta — same threshold as
                 # scripts/branding/generate_wallpaper.py's check()


def hex_to_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    img = Image.open(sys.argv[1]).convert("RGB")
    failures = []
    for spec in sys.argv[2:]:
        x, y, hexval = spec.split(",")
        x, y = int(x), int(y)
        expect = hex_to_rgb(hexval)
        got = img.getpixel((x, y))
        delta = sum(abs(a - b) for a, b in zip(got, expect))
        status = "OK" if delta <= TOLERANCE else "FAIL"
        if status == "FAIL":
            failures.append(spec)
        print(f"({x},{y}) expect {hexval} got {got} delta={delta} {status}")
    if failures:
        print(f"\n{len(failures)} sample(s) failed: {failures}")
        sys.exit(1)
    print("\nall samples within tolerance")


if __name__ == "__main__":
    main()
