"""Format or check project Java sources with a pinned google-java-format.

    python scripts/format_java.py           # rewrite files in place
    python scripts/format_java.py --check   # exit 1 if any file needs formatting

Scope: first-party sources under android/src/main/java/com/pilipala and the
offline/device checks under android/tests. Vendored Media3 decoder sources and
the catvod Spider ABI stay byte-identical to their references.

Options keep the change purely mechanical: imports are neither reordered nor
removed, long string literals are not split, and Javadoc is not rewrapped, so
compiling with -g:none produces identical class files before and after.
"""
from pathlib import Path
import hashlib, os, shutil, subprocess, sys, urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = '1.24.0'
SHA256 = '812f805f58112460edf01bf202a8e61d0fd1f35c0d4fabd54220640776ec57a1'
URL = f'https://github.com/google/google-java-format/releases/download/v{VERSION}/google-java-format-{VERSION}-all-deps.jar'
JAR = ROOT / 'tools/format' / f'google-java-format-{VERSION}-all-deps.jar'
SCOPES = (('shared/java', '**/*.java'), ('android/src/main/java/com/pilipala', '**/*.java'), ('android/tests', '*.java'), ('android/tests/device', '*.java'))
OPTIONS = ['--aosp', '--skip-sorting-imports', '--skip-removing-unused-imports',
           '--skip-reflowing-long-strings', '--skip-javadoc-formatting']
EXPORTS = [f'--add-exports=jdk.compiler/com.sun.tools.javac.{p}=ALL-UNNAMED'
           for p in ('api', 'code', 'file', 'parser', 'tree', 'util')]


def java():
    home = os.environ.get('MARCOMOVIE_JDK') or os.environ.get('JAVA_HOME')
    if home:
        return str(Path(home) / 'bin' / ('java.exe' if os.name == 'nt' else 'java'))
    found = shutil.which('java')
    if not found:
        raise SystemExit('Set JAVA_HOME or MARCOMOVIE_JDK to JDK 17 or newer')
    return found


def formatter():
    if not JAR.exists():
        JAR.parent.mkdir(parents=True, exist_ok=True)
        JAR.write_bytes(urllib.request.urlopen(URL, timeout=60).read())
    if hashlib.sha256(JAR.read_bytes()).hexdigest() != SHA256:
        JAR.unlink()
        raise SystemExit('google-java-format digest mismatch')
    return JAR


def sources():
    files = []
    for folder, pattern in SCOPES:
        files += sorted((ROOT / folder).glob(pattern))
    return files


def main():
    check = '--check' in sys.argv[1:]
    mode = ['--dry-run', '--set-exit-if-changed'] if check else ['--replace']
    files = sources()
    if not check:
        for path in files:
            raw = path.read_bytes()
            if b'\r' in raw:
                path.write_bytes(raw.replace(b'\r\n', b'\n').replace(b'\r', b'\n'))
    result = subprocess.run([java(), *EXPORTS, '-jar', str(formatter()), *OPTIONS, *mode, *map(str, files)],
                            cwd=ROOT, text=True, encoding='utf-8', errors='replace', capture_output=True)
    if result.stderr:
        print(result.stderr, file=sys.stderr)
    if check:
        changed = [line for line in result.stdout.splitlines() if line.strip()]
        if changed or result.returncode:
            print('Files need formatting (run python scripts/format_java.py):')
            for line in changed:
                print('  ' + Path(line).resolve().relative_to(ROOT).as_posix())
            return 1
        print(f'{len(files)} Java files already formatted')
        return 0
    if result.returncode:
        return result.returncode
    print(f'Formatted {len(files)} Java files')
    return 0


if __name__ == '__main__':
    sys.exit(main())
