#!/usr/bin/env python3
"""Draws the DropUp app icon and writes App/DropUp/Assets.xcassets/AppIcon.appiconset.

    pip install pillow
    python3 scripts/make-icon.py

The artwork is the menubar glyph (an up arrow over a tray) in white on a blue rounded square.
Replace the PNGs with your own artwork any time; the asset catalog just needs the same file names.
"""
import json
import os

from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), "..", "App", "DropUp", "Assets.xcassets", "AppIcon.appiconset")
SCALE = 4  # supersample, then shrink for smooth edges
CANVAS = 1024 * SCALE


def squircle_mask(size, inset, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([inset, inset, size - inset, size - inset], radius=radius, fill=255)
    return mask


def gradient(size, top, bottom):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        color = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(size):
            px[x, y] = color
    return img


def draw_glyph(draw, unit, ox, oy, width):
    """The 16 x 16 menubar artwork scaled by `unit`, offset by (ox, oy)."""
    def p(x, y):
        return (ox + x * unit, oy + y * unit)

    def line(points):
        draw.line([p(*pt) for pt in points], fill="white", width=width, joint="curve")
        for pt in (points[0], points[-1]):
            cx, cy = p(*pt)
            draw.ellipse([cx - width / 2, cy - width / 2, cx + width / 2, cy + width / 2], fill="white")

    line([(8, 10), (8, 2.5)])
    line([(4.75, 5.75), (8, 2.5), (11.25, 5.75)])
    line([(2.25, 10), (2.25, 12.25), (3.75, 13.75), (12.25, 13.75), (13.75, 12.25), (13.75, 10)])


def render():
    inset = 100 * SCALE
    body = CANVAS - 2 * inset
    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    base = gradient(CANVAS, (66, 150, 255), (10, 100, 216)).convert("RGBA")
    icon.paste(base, (0, 0), squircle_mask(CANVAS, inset, int(body * 0.225)))
    draw = ImageDraw.Draw(icon)
    unit = body * 0.62 / 16
    glyph = 16 * unit
    draw_glyph(draw, unit, (CANVAS - glyph) / 2, (CANVAS - glyph) / 2 + body * 0.015, int(unit * 1.9))
    return icon


def main():
    os.makedirs(OUT, exist_ok=True)
    master = render()
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            master.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(OUT, name))
            images.append({"idiom": "mac", "size": f"{points}x{points}", "scale": f"{scale}x", "filename": name})
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
    with open(os.path.join(OUT, "..", "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)


if __name__ == "__main__":
    main()
