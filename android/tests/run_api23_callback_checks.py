"""Reject Java 8 callback/stream dependencies absent from Android 6.

Run after build_android.py. D8 lambda desugaring does not supply the
java.util.function/java.util.stream library classes on API 23. Inspect the
compiled application, including anonymous callbacks, rather than source text.
This is a narrow dependency regression check, not device/UI acceptance.
"""

from pathlib import Path
import argparse
import struct
import zipfile


ROOT = Path(__file__).resolve().parents[2]
UNAVAILABLE = ("java/util/function/", "java/util/stream/")


def utf8_constants(data):
    if data[:4] != b"\xca\xfe\xba\xbe":
        raise ValueError("Invalid Java class file")
    count = struct.unpack_from(">H", data, 8)[0]
    offset, index = 10, 1
    while index < count:
        tag = data[offset]
        offset += 1
        if tag == 1:
            length = struct.unpack_from(">H", data, offset)[0]
            offset += 2
            yield data[offset : offset + length].decode("utf-8", errors="replace")
            offset += length
        elif tag in (3, 4, 9, 10, 11, 12, 17, 18):
            offset += 4
        elif tag in (5, 6):
            offset += 8
            index += 1
        elif tag in (7, 8, 16, 19, 20):
            offset += 2
        elif tag == 15:
            offset += 3
        else:
            raise ValueError("Unknown Java constant tag: " + str(tag))
        index += 1


def check_jar(path):
    violations = []
    inspected = 0
    with zipfile.ZipFile(path) as jar:
        names = jar.namelist()
        if "com/pilipala/marcomovie/PlaybackControls.class" not in names:
            raise ValueError("Build does not include PlaybackControls")
        for name in names:
            if not name.startswith("com/pilipala/marcomovie/") or not name.endswith(".class"):
                continue
            inspected += 1
            for value in utf8_constants(jar.read(name)):
                for prefix in UNAVAILABLE:
                    if value.startswith(prefix) or ("L" + prefix) in value:
                        violations.append((name, prefix))
    if violations:
        for name, prefix in sorted(set(violations)):
            print("FAIL API 23 missing library dependency: " + name + " -> " + prefix)
        raise SystemExit(1)
    print("PASS API 23 callback dependencies: " + str(inspected) + " application classes")
    print("Device subtitle dialog and rendering behavior still require device validation.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("classes_jar", nargs="?", type=Path, default=ROOT / "android/build/classes.jar")
    check_jar(parser.parse_args().classes_jar)
