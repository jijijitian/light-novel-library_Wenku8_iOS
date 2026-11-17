"""Renders the 1024x1024 app icon used by xtool's iconPath."""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def build(path):
    img = Image.new("RGB", (SIZE, SIZE), (36, 40, 74))

    # Diagonal gradient background.
    top = (78, 96, 214)
    bottom = (156, 92, 196)
    gradient = Image.new("RGB", (SIZE, SIZE))
    gd = ImageDraw.Draw(gradient)
    for y in range(SIZE):
        gd.line([(0, y), (SIZE, y)], fill=lerp(top, bottom, y / (SIZE - 1)))
    img = gradient

    # Soft radial highlight in the upper-left.
    glow = Image.new("L", (SIZE, SIZE), 0)
    gdraw = ImageDraw.Draw(glow)
    gdraw.ellipse((-260, -320, 700, 520), fill=120)
    glow = glow.filter(ImageFilter.GaussianBlur(120))
    white = Image.new("RGB", (SIZE, SIZE), (255, 255, 255))
    img = Image.composite(white, img, glow.point(lambda v: int(v * 0.35)))

    draw = ImageDraw.Draw(img, "RGBA")

    # Book body: two facing pages with a subtle spine shadow.
    left, right = 232, 792
    top_y, bottom_y = 268, 772
    spine = (SIZE // 2, top_y + 18)

    left_page = [(left, top_y + 46), (spine[0] - 10, top_y),
                 (spine[0] - 10, bottom_y - 40), (left, bottom_y)]
    right_page = [(spine[0] + 10, top_y), (right, top_y + 46),
                  (right, bottom_y), (spine[0] + 10, bottom_y - 40)]

    draw.polygon(left_page, fill=(255, 255, 255, 236))
    draw.polygon(right_page, fill=(244, 246, 255, 230))

    # Page line detail.
    for i in range(7):
        y = top_y + 110 + i * 58
        inset = 18 + i * 3
        draw.line([(left + 44 + inset, y + 26), (spine[0] - 52, y - 4)], fill=(120, 132, 200, 90), width=8)
        draw.line([(spine[0] + 52, y - 4), (right - 44 - inset, y + 26)], fill=(120, 132, 200, 80), width=8)

    # Spine crease.
    draw.line([(spine[0] - 4, top_y + 2), (spine[0] - 4, bottom_y - 42)], fill=(120, 130, 200, 120), width=6)
    draw.line([(spine[0] + 4, top_y + 2), (spine[0] + 4, bottom_y - 42)], fill=(120, 130, 200, 120), width=6)

    # Cover border to mimic the glass bezel.
    draw.polygon(
        [(left - 12, top_y + 34), (SIZE // 2, top_y - 24),
         (right + 12, top_y + 34), (right + 12, bottom_y + 12),
         (SIZE // 2, bottom_y - 28), (left - 12, bottom_y + 12)],
        outline=(255, 255, 255, 96),
    )

    # Accent spark.
    cx, cy, r = 806, 232, 58
    pts = []
    for index in range(8):
        angle = math.pi / 4 * index
        radius = r if index % 2 == 0 else r * 0.34
        pts.append((cx + math.cos(angle) * radius, cy + math.sin(angle) * radius))
    draw.polygon(pts, fill=(255, 226, 150, 240))

    img = img.filter(ImageFilter.SMOOTH)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    img.save(path, "PNG")
    print(f"wrote {path} ({os.path.getsize(path)} bytes)")


if __name__ == "__main__":
    build(sys.argv[1] if len(sys.argv) > 1 else "Support/AppIcon.png")
