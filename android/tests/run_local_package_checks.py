"""Exercise local imports against the same parser used at Android startup."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
jdk = Path(os.environ.get("MARCOMOVIE_JDK") or os.environ["JAVA_HOME"]) / "bin"
src = root / "android/src/main/java/com/pilipala/marcomovie"
parser = root / "android/tests/lib/json-20240303.jar"
with tempfile.TemporaryDirectory() as output, tempfile.TemporaryDirectory() as imports:
    shim = Path(output) / 'android/util/Base64.java'
    shim.parent.mkdir(parents=True)
    shim.write_text('package android.util; public final class Base64 { public static final int DEFAULT=0; public static final int URL_SAFE=8; public static byte[] decode(String value,int flags){return ((flags & URL_SAFE) != 0 ? java.util.Base64.getUrlDecoder() : java.util.Base64.getMimeDecoder()).decode(value);} }', encoding='utf-8')
    xml_shim = Path(output) / 'android/util/Xml.java'
    xml_shim.write_text('package android.util; public final class Xml { public static org.xmlpull.v1.XmlPullParser newPullParser() { return null; } }', encoding='utf-8')
    xpp_shim = Path(output) / 'org/xmlpull/v1/XmlPullParser.java'
    xpp_shim.parent.mkdir(parents=True)
    xpp_shim.write_text('package org.xmlpull.v1; public interface XmlPullParser { int END_DOCUMENT=1; int START_TAG=2; int END_TAG=3; void setInput(java.io.Reader in) throws Exception; int getEventType() throws Exception; String getName(); String getAttributeValue(String ns, String name); String nextText() throws Exception; int next() throws Exception; }', encoding='utf-8')
    subprocess.run([jdk / "javac", "-encoding", "UTF-8", "-cp", parser, "-d", output,
                    root / "shared/java/com/pilipala/source/Warehouse.java", src / "Cms.java", src / "LocalSourcePackage.java", src / "RequestScope.java", src / "LiveCatalog.java", src / "ProxyAddress.java",
                    root / "android/tests/LocalPackageChecks.java", shim, xml_shim, xpp_shim,
                    root / 'lite/src/main/java/com/pilipala/marcomovie/lite/LiteCatalog.java',
                    root / 'lite/src/main/java/com/pilipala/marcomovie/lite/NetworkTls.java',
                    root / 'android/tests/LiteFormatChecks.java'], check=True)
    subprocess.run([jdk / "java", "-cp", output + os.pathsep + str(parser),
                    "com.pilipala.marcomovie.LocalPackageChecks", imports], check=True)
    subprocess.run([jdk / "java", "-cp", output + os.pathsep + str(parser), "LiteFormatChecks"], check=True)
