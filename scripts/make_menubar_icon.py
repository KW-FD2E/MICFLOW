#!/usr/bin/env python3
"""Wycina mikrofon z ikony aplikacji i robi z niego ikonę paska menu.

Pasek menu wymaga obrazka jednobarwnego na przezroczystym tle (template image) —
macOS sam odwraca go w trybie ciemnym i jasnym. Dlatego bierzemy samą sylwetkę,
bez granatowego tła i bez jasnych refleksów.

Użycie: python3 scripts/make_menubar_icon.py Resources/icon-source.png Resources/menubar-mic.png
"""
import sys
from collections import deque

import numpy as np
from PIL import Image

# Wysokość w punktach, w jakiej ikona pojawia się w pasku menu.
TARGET_POINTS = 17
# Zapas rozdzielczości na ekrany Retina.
SCALE = 4
# Plamy mniejsze niż tyle pikseli to śmieci po krawędzi ikony, nie mikrofon.
MIN_BLOB = 300


def largest_blobs(mask: np.ndarray, minimum: int) -> np.ndarray:
    """Zostawia tylko spójne plamy powyżej zadanego rozmiaru."""
    height, width = mask.shape
    visited = np.zeros_like(mask, dtype=bool)
    keep = np.zeros_like(mask)

    for start_y in range(height):
        for start_x in range(width):
            if not mask[start_y, start_x] or visited[start_y, start_x]:
                continue

            queue = deque([(start_y, start_x)])
            visited[start_y, start_x] = True
            cells = []

            while queue:
                y, x = queue.popleft()
                cells.append((y, x))
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < height and 0 <= nx < width and mask[ny, nx] and not visited[ny, nx]:
                        visited[ny, nx] = True
                        queue.append((ny, nx))

            if len(cells) >= minimum:
                for y, x in cells:
                    keep[y, x] = True

    return keep


def build(source: str, destination: str) -> None:
    image = Image.open(source).convert("RGB")
    pixels = np.array(image).astype(int)
    red, green, blue = pixels[:, :, 0], pixels[:, :, 1], pixels[:, :, 2]
    luminance = (red + green + blue) / 3

    # Granice samej ikony — reszta kadru to białe tło.
    icon = luminance < 240
    ys, xs = np.where(icon)
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()

    # Wchodzimy do środka, żeby ominąć krawędź zaokrąglonego kwadratu.
    margin = int((x1 - x0) * 0.05)
    inside = np.zeros_like(icon)
    inside[y0 + margin:y1 - margin + 1, x0 + margin:x1 - margin + 1] = True

    # Tło jest wyraźnie niebieskie (B >> R), a mikrofon czarny lub szary (R≈G≈B).
    mic = ((blue - red) < 25) & (luminance < 205) & inside
    mic = largest_blobs(mic, MIN_BLOB)

    ys, xs = np.where(mic)
    height, width = mic.shape
    rgba = np.zeros((height, width, 4), dtype=np.uint8)
    rgba[:, :, 3] = (mic * 255).astype(np.uint8)

    cropped = Image.fromarray(rgba, "RGBA").crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))

    target_height = TARGET_POINTS * SCALE
    target_width = round(cropped.width * target_height / cropped.height)
    cropped.resize((target_width, target_height), Image.LANCZOS).save(destination)

    print(f"Zapisano: {destination} ({target_width}x{target_height} px, {TARGET_POINTS} pt w pasku)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    build(sys.argv[1], sys.argv[2])
