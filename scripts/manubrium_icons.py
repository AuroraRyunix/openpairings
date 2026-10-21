"""Draws Manubrium's app icons from its nine-squares mark.

The mark (brand/marks/manubrium.svg) is a 24x24 grid of nine squares: the
middle column filled, the centre one in the accent, the other six outlined.
Nothing but rectangles, so it is drawn here directly rather than through an
SVG renderer the build machines may not have.

    python scripts/manubrium_icons.py

writes priv/static/images/manubrium/{icon192,icon512,maskable512,touch180}.png.
Run it again only if the mark changes; the PNGs are committed.
"""

from pathlib import Path

from PIL import Image, ImageDraw

PAPER = (247, 246, 243)  # --bg, light theme
INK = (36, 33, 28)  # --text, light theme
ACCENT = (122, 46, 30)  # the mark's own accent (#7a2e1e)

# (x, y, size, filled?, accent?) in the mark's 24-unit grid, as in the SVG.
SQUARES = [
    (2.6, 2.6, 4.8, False, False),
    (9, 2, 6, True, False),
    (16.6, 2.6, 4.8, False, False),
    (2.6, 9.6, 4.8, False, False),
    (9, 9, 6, True, True),
    (16.6, 9.6, 4.8, False, False),
    (2.6, 16.6, 4.8, False, False),
    (9, 16, 6, True, False),
    (16.6, 16.6, 4.8, False, False),
]
STROKE = 1.2

OUT = Path(__file__).resolve().parent.parent / "priv" / "static" / "images" / "manubrium"


def draw(size, mark_fraction, rounded):
    # Supersample, then shrink: Pillow does not antialias rectangle edges.
    scale = 4
    big = size * scale
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    if rounded:
        d.rounded_rectangle([0, 0, big - 1, big - 1], radius=big * 0.22, fill=PAPER)
    else:
        d.rectangle([0, 0, big - 1, big - 1], fill=PAPER)

    unit = big * mark_fraction / 24
    offset = (big - unit * 24) / 2

    for x, y, s, filled, accent in SQUARES:
        if filled:
            box = [offset + x * unit, offset + y * unit, offset + (x + s) * unit, offset + (y + s) * unit]
            d.rectangle(box, fill=ACCENT if accent else INK)
        else:
            # The SVG strokes centred on the edge; widen the box by half a
            # stroke so the outer edge lands where the SVG's does.
            h = STROKE / 2
            box = [
                offset + (x - h) * unit,
                offset + (y - h) * unit,
                offset + (x + s + h) * unit,
                offset + (y + s + h) * unit,
            ]
            d.rectangle(box, outline=INK, width=max(1, round(STROKE * unit)))

    return img.resize((size, size), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    draw(192, 0.78, True).save(OUT / "icon192.png", optimize=True)
    draw(512, 0.78, True).save(OUT / "icon512.png", optimize=True)
    # Maskable: full bleed, and the mark inside the 80% safe circle.
    draw(512, 0.52, False).save(OUT / "maskable512.png", optimize=True)
    # iOS rounds the corners itself and wants no transparency.
    draw(180, 0.7, False).convert("RGB").save(OUT / "touch180.png", optimize=True)


if __name__ == "__main__":
    main()
