#!/usr/bin/env python3
"""Generate AppIcon.icns for the app bundle.

Pure stdlib: a minimal PNG writer plus signed-distance-field shapes, so there is
no Pillow dependency. Renders once at 1024px with analytic antialiasing and lets
sips produce the smaller sizes, which is far quicker than supersampling in
Python at every size.

Usage: make-icon.py <output.icns>
"""
import math
import os
import struct
import subprocess
import sys
import tempfile
import zlib

SIZE = 1024


def write_png(path, w, h, pixels):
    """pixels: bytearray of w*h*4 RGBA."""
    raw = b"".join(
        b"\x00" + bytes(pixels[y * w * 4:(y + 1) * w * 4]) for y in range(h)
    )

    def chunk(tag, data):
        body = tag + data
        return (struct.pack(">I", len(data)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


def sd_rounded_rect(px, py, hw, hh, r):
    qx, qy = abs(px) - hw + r, abs(py) - hh + r
    return (min(max(qx, qy), 0.0)
            + math.hypot(max(qx, 0.0), max(qy, 0.0)) - r)


def coverage(d, aa):
    """Distance -> alpha, smooth across roughly one pixel."""
    return min(max(0.5 - d / aa, 0.0), 1.0)


def over(dst, src, a):
    """src over dst with alpha a; both are (r,g,b) 0-255."""
    return tuple(s * a + d * (1.0 - a) for s, d in zip(src, dst))


def render():
    px = bytearray(SIZE * SIZE * 4)
    aa = 2.0 / SIZE          # ~1px, in normalized units

    # macOS icons sit inside the canvas rather than filling it.
    plate_h = 0.402          # half-extent of the rounded plate
    plate_r = 0.225          # Apple-ish squircle corner radius

    for y in range(SIZE):
        ny = (y + 0.5) / SIZE - 0.5      # -0.5 .. 0.5
        row = y * SIZE * 4
        # vertical gradient for the plate
        t = (ny + plate_h) / (2 * plate_h)
        t = min(max(t, 0.0), 1.0)
        plate = (43 + (16 - 43) * t, 52 + (20 - 52) * t, 64 + (27 - 64) * t)

        for x in range(SIZE):
            nx = (x + 0.5) / SIZE - 0.5

            a_plate = coverage(sd_rounded_rect(nx, ny, plate_h, plate_h, plate_r), aa)
            if a_plate <= 0.0:
                continue

            col = plate
            r = math.hypot(nx, ny)

            # Outer lens ring: a light metallic annulus.
            a_ring = coverage(r - 0.300, aa) * (1.0 - coverage(r - 0.238, aa))
            if a_ring > 0.0:
                # brighter toward the upper-left for a lit look
                lit = 0.5 - (nx + ny) * 0.9
                lit = min(max(lit, 0.0), 1.0)
                ring = (120 + 95 * lit, 140 + 95 * lit, 165 + 85 * lit)
                col = over(col, ring, a_ring)

            # Glass.
            a_glass = coverage(r - 0.238, aa)
            if a_glass > 0.0:
                k = min(r / 0.238, 1.0)
                glass = (10 + 26 * k, 14 + 30 * k, 21 + 38 * k)
                col = over(col, glass, a_glass)

            # Pupil: the dark centre of the glass.
            a_pupil = coverage(r - 0.105, aa)
            if a_pupil > 0.0:
                col = over(col, (7, 10, 15), a_pupil * 0.9)

            # Specular glint, upper-left. A soft quadratic falloff rather than a
            # hard-edged disc, which otherwise reads as a second pupil.
            gr = math.hypot(nx + 0.088, ny + 0.095)
            if gr < 0.105:
                f = 1.0 - gr / 0.105
                col = over(col, (238, 246, 255), f * f * 0.62)

            i = row + x * 4
            px[i] = int(col[0] + 0.5)
            px[i + 1] = int(col[1] + 0.5)
            px[i + 2] = int(col[2] + 0.5)
            px[i + 3] = int(a_plate * 255 + 0.5)

    return px


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: make-icon.py <output.icns>")
    out = sys.argv[1]

    pixels = render()
    with tempfile.TemporaryDirectory() as tmp:
        base = os.path.join(tmp, "base.png")
        write_png(base, SIZE, SIZE, pixels)

        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.mkdir(iconset)
        # (pixel size, filename) pairs iconutil expects
        wanted = [
            (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
        ]
        for size, name in wanted:
            subprocess.run(
                ["sips", "-z", str(size), str(size), base,
                 "--out", os.path.join(iconset, name)],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )

        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)


if __name__ == "__main__":
    main()
