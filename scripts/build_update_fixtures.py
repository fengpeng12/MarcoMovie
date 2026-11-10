from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from build_android import ROOT,SDK,JDK,ANDROID,run,exe
import xml.etree.ElementTree as ET
m=ET.parse(ROOT/'android/src/main/AndroidManifest.xml').getroot(); ns='{http://schemas.android.com/apk/res/android}'; code=int(m.get(ns+'versionCode')); parts=m.get(ns+'versionName').split('.'); newer='.'.join(parts[:2]+[str(int(parts[2])+1)]); older='.'.join(parts[:2]+[str(max(0,int(parts[2])-1))])
out=ROOT/'android/build/update-fixtures';out.mkdir(parents=True,exist_ok=True)
for name,package,code,version in [('newer','com.pilipala.marcomovie',code+1,newer),('older','com.pilipala.marcomovie',code-1,older),('foreign','com.example.updatefixture',code+1,newer)]:
    manifest=out/(name+'.xml')
    manifest.write_text(f'<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{package}" android:versionCode="{code}" android:versionName="{version}"><uses-sdk android:minSdkVersion="23" android:targetSdkVersion="28"/><application android:label="Never install test fixture"/></manifest>',encoding='utf-8')
    run(exe(SDK,'aapt2'),'link','-o',out/(name+'-unsigned.apk'),'--manifest',manifest,'-I',ANDROID)
    run(exe(JDK/'bin','java'),'-jar',SDK/'lib/apksigner.jar','sign','--ks',ROOT/'android/private/development.p12','--ks-key-alias','marcomovie','--ks-pass','env:MARCOMOVIE_KEY_PASSWORD','--out',out/(name+'.apk'),out/(name+'-unsigned.apk'))
key=out/'fixture.p12'
if not key.exists():run(exe(JDK/'bin','keytool'),'-genkeypair','-alias','fixture','-keystore',key,'-storepass','fixture','-keypass','fixture','-dname','CN=Private test fixture','-keyalg','RSA','-validity','30')
run(exe(JDK/'bin','java'),'-jar',SDK/'lib/apksigner.jar','sign','--ks',key,'--ks-pass','pass:fixture','--out',out/'wrong-signer.apk',out/'newer-unsigned.apk')
