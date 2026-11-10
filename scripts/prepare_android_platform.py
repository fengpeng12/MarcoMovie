"""Fetch the pinned official Android 35 compile SDK; does not change the TV OS."""
from pathlib import Path
import hashlib, urllib.request, zipfile

ROOT=Path(__file__).resolve().parents[1]
URL='https://dl.google.com/android/repository/platform-35_r02.zip'
ARCHIVE_SHA1='0bb560a90a7a2cbd0dd8348224d518b638fe7949'
JAR_SHA256='4566663c3876e022b4fa4ced8c8697c4ab1688267f090114fd92d027b32e619b'

def prepare():
    destination=ROOT/'tools/android-35/android.jar'
    if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest()==JAR_SHA256:return destination
    archive=ROOT/'tools/android-platform-35.zip';archive.parent.mkdir(exist_ok=True)
    if not archive.exists():urllib.request.urlretrieve(URL,archive)
    if hashlib.sha1(archive.read_bytes()).hexdigest()!=ARCHIVE_SHA1:raise RuntimeError('Android platform archive checksum mismatch')
    with zipfile.ZipFile(archive) as package:
        name=next(n for n in package.namelist() if n.endswith('/android.jar'));data=package.read(name)
    if hashlib.sha256(data).hexdigest()!=JAR_SHA256:raise RuntimeError('Android compile library checksum mismatch')
    destination.parent.mkdir(parents=True,exist_ok=True);destination.write_bytes(data)
    return destination

if __name__=='__main__':print(prepare())
