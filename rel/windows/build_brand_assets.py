"""Builds the Windows installer's icon, splash and MSI dialog art from the
site's brand mark.

Run when the mark changes; the outputs are committed beside this script so a
build machine needs no image tooling:

    py -3 rel/windows/build_brand_assets.py

Needs Pillow (`py -3 -m pip install pillow`) and nothing else.

## The MSI images

`vpk pack --msi` takes `--msiBanner` and `--msiLogo`: WiX's "Bitmap" dialog
controls, which is why they must be `.bmp` (Velopack's own docs say so under
`--msiBanner`/`--msiLogo` - confirmed against the .wxs template embedded in
`vpk` itself, which wires both straight into `<Binary SourceFile="...">`
elements consumed by `Type="Bitmap"` controls: Windows Installer's classic
dialog art, not a modern image control that would tolerate PNG).

Their layout is fixed by that same embedded template, not chosen here:

  * The banner (493x58) is `BannerBitmap`, full width and top-aligned, on
    every wizard page except Welcome/Exit.
  * The logo (493x312) is `Bitmap`, the FULL background of the Welcome and
    Exit pages - the wizard's Title and Description text is drawn
    transparently on top of it, left edge at dialog-unit x=135 of 370, i.e.
    pixel 180 of 493 (`135/370 * 493`). That text has no colour of its own
    in the template (no `TextStyle` colour, no per-control override), so it
    renders in the Windows default control text colour - black. A dark
    image under it, past x=180, would make it unreadable.

  So the logo's ink-dark column, carrying the mark, ends at x=164 - WiX's
  own convention for this bitmap - leaving a white gutter before the text
  at x=180. The banner works the same way round: each page's Title and
  Description are drawn over its left side (x=20 and x=33), so that side
  stays white and the mark sits at the right edge. Both used to put ink
  exactly where WiX puts text.
  This is the same reasoning as the .ico's white-fill-plus-dark-stroke mark,
  applied in the other direction: know what the mark sits on, don't fight it.

## What the mark is, and why it is drawn here rather than loaded

The brand is the emblem on <https://openpairings.zerotwo.cloud/>: two wings
flanking a sky-blue orb, an inline SVG on a 64x48 viewBox. It is inline in
the page rather than a file, so there is no asset to convert - and it is
three shapes (two quadratic-bezier paths and a circle with a linear
gradient), which is less code to draw directly than it would take to add an
SVG rasteriser to this project's toolchain.

`priv/static/images/logo.png` is NOT this mark. It is an older ornate
illustration, and it is not what the site shows.

## Two colour decisions

The wings are `fill="currentColor"` in the page, so on the site's dark hero
they inherit near-white. An icon has no such context: it sits on the
taskbar, on Explorer's white list background, and on whatever wallpaper
somebody chose. White fill with the mark's own dark stroke reads on all
three - the outline is what stops the wings disappearing into a white
background, and it is in the original rather than added here.

The orb keeps its gradient exactly (`#38bdf8` to `#0284c7`, corner to
corner). It is the piece people will recognise at 16 pixels, where the wings
are barely three pixels of white.

## Why there is no simplified small size

An .ico usually carries a reduced drawing for its small sizes, because a
lockup with a wordmark turns to mush at 16px. This mark has no wordmark and
three shapes, so the same geometry works the whole way down. Every size is
rendered from the vector at its own resolution rather than resampled from
one bitmap.

## Why the .ico container is written by hand

`Image.save(format="ICO", sizes=[...])` takes ONE image and downsamples it
for each requested size, silently discarding prepared per-size frames. Since
each size here is rendered at its own scale, the container is assembled
directly: a 6-byte header, a 16-byte directory entry per image, then PNG
payloads, which Windows accepts at every size.
"""

import io
import os
import struct
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("Pillow is required: py -3 -m pip install pillow")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

# The mark's own values, read off the page rather than eyeballed.
ORB_FROM = (0x38, 0xBD, 0xF8)
ORB_TO = (0x02, 0x84, 0xC7)
STROKE = (0x0F, 0x17, 0x2A)
WING = (0xFF, 0xFF, 0xFF)

# The site's dark ground and its muted text, for the splash.
INK = (0x0B, 0x11, 0x20)
TEXT = (0xE2, 0xE8, 0xF0)
MUTED = (0x94, 0xA3, 0xB8)

VIEW_W, VIEW_H = 64, 48
ICON_SIZES = [16, 24, 32, 48, 64, 128, 256]

# Drawn this many times larger and then reduced - the cheap way to clean
# edges without writing an antialiasing rasteriser.
SUPERSAMPLE = 8

# M22,18 Q10,10 1,14 Q8,22 10,30 Q16,32 22,30 Q26,26 22,18 Z
WING_LEFT = [
    (22, 18),
    ((10, 10), (1, 14)),
    ((8, 22), (10, 30)),
    ((16, 32), (22, 30)),
    ((26, 26), (22, 18)),
]
WING_RIGHT = [
    (VIEW_W - WING_LEFT[0][0], WING_LEFT[0][1]),
] + [
    tuple((VIEW_W - x, y) for (x, y) in seg) for seg in WING_LEFT[1:]
]


def _flatten(spec, scale, steps=48):
    """A wing path flattened to a polygon, `scale` pixels per view unit."""
    points = [spec[0]]

    for control, end in spec[1:]:
        p0 = points[-1]
        for i in range(1, steps + 1):
            t = i / steps
            u = 1 - t
            points.append(
                (
                    u * u * p0[0] + 2 * u * t * control[0] + t * t * end[0],
                    u * u * p0[1] + 2 * u * t * control[1] + t * t * end[1],
                )
            )

    return [(x * scale, y * scale) for (x, y) in points]


def _orb(scale):
    """The circle, filled with the mark's corner-to-corner gradient."""
    d = max(2, int(28 * scale))
    tile = Image.new("RGBA", (d, d), (0, 0, 0, 0))
    px = tile.load()

    for y in range(d):
        for x in range(d):
            # x1,y1 0% -> x2,y2 100%: the gradient runs along the diagonal.
            t = (x + y) / (2 * (d - 1))
            px[x, y] = (
                round(ORB_FROM[0] + (ORB_TO[0] - ORB_FROM[0]) * t),
                round(ORB_FROM[1] + (ORB_TO[1] - ORB_FROM[1]) * t),
                round(ORB_FROM[2] + (ORB_TO[2] - ORB_FROM[2]) * t),
                255,
            )

    mask = Image.new("L", (d, d), 0)
    ImageDraw.Draw(mask).ellipse([(0, 0), (d - 1, d - 1)], fill=255)
    tile.putalpha(mask)
    return tile


def render_mark(size):
    """The mark at `size` x `size`, centred, with transparent margins."""
    scale = size * SUPERSAMPLE / VIEW_W
    canvas = Image.new("RGBA", (int(VIEW_W * scale), int(VIEW_H * scale)), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    for spec in (WING_LEFT, WING_RIGHT):
        poly = _flatten(spec, scale)
        draw.polygon(poly, fill=WING + (255,))
        draw.line(
            poly + [poly[0]],
            fill=STROKE + (255,),
            width=max(1, round(2.2 * scale)),
            joint="curve",
        )

    orb = _orb(scale)
    ox, oy = round(18 * scale), round(10 * scale)
    canvas.alpha_composite(orb, (ox, oy))
    ImageDraw.Draw(canvas).ellipse(
        [(ox, oy), (ox + orb.width - 1, oy + orb.height - 1)],
        outline=STROKE + (255,),
        width=max(1, round(2.5 * scale)),
    )

    shrunk = canvas.resize((size, max(1, round(size * VIEW_H / VIEW_W))), Image.LANCZOS)

    square = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    square.alpha_composite(shrunk, (0, (size - shrunk.height) // 2))
    return square


def build_icon(out_path):
    payloads = []
    for size in ICON_SIZES:
        buf = io.BytesIO()
        render_mark(size).save(buf, format="PNG")
        payloads.append(buf.getvalue())

    header = struct.pack("<HHH", 0, 1, len(ICON_SIZES))
    offset = len(header) + 16 * len(ICON_SIZES)

    directory = b""
    for size, payload in zip(ICON_SIZES, payloads):
        # 256 is stored as 0: the field is one byte and 256 does not fit.
        dim = 0 if size == 256 else size
        directory += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(payload), offset)
        offset += len(payload)

    with open(out_path, "wb") as f:
        f.write(header + directory + b"".join(payloads))

    return out_path


def _font(names, size):
    for name in names:
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def build_splash(out_path):
    """The image Velopack shows while it unpacks.

    On screen for a few seconds, and its only job is to say the right thing
    is installing: the mark, the name, one line of what it is.
    """
    width, height = 500, 300
    canvas = Image.new("RGBA", (width, height), INK + (255,))
    draw = ImageDraw.Draw(canvas)

    mark = render_mark(150)
    canvas.alpha_composite(mark, ((width - mark.width) // 2, 34))

    title_font = _font(["segoeuib.ttf", "seguisb.ttf", "arialbd.ttf"], 30)
    sub_font = _font(["segoeui.ttf", "arial.ttf"], 15)

    title, sub = "OpenPairings", "Chess tournament manager"

    tw = draw.textlength(title, font=title_font)
    draw.text(((width - tw) / 2, 194), title, font=title_font, fill=TEXT + (255,))

    sw = draw.textlength(sub, font=sub_font)
    draw.text(((width - sw) / 2, 236), sub, font=sub_font, fill=MUTED + (255,))

    canvas.convert("RGB").save(out_path, format="PNG")
    return out_path


def build_msi_banner(out_path):
    """The 493x58 strip WiX shows across the top of every MSI wizard page
    except Welcome/Exit.

    WiX draws each page's own title and description over the LEFT of this
    strip, in its default black: the title from x=20, the description from
    x=33 (15 and 25 of the dialog's 370 units, at 493/370 px per unit). So
    everything there stays plain white, and the mark sits in the space WiX
    leaves free at the right edge. No wordmark: the page title already says
    what is being installed, and ours was the text that collided with it.

    No bottom rule either. WiX draws its own line under the banner
    (`BannerLine`), and a stripe of ours sat on top of it.
    """
    width, height = 493, 58
    canvas = Image.new("RGBA", (width, height), (255, 255, 255, 255))

    mark = render_mark(44)
    canvas.alpha_composite(mark, (width - mark.width - 12, (height - mark.height) // 2))

    canvas.convert("RGB").save(out_path, format="BMP")
    return out_path


def build_msi_logo(out_path):
    """The 493x312 background of the MSI's Welcome/Exit pages.

    WiX draws these pages' title and body from x=180 (135 of the dialog's
    370 units), in its default black. The ink-dark column carrying the mark
    therefore ends at x=164 - WiX's own convention for this bitmap - leaving
    a white gutter before the first letter. It used to end at exactly 180,
    which put the title's first characters on the dark edge.
    """
    width, height = 493, 312
    left_w = 164
    canvas = Image.new("RGBA", (width, height), (255, 255, 255, 255))
    draw = ImageDraw.Draw(canvas)
    draw.rectangle([0, 0, left_w - 1, height - 1], fill=INK + (255,))

    mark = render_mark(124)
    mx = (left_w - mark.width) // 2
    my = 96
    canvas.alpha_composite(mark, (mx, my))

    title_font = _font(["segoeuib.ttf", "seguisb.ttf", "arialbd.ttf"], 20)
    title = "OpenPairings"
    tw = draw.textlength(title, font=title_font)
    draw.text(
        (max(8, (left_w - tw) / 2), my + mark.height + 20),
        title,
        font=title_font,
        fill=TEXT + (255,),
    )

    canvas.convert("RGB").save(out_path, format="BMP")
    return out_path


def main():
    icon = build_icon(os.path.join(HERE, "OpenPairings.ico"))
    splash = build_splash(os.path.join(HERE, "splash.png"))
    msi_banner = build_msi_banner(os.path.join(HERE, "msi_banner.bmp"))
    msi_logo = build_msi_logo(os.path.join(HERE, "msi_logo.bmp"))

    for path in (icon, splash, msi_banner, msi_logo):
        print("wrote %s (%d bytes)" % (os.path.relpath(path, ROOT), os.path.getsize(path)))


if __name__ == "__main__":
    main()
