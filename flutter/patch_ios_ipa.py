"""Validate real iOS 14 deployment targets, then ad-hoc sign for sideloading."""
from pathlib import Path
import plistlib
import struct
import subprocess
import sys


def validate_app(app_dir: Path) -> None:
    """Reject dependencies compiled for a newer iOS. Rewriting minos hides dyld errors."""
    if not (app_dir / 'Info.plist').is_file():
        raise ValueError('Missing application Info.plist')
    binaries = 0
    for path in app_dir.rglob('*'):
        if path.is_symlink() or not path.is_file():
            continue
        if path.name == 'Info.plist':
            metadata = plistlib.loads(path.read_bytes())
            minimum = metadata.get('MinimumOSVersion')
            if minimum and tuple((list(map(int, minimum.split('.'))) + [0, 0])[:3]) > (14, 0, 0):
                raise ValueError(f'{path}: requires iOS {minimum}')
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic in (bytes.fromhex('cafebabe'), bytes.fromhex('cafebabf')):
            subprocess.run(['lipo', '-thin', 'arm64', str(path), '-output', str(path)], check=True)
        elif magic != bytes.fromhex('cffaedfe'):
            continue
        data = path.read_bytes()
        if len(data) < 32 or data[:4] != bytes.fromhex('cffaedfe'):
            raise ValueError(f'{path}: truncated or unsupported Mach-O')
        binaries += 1
        cpu, = struct.unpack_from('<I', data, 4)
        if cpu != 0x0100000c:
            raise ValueError(f'{path}: expected arm64 iOS device binary')
        count, size = struct.unpack_from('<II', data, 16)
        if size > len(data) - 32 or count > size // 8:
            raise ValueError(f'{path}: invalid load-command bounds')
        pos = 32
        has_target = False
        for _ in range(count):
            cmd, length = struct.unpack_from('<II', data, pos)
            if length < 8 or pos + length > 32 + size:
                raise ValueError(f'{path}: invalid Mach-O')
            if cmd in (0x24, 0x2f, 0x30):
                raise ValueError(f'{path}: non-iOS device deployment target')
            if cmd in (0x32, 0x25):
                has_target = True
                if length < (24 if cmd == 0x32 else 16):
                    raise ValueError(f'{path}: truncated deployment command')
            if cmd == 0x32:
                platform, minimum = struct.unpack_from('<II', data, pos + 8)
                if platform != 2 or minimum > 0x000e0000:
                    raise ValueError(f'{path}: incompatible platform {platform}, deployment target {minimum:#x}')
            if cmd == 0x25 and struct.unpack_from('<I', data, pos + 8)[0] > 0x000e0000:
                raise ValueError(f'{path}: deployment target exceeds iOS 14.0')
            pos += length
        if pos != 32 + size or not has_target:
            raise ValueError(f'{path}: missing deployment target or invalid command size')
    if binaries == 0:
        raise ValueError('No arm64 application binaries found')


def codesign_bundle(app_dir: Path) -> None:
    fw_dir = app_dir / "Frameworks"
    if fw_dir.exists():
        for item in sorted(fw_dir.iterdir()):
            if item.suffix in (".framework", ".dylib"):
                subprocess.run(
                    ["codesign", "--force", "--sign", "-", "--timestamp=none", str(item)],
                    check=True,
                )
    entitlements = app_dir.parent / "trollstore.entitlements"
    entitlements.write_bytes(
        plistlib.dumps(
            {
                "application-identifier": "TROLLSTORE.com.pilipala.marcoMovie",
                "com.apple.developer.team-identifier": "TROLLSTORE",
                "get-task-allow": True,
            },
            fmt=plistlib.FMT_XML,
        )
    )
    subprocess.run(
        [
            "codesign",
            "--force",
            "--sign",
            "-",
            "--timestamp=none",
            "--entitlements",
            str(entitlements),
            str(app_dir),
        ],
        check=True,
    )


def main() -> None:
    app_dir = Path(sys.argv[1]).resolve()
    validate_app(app_dir)
    codesign_bundle(app_dir)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app_dir)], check=True)


if __name__ == "__main__":
    main()
