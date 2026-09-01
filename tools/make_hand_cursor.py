"""Turn the transparent black-outline hand PNG into opaque white cursor files.

The source artwork is line art: only the strokes carry alpha, so the hand reads as
see-through. Here the enclosed area is flood filled to make the hand solid, the
palette is recoloured to white, and the result is written as classic 24bpp
cursors/icons (XOR bitmap + 1bpp AND mask), the format Windows OLE picture
loading - and therefore VBA's LoadPicture - handles on every version.
"""

from __future__ import annotations

import struct
from collections import deque
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets" / "cursors" / "hand-source.png"
OUT_DIR = ROOT / "assets" / "cursors"

SIZE = 32
OUTLINE_ALPHA = 96  # strokes at or above this stay as the dark outline
HOTSPOT = (12, 2)  # tip of the raised index finger

WHITE = (255, 255, 255)
OUTLINE = (0, 0, 0)
TRANSPARENT = None


def load_alpha(path: Path) -> list[list[int]]:
    img = Image.open(path).convert("RGBA")
    if img.size != (SIZE, SIZE):
        img = img.resize((SIZE, SIZE), Image.LANCZOS)
    alpha = img.getchannel("A")
    return [[alpha.getpixel((x, y)) for x in range(SIZE)] for y in range(SIZE)]


def outside_mask(alpha: list[list[int]]) -> list[list[bool]]:
    """Flood fill the fully transparent background inwards from the border.

    Anything transparent that the fill cannot reach is enclosed by the artwork,
    i.e. the inside of the hand.
    """
    outside = [[False] * SIZE for _ in range(SIZE)]
    queue: deque[tuple[int, int]] = deque()
    for x in range(SIZE):
        for y in (0, SIZE - 1):
            queue.append((x, y))
    for y in range(SIZE):
        for x in (0, SIZE - 1):
            queue.append((x, y))
    while queue:
        x, y = queue.popleft()
        if not (0 <= x < SIZE and 0 <= y < SIZE) or outside[y][x] or alpha[y][x] > 0:
            continue
        outside[y][x] = True
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    return outside


def build_pixels(alpha, outside, *, silhouette: bool):
    """Map every pixel to an opaque colour or to transparent."""
    pixels = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            a = alpha[y][x]
            inside = a == 0 and not outside[y][x]
            if a == 0 and not inside:
                row.append(TRANSPARENT)
            elif silhouette or a < OUTLINE_ALPHA:
                row.append(WHITE)
            else:
                row.append(OUTLINE)
        pixels.append(row)
    return pixels


def encode_dib(pixels) -> bytes:
    """24bpp bottom-up XOR bitmap followed by the 1bpp AND transparency mask."""
    xor = bytearray()
    and_mask = bytearray()
    for y in reversed(range(SIZE)):
        bits = 0
        for x in range(SIZE):
            px = pixels[y][x]
            r, g, b = px if px is not None else (0, 0, 0)
            xor += bytes((b, g, r))
            if px is None:  # 1 in the AND mask leaves the screen untouched
                bits |= 1 << (SIZE - 1 - x)
        and_mask += struct.pack(">I", bits)

    header = struct.pack(
        "<IiiHHIIiiII",
        40,  # biSize
        SIZE,  # biWidth
        SIZE * 2,  # biHeight covers XOR + AND
        1,  # biPlanes
        24,  # biBitCount
        0,  # BI_RGB
        len(xor) + len(and_mask),
        0,
        0,
        0,
        0,
    )
    return header + bytes(xor) + bytes(and_mask)


def write_container(path: Path, dib: bytes, *, cursor: bool) -> None:
    if cursor:
        field_a, field_b = HOTSPOT
    else:
        field_a, field_b = 1, 24  # icons store planes / bit count here
    data = struct.pack("<HHH", 0, 2 if cursor else 1, 1)
    data += struct.pack(
        "<BBBBHHII", SIZE, SIZE, 0, 0, field_a, field_b, len(dib), 22
    )
    path.write_bytes(data + dib)


def write_preview(path: Path, pixels) -> None:
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    for y in range(SIZE):
        for x in range(SIZE):
            px = pixels[y][x]
            if px is not None:
                img.putpixel((x, y), px + (255,))
    img.save(path)


def main() -> None:
    alpha = load_alpha(SRC)
    outside = outside_mask(alpha)

    for name, silhouette in (("hand-white", False), ("hand-white-solid", True)):
        pixels = build_pixels(alpha, outside, silhouette=silhouette)
        dib = encode_dib(pixels)
        write_container(OUT_DIR / f"{name}.cur", dib, cursor=True)
        write_container(OUT_DIR / f"{name}.ico", dib, cursor=False)
        write_preview(OUT_DIR / f"{name}-preview.png", pixels)
        opaque = sum(1 for row in pixels for px in row if px is not None)
        print(f"{name}: {opaque} opaque pixels, hotspot {HOTSPOT}")


if __name__ == "__main__":
    main()
