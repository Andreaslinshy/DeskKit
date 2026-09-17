#!/usr/bin/env python3
"""Create the macOS AppIcon asset sizes from the supplied DeskKit artwork."""
from pathlib import Path
import json
import subprocess

root = Path(__file__).resolve().parents[1]
source = root / 'Artwork/DeskKitIcon.png'
catalog = root / 'DeskKit/Assets.xcassets'
icons = catalog / 'AppIcon.appiconset'
icons.mkdir(parents=True, exist_ok=True)
info = {'author': 'xcode', 'version': 1}
(catalog / 'Contents.json').write_text(json.dumps({'info': info}, indent=2) + '\n')
images = []
for size in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        pixels = size * scale
        filename = f'icon_{size}x{size}@{scale}x.png'
        subprocess.run(['/usr/bin/sips', '-z', str(pixels), str(pixels), str(source),
                        '--out', str(icons / filename)], check=True, stdout=subprocess.DEVNULL)
        images.append({'filename': filename, 'idiom': 'mac', 'size': f'{size}x{size}', 'scale': f'{scale}x'})
(icons / 'Contents.json').write_text(json.dumps({'images': images, 'info': info}, indent=2) + '\n')
print('Generated 10 macOS app icon sizes.')
