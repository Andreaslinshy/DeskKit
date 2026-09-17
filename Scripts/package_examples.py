#!/usr/bin/env python3
"""Package the three reference components without runtime data or local configuration."""
from pathlib import Path
import hashlib
import json
import re
import zipfile

ROOT = Path(__file__).resolve().parents[1]
COMPONENTS = ('system-monitor', 'codex-quota', 'gold-price')
PRIVATE_PATTERNS = [
    r'/Users/[^/\s]+', r'/Volumes/[^/\s]+',
    r'[A-Za-z0-9_.+%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
    r'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----',
    r'\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})',
]


def package_examples(output=None):
    output = Path(output) if output else ROOT / 'Examples/DeskKit-examples.zip'
    entries = {}
    for component in COMPONENTS:
        folder = ROOT / 'Plugins' / (component + '.deskkit')
        manifest = json.loads((folder / 'widget.json').read_text())
        if manifest['id'] != component or manifest['script'] != 'render.js' or manifest['defaultEnabled']:
            raise SystemExit(f'{component}: examples must keep their known ID/script and start disabled.')
        source = manifest['source']
        if source.get('executable') or source.get('interface'):
            raise SystemExit(f'{component}: remove local executable/interface overrides before sharing.')
        for filename in ('widget.json', 'render.js'):
            data = (folder / filename).read_bytes()
            text = data.decode('utf-8')
            if any(re.search(pattern, text, re.I) for pattern in PRIVATE_PATTERNS):
                raise SystemExit(f'{component}/{filename}: possible private content; package not written.')
            entries[f'DeskKit-examples/{folder.name}/{filename}'] = data
    for source, name in [('Examples/README.md', 'README.md'), ('PluginGuide.md', 'PluginGuide.md'), ('LICENSE', 'LICENSE')]:
        entries['DeskKit-examples/' + name] = (ROOT / source).read_bytes()
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(entries.items()):
            entry = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, data)
    print(f'{output.name}: {len(entries)} files; SHA-256 {hashlib.sha256(output.read_bytes()).hexdigest()}')
    return output


if __name__ == '__main__':
    package_examples()
