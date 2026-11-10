"""Package the existing transparent brand mark at native launcher sizes.

Run only when the owner-supplied mark changes, with Pillow installed.
The resulting PNG family is checked in, so builds do not need Pillow.
"""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
mark = Image.open(ROOT / 'android/src/main/res/drawable-nodpi/logo_mark.png').convert('RGBA')
for size in (16, 20, 24, 32, 40, 48, 64, 128, 256):
    folder = ROOT / 'flutter/brand/windows'
    folder.mkdir(parents=True, exist_ok=True)
    mark.resize((size, size), Image.Resampling.LANCZOS).save(folder / f'{size}.png')
for density, size in (('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)):
    folder = ROOT / 'android/src/main/res' / f'mipmap-{density}'
    folder.mkdir(parents=True, exist_ok=True)
    mark.resize((size, size), Image.Resampling.LANCZOS).save(folder / 'ic_launcher.png')
