"""Draws the taskbar / Dock icon: nine squares on a white tile, seven of them
an arrow pointing at the top-left corner, its tip yellow.

    py -3 rel/build_taskbar_icon.py

Writes rel/windows/OpenPairings.ico (the launcher's icon, so the taskbar's)
and rel/macos/OpenPairings-icon.png (the Dock's, turned into an .icns by
build_app.sh). Nothing else: the site, the favicon, the splash and the
installer art keep the winged orb. Alnasl's icon is the same grid with its
arrow pointing the other way; the two are meant to sit side by side.

The small sizes are drawn on whole pixels rather than shrunk from a big
drawing - a one-pixel gap between squares survives that, and does not
survive a downsample. Needs Pillow.
"""

import io
import os
import struct

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))

BLUE = (0x1F, 0x5F, 0xAE, 255)
YELLOW = (0xF2, 0xB7, 0x05, 255)
PAPER = (255, 255, 255, 255)
EDGE = (0xD3, 0xD1, 0xC7, 255)

# Row by row; None is an empty square.
ARROW = [YELLOW, BLUE, BLUE,
         BLUE, BLUE, None,
         BLUE, None, BLUE]

ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]

# (margin, cell, gap) in whole pixels, for the sizes too small to shrink to.
PIXEL_GRIDS = {16: (1, 4, 1), 24: (2, 6, 1), 32: (3, 8, 1), 48: (5, 12, 2)}


def tile(size):
    """The white tile with the grid, `size` pixels square, edge to edge."""
    if size in PIXEL_GRIDS:
        margin, cell, gap = PIXEL_GRIDS[size]
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        radius = max(2, size // 6)
        d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=PAPER,
                            outline=EDGE if size >= 32 else None)
        for i, colour in enumerate(ARROW):
            if colour:
                x = margin + (i % 3) * (cell + gap)
                y = margin + (i // 3) * (cell + gap)
                d.rectangle([x, y, x + cell - 1, y + cell - 1], fill=colour)
        return img

    s = 8
    big = size * s
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    u = big / 100
    d.rounded_rectangle([u, u, big - u, big - u], radius=18 * u, fill=PAPER,
                        outline=EDGE, width=max(1, round(2 * u)))
    for i, colour in enumerate(ARROW):
        if colour:
            x = (12 + (i % 3) * 26.5) * u
            y = (12 + (i // 3) * 26.5) * u
            d.rounded_rectangle([x, y, x + 23.5 * u, y + 23.5 * u], radius=2 * u, fill=colour)
    return img.resize((size, size), Image.LANCZOS)


def write_ico(path):
    payloads = []
    for size in ICO_SIZES:
        buf = io.BytesIO()
        tile(size).save(buf, format="PNG")
        payloads.append(buf.getvalue())
    header = struct.pack("<HHH", 0, 1, len(ICO_SIZES))
    offset = len(header) + 16 * len(ICO_SIZES)
    directory = b""
    for size, payload in zip(ICO_SIZES, payloads):
        dim = 0 if size == 256 else size  # one byte; 256 is spelled 0
        directory += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(payload), offset)
        offset += len(payload)
    with open(path, "wb") as f:
        f.write(header + directory + b"".join(payloads))


def write_mac_png(path):
    # macOS draws its icons inside a margin (824 of 1024); a tile that fills
    # the canvas looks a size too big beside everybody else's in the Dock.
    canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    canvas.paste(tile(824), (100, 100))
    canvas.save(path)


def main():
    ico = os.path.join(HERE, "windows", "OpenPairings.ico")
    png = os.path.join(HERE, "macos", "OpenPairings-icon.png")
    write_ico(ico)
    write_mac_png(png)
    for p in (ico, png):
        print("wrote %s (%d bytes)" % (os.path.relpath(p, os.path.dirname(HERE)), os.path.getsize(p)))


if __name__ == "__main__":
    main()
