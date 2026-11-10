"""Build a separate instrumentation APK using the local development identity."""
from pathlib import Path
import sys, zipfile, os, wave, hashlib, json
sys.path.insert(0,str(Path(__file__).parent))
from build_android import ROOT, BUILD, JDK, SDK, ANDROID, run, exe

probe_name=sys.argv[1] if len(sys.argv)>1 else 'DecoderProbe'
assert probe_name in ('DecoderProbe','InteractionProbe','HomeProbe','StartupProbe','ExperienceProbe','MotionProbe','SearchCaseProbe','PerformanceProbe','DetailProbe','ConfigLiveProbe','UpdateProbe','LayoutProbe','ResponsiveProbe','MobilePlayerProbe','SourceHostProbe')
out=BUILD/('source-host-probe' if probe_name=='SourceHostProbe' else 'mobile-player-probe' if probe_name=='MobilePlayerProbe' else 'responsive-probe' if probe_name=='ResponsiveProbe' else 'layout-probe' if probe_name=='LayoutProbe' else 'update-probe' if probe_name=='UpdateProbe' else 'config-live-probe' if probe_name=='ConfigLiveProbe' else 'detail-probe' if probe_name=='DetailProbe' else 'performance-probe' if probe_name=='PerformanceProbe' else 'search-case-probe' if probe_name=='SearchCaseProbe' else 'motion-probe' if probe_name=='MotionProbe' else 'experience-probe' if probe_name=='ExperienceProbe' else 'startup-probe' if probe_name=='StartupProbe' else 'probe' if probe_name=='Probe' else 'decoder-probe' if probe_name=='DecoderProbe' else 'home-probe' if probe_name=='HomeProbe' else 'interaction-probe');out.mkdir(exist_ok=True)
for d in ('classes','dex'): (out/d).mkdir(exist_ok=True)
manifest=out/'AndroidManifest.xml'
manifest.write_text('''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.pilipala.marcomovie.test"><uses-sdk android:minSdkVersion="23" android:targetSdkVersion="28"/><application android:label="Marco Movie local test"/><instrumentation android:name="com.pilipala.marcomovie.Probe" android:targetPackage="com.pilipala.marcomovie"/></manifest>''',encoding='utf-8')
manifest.write_text(manifest.read_text().replace('com.pilipala.marcomovie.Probe','com.pilipala.marcomovie.'+probe_name),encoding='utf-8')
assets=[]
if probe_name=='MobilePlayerProbe':
    # Deterministic local media: this verifies seeking/layout, not video codecs.
    folder=out/'assets';folder.mkdir(exist_ok=True)
    with wave.open(str(folder/'timeline.wav'),'wb') as audio:
        audio.setparams((1,2,8000,0,'NONE','not compressed'))
        audio.writeframes(b'\x00\x00'*8000*60)
    assets=['-A',folder]
run(exe(SDK,'aapt2'),'link','-o',out/'resources.apk','--manifest',manifest,'-I',ANDROID,*assets)
run(exe(JDK/'bin','javac'),'-encoding','UTF-8','-source','8','-target','8','-Xlint:-options','-classpath',str(ANDROID)+os.pathsep+str(BUILD/'classes.jar')+(os.pathsep+str(ROOT/'tools/java-dependencies/core-3.5.3.jar') if probe_name=='ConfigLiveProbe' else ''),'-d',out/'classes',ROOT/('android/tests/device/'+probe_name+'.java'))
with zipfile.ZipFile(out/'classes.jar','w') as z:
    for p in (out/'classes').rglob('*.class'):z.write(p,p.relative_to(out/'classes').as_posix())
run(exe(JDK/'bin','java'),'-cp',SDK/'lib/d8.jar','com.android.tools.r8.D8','--min-api','23','--lib',ANDROID,'--classpath',BUILD/'classes.jar','--output',out/'dex',out/'classes.jar')
with zipfile.ZipFile(out/'resources.apk') as src,zipfile.ZipFile(out/'unsigned.apk','w',zipfile.ZIP_DEFLATED) as dst:
    for n in src.namelist():dst.writestr(n,src.read(n))
    dst.write(out/'dex/classes.dex','classes.dex')
run(exe(SDK,'zipalign'),'-f','4',out/'unsigned.apk',out/'aligned.apk')
run(exe(JDK/'bin','java'),'-jar',SDK/'lib/apksigner.jar','sign','--ks',Path(os.environ.get('MARCOMOVIE_SIGNING_KEY',str(ROOT/'android/private/development.p12'))),'--ks-key-alias','marcomovie','--ks-pass','env:MARCOMOVIE_KEY_PASSWORD','--out',out/'probe.apk',out/'aligned.apk')
print(out/'probe.apk')
if probe_name=='MobilePlayerProbe':
    # x86_64 UI verification deliberately omits ARM-only native libraries.
    # Never replace dist packages with this test-only derivative.
    source=BUILD/'unsigned-mobile.apk'
    with zipfile.ZipFile(source) as src,zipfile.ZipFile(out/'layout-only-unsigned.apk','w',zipfile.ZIP_DEFLATED) as dst:
        for entry in src.infolist():
            if not entry.filename.startswith('lib/'):
                dst.writestr(entry,src.read(entry.filename))
    run(exe(SDK,'zipalign'),'-f','4',out/'layout-only-unsigned.apk',out/'layout-only-aligned.apk')
    run(exe(JDK/'bin','java'),'-jar',SDK/'lib/apksigner.jar','sign','--ks',Path(os.environ.get('MARCOMOVIE_SIGNING_KEY',str(ROOT/'android/private/development.p12'))),'--ks-key-alias','marcomovie','--ks-pass','env:MARCOMOVIE_KEY_PASSWORD','--out',out/'layout-only.apk',out/'layout-only-aligned.apk')
    (out/'scope.json').write_text(json.dumps({'scope':'UI and system-player seeking only; ARM native libraries omitted. Not a distributable APK or CatPaw/decoder acceptance.','production_unsigned_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'test_apk_sha256':hashlib.sha256((out/'layout-only.apk').read_bytes()).hexdigest()},indent=2)+'\n')
