"""Compile LiteProbe against API14 and run JVM verification checks for TV Lite."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request
import zipfile

from build_lite import API14, BUILD, JDK, ROOT, SDK, exe, run

JSON_JAR_URL = 'https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar'
JSON_JAR_SHA256 = '3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed'


def prepare_json_jar():
    env_jar = os.environ.get('MARCOMOVIE_JSON_JAR')
    if env_jar and Path(env_jar).exists():
        return Path(env_jar)
    jar = ROOT / 'android/tests/lib/json-20240303.jar'
    if not jar.exists():
        jar.parent.mkdir(parents=True, exist_ok=True)
        jar.write_bytes(urllib.request.urlopen(JSON_JAR_URL, timeout=30).read())
    if hashlib.sha256(jar.read_bytes()).hexdigest() != JSON_JAR_SHA256:
        raise RuntimeError('Test JSON library digest mismatch')
    return jar

ANDROID_SHIM_BASE64 = """package android.util;
public final class Base64 {
    public static final int DEFAULT = 0;
    public static final int NO_PADDING = 1;
    public static final int NO_WRAP = 2;
    public static final int URL_SAFE = 8;

    public static byte[] decode(String str, int flags) {
        String cleaned = str.trim().replace("\\r", "").replace("\\n", "");
        if ((flags & URL_SAFE) != 0 || cleaned.indexOf('-') >= 0 || cleaned.indexOf('_') >= 0) {
            cleaned = cleaned.replace('-', '+').replace('_', '/');
        }
        while (cleaned.length() % 4 != 0) cleaned += "=";
        return java.util.Base64.getDecoder().decode(cleaned);
    }

    public static String encodeToString(byte[] input, int flags) {
        java.util.Base64.Encoder enc = ((flags & URL_SAFE) != 0)
            ? java.util.Base64.getUrlEncoder()
            : java.util.Base64.getEncoder();
        if ((flags & NO_PADDING) != 0) enc = enc.withoutPadding();
        return enc.encodeToString(input);
    }
}
"""

ANDROID_SHIM_XML = """package android.util;
import java.io.InputStream;
import java.io.Reader;
import javax.xml.stream.XMLInputFactory;
import javax.xml.stream.XMLStreamConstants;
import javax.xml.stream.XMLStreamReader;
import org.xmlpull.v1.XmlPullParser;
import org.xmlpull.v1.XmlPullParserException;

public final class Xml {
    public static XmlPullParser newPullParser() {
        return new StaxPullParser();
    }

    private static final class StaxPullParser implements XmlPullParser {
        private XMLStreamReader reader;
        private int eventType = START_DOCUMENT;

        @Override
        public void setInput(Reader in) throws XmlPullParserException {
            try {
                XMLInputFactory f = XMLInputFactory.newInstance();
                f.setProperty(XMLInputFactory.IS_COALESCING, Boolean.TRUE);
                reader = f.createXMLStreamReader(in);
                eventType = START_DOCUMENT;
            } catch (Exception e) {
                throw new XmlPullParserException(e.getMessage());
            }
        }

        @Override
        public int getEventType() { return eventType; }

        @Override
        public int next() throws XmlPullParserException {
            try {
                while (reader.hasNext()) {
                    int code = reader.next();
                    if (code == XMLStreamConstants.START_ELEMENT) return eventType = START_TAG;
                    if (code == XMLStreamConstants.END_ELEMENT) return eventType = END_TAG;
                    if (code == XMLStreamConstants.CHARACTERS || code == XMLStreamConstants.CDATA) return eventType = TEXT;
                    if (code == XMLStreamConstants.END_DOCUMENT) return eventType = END_DOCUMENT;
                }
                return eventType = END_DOCUMENT;
            } catch (Exception e) {
                throw new XmlPullParserException(e.getMessage());
            }
        }

        @Override
        public String getName() { return reader.getLocalName(); }

        @Override
        public String getAttributeValue(String namespace, String name) {
            return reader.getAttributeValue(namespace, name);
        }

        @Override
        public String nextText() throws XmlPullParserException {
            try {
                return reader.getElementText();
            } catch (Exception e) {
                throw new XmlPullParserException(e.getMessage());
            } finally {
                eventType = END_TAG;
            }
        }

        @Override public void setFeature(String name, boolean state) {}
        @Override public boolean getFeature(String name) { return false; }
        @Override public void setProperty(String name, Object value) {}
        @Override public Object getProperty(String name) { return null; }
        @Override public void setInput(InputStream inputStream, String inputEncoding) {}
        @Override public String getInputEncoding() { return "UTF-8"; }
        @Override public void defineEntityReplacementText(String entityName, String replacementText) {}
        @Override public int getNamespaceCount(int depth) { return 0; }
        @Override public String getNamespacePrefix(int pos) { return null; }
        @Override public String getNamespaceUri(int pos) { return null; }
        @Override public String getNamespace(String prefix) { return null; }
        @Override public int getDepth() { return 0; }
        @Override public String getPositionDescription() { return ""; }
        @Override public int getLineNumber() { return 0; }
        @Override public int getColumnNumber() { return 0; }
        @Override public boolean isWhitespace() { return false; }
        @Override public String getText() { return reader.getText(); }
        @Override public char[] getTextCharacters(int[] holderForStartAndLength) { return new char[0]; }
        @Override public String getNamespace() { return ""; }
        @Override public String getPrefix() { return null; }
        @Override public boolean isEmptyElementTag() { return false; }
        @Override public int getAttributeCount() { return reader.getAttributeCount(); }
        @Override public String getAttributeNamespace(int index) { return ""; }
        @Override public String getAttributeName(int index) { return reader.getAttributeLocalName(index); }
        @Override public String getAttributePrefix(int index) { return null; }
        @Override public String getAttributeType(int index) { return "CDATA"; }
        @Override public boolean isAttributeDefault(int index) { return false; }
        @Override public String getAttributeValue(int index) { return reader.getAttributeValue(index); }
        @Override public int nextToken() throws XmlPullParserException { return next(); }
        @Override public void require(int type, String namespace, String name) {}
        @Override public int nextTag() throws XmlPullParserException { return next(); }
    }
}
"""


def main():
    if not (BUILD / 'classes.jar').exists():
        subprocess.run(['python', '-X', 'utf8', str(ROOT / 'scripts/build_lite.py')], check=True)

    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        probe_classes = tmp_dir / 'probe_classes'
        probe_dex = tmp_dir / 'probe_dex'
        probe_classes.mkdir()
        probe_dex.mkdir()

        # 1. Verify LiteProbe.java compiles cleanly against API 14 + classes.jar and dexes for min-api 14
        run(
            exe(JDK / 'bin', 'javac'),
            '-encoding', 'UTF-8',
            '-source', '8', '-target', '8',
            '-bootclasspath', API14,
            '-classpath', BUILD / 'classes.jar',
            '-d', probe_classes,
            ROOT / 'lite/tests/LiteProbe.java',
        )
        probe_jar = tmp_dir / 'probe.jar'
        with zipfile.ZipFile(probe_jar, 'w') as zf:
            for p in probe_classes.rglob('*.class'):
                zf.write(p, p.relative_to(probe_classes).as_posix())
        run(
            exe(JDK / 'bin', 'java'),
            '-cp', SDK / 'lib/d8.jar',
            'com.android.tools.r8.D8',
            '--min-api', '14',
            '--lib', API14,
            '--classpath', BUILD / 'classes.jar',
            '--output', probe_dex,
            probe_jar,
        )
        assert (probe_dex / 'classes.dex').exists(), 'LiteProbe failed D8 min-api 14 verification'
        print('PASS LiteProbe API14 compile + D8 min-api 14 check')

        # 2. Compile and run LiteJvmChecks
        shim_src = tmp_dir / 'shim_src/android/util'
        shim_src.mkdir(parents=True)
        (shim_src / 'Base64.java').write_text(ANDROID_SHIM_BASE64, encoding='utf-8')
        (shim_src / 'Xml.java').write_text(ANDROID_SHIM_XML, encoding='utf-8')

        jvm_classes = tmp_dir / 'jvm_classes'
        jvm_classes.mkdir()
        json_jar = prepare_json_jar()
        sep = os.pathsep
        compile_cp = sep.join([str(BUILD / 'classes.jar'), str(json_jar), str(API14)])
        run(
            exe(JDK / 'bin', 'javac'),
            '-encoding', 'UTF-8',
            '-source', '8', '-target', '8',
            '-classpath', compile_cp,
            '-d', jvm_classes,
            shim_src / 'Base64.java',
            shim_src / 'Xml.java',
            ROOT / 'lite/tests/LiteJvmChecks.java',
            ROOT / 'lite/tests/LiteCredentialProbe.java',
            ROOT / 'lite/tests/LiteTlsChecks.java',
        )
        run_cp = sep.join([str(jvm_classes), str(BUILD / 'classes.jar'), str(json_jar), str(API14)])
        out = run(exe(JDK / 'bin', 'java'), '-cp', run_cp, 'com.pilipala.marcomovie.lite.LiteJvmChecks', capture=True)
        print(out.strip())
        assert 'PASS 53 TV Lite JVM checks' in out
        print(run(exe(JDK / 'bin', 'java'), '-cp', run_cp, 'com.pilipala.marcomovie.lite.LiteCredentialProbe', capture=True).strip())
        print(run(exe(JDK / 'bin', 'java'), '-cp', run_cp, 'com.pilipala.marcomovie.lite.LiteTlsChecks', capture=True).strip())


if __name__ == '__main__':
    main()
