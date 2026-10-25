#!/usr/bin/env python3
"""File/assets audit only. This does not parse GDScript or run Godot."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import re
import struct
import sys
import zlib

project = Path(__file__).resolve().parents[1]
source = Path('/Users/kari/Documents/动物餐厅游戏素材/animal_restaurant_v5')
errors = []
required = ['project.godot', 'main.tscn', 'main.gd', 'game_model.gd',
            'restaurant_view.gd', 'README.md', 'tests/test_model.gd',
            'tests/persistence_process.gd']
for name in required:
    path = project / name
    if not path.is_file() or path.stat().st_size == 0:
        errors.append(f'Missing or empty: {name}')

view = (project / 'restaurant_view.gd').read_text()
references = set(re.findall(r'"((?:base|actions|drinks|seating|cleanup|props)/[^"%]+\.(?:png|json))"', view))
for name in references:
    if not (project / 'assets' / name).is_file():
        errors.append(f'Missing runtime asset: {name}')
for i in range(4):
    for name in [f'actions/cat/hands_foreground/eat_{i:02d}.png',
                 f'drinks/cat/hands_foreground/drink_{i}.png']:
        if not (project / 'assets' / name).is_file():
            errors.append(f'Missing dynamic foreground: {name}')

png_count = json_count = matched = 0
for asset in (project / 'assets').rglob('*'):
    if not asset.is_file():
        continue
    if asset.suffix == '.import':
        continue  # Godot's generated sidecars are not upstream asset bytes.
    data = asset.read_bytes()
    relative = asset.relative_to(project / 'assets')
    if source.is_dir():
        original = source / relative
        if not original.is_file() or original.read_bytes() != data:
            errors.append(f'Asset differs from source: {relative}')
        else:
            matched += 1
    if asset.suffix == '.json':
        try:
            json.loads(data)
            json_count += 1
        except (ValueError, UnicodeError) as exc:
            errors.append(f'Bad JSON {relative}: {exc}')
    if asset.suffix == '.png':
        png_count += 1
        if data[:8] != b'\x89PNG\r\n\x1a\n':
            errors.append(f'Bad PNG signature: {relative}')
            continue
        cursor = 8
        while cursor < len(data):
            length = struct.unpack('>I', data[cursor:cursor + 4])[0]
            kind = data[cursor + 4:cursor + 8]
            payload = data[cursor + 8:cursor + 8 + length]
            crc = struct.unpack('>I', data[cursor + 8 + length:cursor + 12 + length])[0]
            if zlib.crc32(kind + payload) & 0xffffffff != crc:
                errors.append(f'PNG CRC failure: {relative}')
                break
            cursor += length + 12
            if kind == b'IEND':
                break
        if '/frames/' in str(asset):
            width, height = struct.unpack('>II', data[16:24])
            if (width, height) != (128, 128):
                errors.append(f'Unexpected character frame dimensions: {relative}')

for script in project.glob('*.gd'):
    if 'restaurant_20_tables' in script.read_text():
        errors.append('Baked 20-table scene referenced at runtime')
report = {
    'checked_at_utc': datetime.now(timezone.utc).isoformat(),
    'project': str(project),
    'scope': 'file references, JSON decoding, PNG signatures/CRC/dimensions, byte equality to v5 source',
    'gdscript_parsed': False,
    'godot_executed': False,
    'runtime_literal_references': len(references),
    'png_files_checked': png_count,
    'json_files_checked': json_count,
    'assets_identical_to_source': matched if source.is_dir() else None,
    'source_sha256': {name: hashlib.sha256((project / name).read_bytes()).hexdigest()
                      for name in required if (project / name).is_file()},
    'passed': not errors,
    'errors': errors,
}
out = project / 'verification' / 'static_checks.json'
out.parent.mkdir(exist_ok=True)
out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(report, ensure_ascii=False, indent=2))
sys.exit(0 if not errors else 1)
