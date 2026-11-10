"""Create descriptive installer names while retaining old updater-compatible bytes."""
import argparse
import hashlib
from pathlib import Path
import re
import shutil

ALIASES = {
    'windows-setup.exe': 'windows-x64-setup.exe',
    'windows-x64.zip': 'windows-x64-portable.zip',
    'macos.zip': 'macos-desktop.zip',
    'ios-unsigned.ipa': 'ios-iphone-ipad-unsigned.ipa',
}
PLATFORMS = {
    'windows': ('windows-setup.exe', 'windows-x64.zip'),
    'macos': ('macos.zip',),
    'ios': ('ios-unsigned.ipa',),
}


def clear_names(folder, version, platform):
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?', version):
        raise ValueError('Invalid package version')
    if platform not in PLATFORMS:
        raise ValueError('Unknown platform')
    folder = Path(folder)
    planned = []
    for old in PLATFORMS[platform]:
        source = folder / f'MarcoMovie-{version}-{old}'
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if source.stat().st_size == 0 or source.with_name(source.name + '.sha256').read_text().split()[0] != digest:
            raise ValueError('Original package checksum mismatch')
        target = folder / f'MarcoMovie-{version}-{ALIASES[old]}'
        if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise ValueError('Refusing to overwrite a different named package')
        planned.append((source, target, digest))
    for source, target, digest in planned:
        shutil.copyfile(source, target)
        target.with_name(target.name + '.sha256').write_text(digest + '  ' + target.name + '\n', encoding='ascii')
    return [target for _, target, _ in planned]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--folder', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--platform', choices=PLATFORMS, required=True)
    args = parser.parse_args()
    for path in clear_names(args.folder, args.version, args.platform):
        print(path.name)
