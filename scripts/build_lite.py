"""Build the Android 4.0+ (API 14+) Lite APK alongside the standard release."""
from pathlib import Path
import os,sys,re,hashlib,json,shutil,zipfile,urllib.request,xml.etree.ElementTree as ET
from build_android import ROOT,JDK,SDK,ENV,run,exe
SRC=ROOT/'lite/src/main';BUILD=ROOT/'android/build/lite';DIST=ROOT/'dist/lite'
API14_URL='https://dl.google.com/android/repository/android-14_r04.zip'
API14_ARCHIVE_SHA1='d4f1d8fbca25225b5f0e7a0adf0d39c3d6e60b3c'
API14_JAR_SHA256='1fbb4b4e493389f99e27dff98dbfed1b134855f204948229f4f31cb66908205f'

def prepare_api14():
 env_jar=os.environ.get('MARCOMOVIE_API14_JAR')
 if env_jar and Path(env_jar).exists():return Path(env_jar)
 dest=ROOT/'tools/android-14/android.jar'
 if dest.exists() and hashlib.sha256(dest.read_bytes()).hexdigest()==API14_JAR_SHA256:return dest
 archive=ROOT/'tools/android-platform-14.zip';archive.parent.mkdir(parents=True,exist_ok=True)
 if not archive.exists():urllib.request.urlretrieve(API14_URL,archive)
 if hashlib.sha1(archive.read_bytes()).hexdigest()!=API14_ARCHIVE_SHA1:raise RuntimeError('API14 platform archive checksum mismatch')
 with zipfile.ZipFile(archive) as pkg:
  name=next(n for n in pkg.namelist() if n.endswith('/android.jar'));data=pkg.read(name)
 if hashlib.sha256(data).hexdigest()!=API14_JAR_SHA256:raise RuntimeError('API14 android.jar checksum mismatch')
 dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
 return dest

API14=prepare_api14()

def build():
 candidate='--candidate' in sys.argv
 global BUILD,DIST
 if candidate:BUILD=ROOT/'android/build/lite-candidate';DIST=ROOT/'verification/private/lite-candidate'
 for d in (BUILD/'classes',BUILD/'dex',BUILD/'generated',DIST,ROOT/'dist'):d.mkdir(parents=True,exist_ok=True)
 for folder in ('classes','dex','generated'):
  for p in (BUILD/folder).rglob('*'):
   if p.is_file() and p.suffix in ('.class','.dex','.java'):
    assert p.resolve().is_relative_to(BUILD.resolve());p.unlink()
 dep=ROOT/'tools/java-dependencies/core-3.2.1.jar';dep.parent.mkdir(parents=True,exist_ok=True)
 if not dep.exists():dep.write_bytes(urllib.request.urlopen('https://repo.maven.apache.org/maven2/com/google/zxing/core/3.2.1/core-3.2.1.jar',timeout=30).read())
 pin=ROOT/'lite/zxing.sha256'
 digest=hashlib.sha256(dep.read_bytes()).hexdigest()
 if not pin.exists():raise RuntimeError('Record independently reviewed dependency digest in lite/zxing.sha256')
 if digest!=pin.read_text().strip():raise RuntimeError('ZXing digest mismatch')
 dependencies=[dep];native={}
 if candidate:
  for item in json.loads((ROOT/'lite/candidate-dependencies.json').read_text()):
   archive=ROOT/'tools/lite-dependencies'/item['url'].rsplit('/',1)[1];archive.parent.mkdir(parents=True,exist_ok=True)
   if not archive.exists():archive.write_bytes(urllib.request.urlopen(item['url'],timeout=40).read())
   if hashlib.sha256(archive.read_bytes()).hexdigest()!=item['sha256']:raise RuntimeError('Candidate dependency mismatch')
   with zipfile.ZipFile(archive) as z:
    if 'classes.jar' in z.namelist():
     jar=BUILD/(item['name']+'.jar');jar.write_bytes(z.read('classes.jar'));dependencies.append(jar)
    for n in z.namelist():
     if n.startswith('jni/armeabi-v7a/') and n.endswith('.so'):native['lib/'+n[4:]]=z.read(n)
 run(exe(SDK,'aapt2'),'compile','--dir',SRC/'res','-o',BUILD/'res.zip')
 run(exe(SDK,'aapt2'),'link','-o',BUILD/'res.apk','--manifest',SRC/'AndroidManifest.xml','-I',API14,'--java',BUILD/'generated',BUILD/'res.zip')
 # Lite has no embedded CatPaw runtime; its API 14 build must not link API 21+ hosts.
 shared=[p for package in ('emby','source','glass') for p in (ROOT/'shared/java/com/pilipala'/package).rglob('*.java')]
 sources=list((SRC/'java').rglob('*.java'))+shared+list((BUILD/'generated').rglob('*.java'))
 if candidate:sources+=list((ROOT/'lite/experimental').glob('*.java'))
 run(exe(JDK/'bin','javac'),'-encoding','UTF-8','-source','8','-target','8','-Xlint:-options','-bootclasspath',API14,'-classpath',os.pathsep.join(map(str,dependencies)),'-d',BUILD/'classes',*sources)
 with zipfile.ZipFile(BUILD/'classes.jar','w',zipfile.ZIP_DEFLATED) as z:
  for p in (BUILD/'classes').rglob('*.class'):z.write(p,p.relative_to(BUILD/'classes').as_posix())
 run(exe(JDK/'bin','java'),'-cp',SDK/'lib/d8.jar','com.android.tools.r8.D8','--min-api','14','--lib',API14,'--output',BUILD/'dex',BUILD/'classes.jar',*dependencies)
 dex=list((BUILD/'dex').glob('*.dex'))
 if len(dex)!=1:raise RuntimeError('API14 build must remain single-dex')
 with zipfile.ZipFile(BUILD/'res.apk') as src,zipfile.ZipFile(BUILD/'unsigned.apk','w',zipfile.ZIP_DEFLATED) as out:
  for name in src.namelist():out.writestr(name,src.read(name))
  out.write(dex[0],'classes.dex')
  for name,data in native.items():out.writestr(name,data)
  for file in [ROOT/'lite/LICENSE',ROOT/'lite/NOTICE',*list((ROOT/'lite/licenses').glob('*.txt'))]:out.write(file,'assets/licenses/'+file.name)
 run(exe(SDK,'zipalign'),'-f','4',BUILD/'unsigned.apk',BUILD/'aligned.apk')
 apk=DIST/'MarcoMovie-Lite-0.1.1-alpha.apk'
 key=Path(os.environ.get('MARCOMOVIE_SIGNING_KEY',str(ROOT/'android/private/development.p12')))
 run(exe(JDK/'bin','java'),'-jar',SDK/'lib/apksigner.jar','sign','--min-sdk-version','14','--ks',key,'--ks-key-alias','marcomovie','--ks-pass','env:MARCOMOVIE_KEY_PASSWORD','--out',apk,BUILD/'aligned.apk')
 signature=run(exe(JDK/'bin','java'),'-jar',SDK/'lib/apksigner.jar','verify','--min-sdk-version','14','--verbose','--print-certs',apk,capture=True)
 cert=re.search(r'Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F]+)',signature)
 signer=cert.group(1).lower() if cert else ''
 expected=os.environ.get('MARCOMOVIE_EXPECTED_SIGNER_SHA256','2549f01e89c41201ea171847048228c6df79a7c57fff2ec9a439195c757a80de' if os.environ.get('MARCOMOVIE_RELEASE')=='1' else '').strip().lower()
 if expected and signer!=expected:raise RuntimeError('Lite APK signer certificate mismatch')
 run(exe(SDK,'zipalign'),'-c','4',apk)
 sha=hashlib.sha256(apk.read_bytes()).hexdigest()
 apk.with_suffix('.apk.sha256').write_text(sha+'  '+apk.name+'\n')
 if not candidate:
  version=ET.parse(SRC/'AndroidManifest.xml').getroot().get('{http://schemas.android.com/apk/res/android}versionName','0.4.35')
  from android_package_names import package_name, compatibility_alias
  release_apk=ROOT/'dist'/package_name(version, 'lite')
  shutil.copy2(apk,release_apk)
  release_apk.with_suffix('.apk.sha256').write_text(sha+'  '+release_apk.name+'\n',encoding='utf8')
  compatibility_alias(release_apk, version, 'lite')
 result=dict(package='com.pilipala.marcomovie.lite',experimental_candidate=candidate,compile_api=14,min_api=14,bytes=apk.stat().st_size,sha256=sha,signature=signature,signer_sha256=signer,release_signer_verified=bool(expected),physical_tv_tested=False)
 (BUILD/'build-report.json').write_text(json.dumps(result,indent=2),encoding='utf8');print(json.dumps(result,indent=2))
if __name__=='__main__':build()
