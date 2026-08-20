#!/usr/bin/env python3
"""Robi z obrazka źródłowego komplet ikon .icns dla pakietu .app.

Obrazek wejściowy ma białe tło i ikonę gdzieś pośrodku. Skrypt:
1. przycina do samej ikony,
2. wycina zaokrąglone rogi (inaczej w Docku widać białe narożniki),
3. dokłada margines, bo macOS oczekuje ikony mniejszej niż płótno,
4. generuje wszystkie rozmiary wymagane przez .icns.

Użycie: python3 scripts/make_icon.py zrodlo.png Resources/MICFLOW.icns
"""
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

# macOS rysuje ikonę na płótnie z zapasem na cień — bez marginesu ikona
# wygląda w Docku na większą niż systemowe.
CANVAS = 1024
CONTENT = 824

# Rozmiary wymagane przez iconutil.
SIZES = [16, 32, 64, 128, 256, 512, 1024]


def trim_to_icon(image: Image.Image, tolerance: int = 18) -> Image.Image:
    """Przycina białe otoczenie, zostawiając samą ikonę."""
    grayscale = image.convert("L")
    mask = grayscale.point(lambda value: 0 if value > 255 - tolerance else 255)
    box = mask.getbbox()
    if box is None:
        raise SystemExit("BŁĄD: obrazek wygląda na całkowicie biały.")
    return image.crop(box)


def make_square(image: Image.Image) -> Image.Image:
    """Dosuwa do kwadratu, gdyby przycięcie wyszło lekko prostokątne."""
    side = max(image.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(image, ((side - image.width) // 2, (side - image.height) // 2))
    return square


def round_corners(image: Image.Image, radius_ratio: float = 0.235) -> Image.Image:
    """Nakłada maskę zaokrąglonego kwadratu — usuwa białe narożniki.

    Maska jest odrobinę mniejsza od obrazka: źródło ma wokół kształtu delikatny
    cień, który bez tego zostawał w narożnikach jako ciemne zadziory.
    Proporcja promienia odpowiada temu, czego macOS używa dla ikon aplikacji.
    """
    inset = max(1, round(image.width * 0.012))

    mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [(inset, inset), (image.width - 1 - inset, image.height - 1 - inset)],
        radius=int(image.width * radius_ratio),
        fill=255,
    )
    result = image.copy()
    result.putalpha(mask)
    return result


def build(source: str, destination: str) -> None:
    image = Image.open(source).convert("RGBA")
    image = round_corners(make_square(trim_to_icon(image)))
    image = image.resize((CONTENT, CONTENT), Image.LANCZOS)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - CONTENT) // 2
    canvas.paste(image, (offset, offset), image)

    with tempfile.TemporaryDirectory() as directory:
        iconset = pathlib.Path(directory) / "icon.iconset"
        iconset.mkdir()

        for size in SIZES:
            resized = canvas.resize((size, size), Image.LANCZOS)
            resized.save(iconset / f"icon_{size}x{size}.png")
            # Warianty @2x pozwalają macOS wybrać ostrzejszą wersję na Retinie.
            if size > 16:
                resized.save(iconset / f"icon_{size // 2}x{size // 2}@2x.png")

        pathlib.Path(destination).parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", destination],
            check=True,
        )

    print(f"Zapisano: {destination}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    build(sys.argv[1], sys.argv[2])
