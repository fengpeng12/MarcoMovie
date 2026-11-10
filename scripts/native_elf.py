"""Inspect ELF LOAD alignment without executing an untrusted native library."""
import argparse
import json
from pathlib import Path
import struct
import zipfile


def inspect_elf(data):
    if len(data) < 16 or data[:4] != b'\x7fELF' or data[5] != 1:
        raise ValueError('Expected a little-endian ELF file')
    bits = data[4]
    if bits == 2:
        header = '<16sHHIQQQIHHHHHH'; program = '<IIQQQQQQ'
    elif bits == 1:
        header = '<16sHHIIIIIHHHHHH'; program = '<IIIIIIII'
    else:
        raise ValueError('Unsupported ELF class')
    if len(data) < struct.calcsize(header):
        raise ValueError('Truncated ELF header')
    fields = struct.unpack_from(header, data)
    phoff, phentsize, phnum = fields[5], fields[9], fields[10]
    if phnum == 0 or phnum == 0xffff or phentsize < struct.calcsize(program):
        raise ValueError('Invalid or extended ELF program table')
    if phoff + phentsize * phnum > len(data):
        raise ValueError('Truncated ELF program table')
    loads = []
    for i in range(phnum):
        p = struct.unpack_from(program, data, phoff + phentsize * i)
        if p[0] != 1:
            continue
        offset, vaddr, filesz, memsz, align = (p[2], p[3], p[5], p[6], p[7]) if bits == 2 else (p[1], p[2], p[4], p[5], p[7])
        if filesz > memsz or offset + filesz > len(data):
            raise ValueError('ELF segment outside file')
        valid = align >= 16384 and align & (align - 1) == 0 and offset % 16384 == vaddr % 16384
        loads.append({'offset': offset, 'vaddr': vaddr, 'align': align, 'compatible_16kb': valid})
    if not loads:
        raise ValueError('ELF has no LOAD segments')
    return {'bits': bits * 32, 'machine': fields[2], 'loads': loads,
            'compatible_16kb': all(p['compatible_16kb'] for p in loads)}


def inspect_apk(path):
    rows = []
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            if not item.filename.startswith('lib/') or not item.filename.endswith('.so'):
                continue
            row = {'path': item.filename, **inspect_elf(archive.read(item))}
            # Compressed libraries are extracted by Android. Only stored entries
            # can be mmap'ed from the APK and require an aligned ZIP data offset.
            with open(path, 'rb') as stream:
                stream.seek(item.header_offset)
                local = stream.read(30)
            if len(local) != 30 or local[:4] != b'PK\x03\x04':
                raise ValueError('Invalid ZIP local header')
            name_size, extra_size = struct.unpack_from('<HH', local, 26)
            offset = item.header_offset + 30 + name_size + extra_size
            row['zip_compressed'] = item.compress_type != zipfile.ZIP_STORED
            row['zip_16kb_aligned'] = row['zip_compressed'] or offset % 16384 == 0
            rows.append(row)
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('path', type=Path)
    parser.add_argument('--require-16kb', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    rows = inspect_apk(args.path) if zipfile.is_zipfile(args.path) else [{'path': args.path.name, **inspect_elf(args.path.read_bytes())}]
    report = json.dumps(rows, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report, encoding='utf-8')
    else:
        print(report)
    failures = [r['path'] for r in rows if r['bits'] == 64 and not (r['compatible_16kb'] and r.get('zip_16kb_aligned', True))]
    if args.require_16kb and not any(r['bits'] == 64 for r in rows):
        raise SystemExit('No 64-bit native libraries found; 16KB support cannot be verified')
    if args.require_16kb and failures:
        raise SystemExit('Non-16KB native libraries: ' + ', '.join(failures))


if __name__ == '__main__':
    main()
