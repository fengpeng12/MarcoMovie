package com.pilipala.marcomovie.lite;

import javax.net.ssl.*;
import java.io.IOException;
import java.util.Arrays;

public final class LiteTlsChecks {
    static final class LegacySocket extends SSLSocket {
        final String[] supported;
        String[] enabled = {"TLSv1"};
        boolean closed;
        LegacySocket(String... supported) { this.supported = supported; }
        public String[] getSupportedProtocols() { return supported; }
        public String[] getEnabledProtocols() { return enabled; }
        public void setEnabledProtocols(String[] protocols) { enabled = protocols; }
        public String[] getSupportedCipherSuites() { return new String[0]; }
        public String[] getEnabledCipherSuites() { return new String[0]; }
        public void setEnabledCipherSuites(String[] suites) {}
        public SSLSession getSession() { return null; }
        public void addHandshakeCompletedListener(HandshakeCompletedListener listener) {}
        public void removeHandshakeCompletedListener(HandshakeCompletedListener listener) {}
        public void startHandshake() {}
        public void setUseClientMode(boolean mode) {}
        public boolean getUseClientMode() { return true; }
        public void setNeedClientAuth(boolean need) {}
        public boolean getNeedClientAuth() { return false; }
        public void setWantClientAuth(boolean want) {}
        public boolean getWantClientAuth() { return false; }
        public void setEnableSessionCreation(boolean flag) {}
        public boolean getEnableSessionCreation() { return true; }
        public void close() { closed = true; }
    }

    public static void main(String[] args) throws Exception {
        LegacySocket old = new LegacySocket("SSLv3", "TLSv1", "TLSv1.1", "TLSv1.2");
        NetworkTls.ModernTlsFactory.configure(old);
        if (!Arrays.equals(old.enabled, new String[]{"TLSv1.2"}))
            throw new AssertionError("Android 4.1-4.4 must explicitly enable supported TLS 1.2");
        LegacySocket modern = new LegacySocket("TLSv1", "TLSv1.2", "TLSv1.3");
        NetworkTls.ModernTlsFactory.configure(modern);
        if (!Arrays.equals(modern.enabled, new String[]{"TLSv1.2", "TLSv1.3"}))
            throw new AssertionError("Keep modern protocols enabled");
        LegacySocket unsupported = new LegacySocket("SSLv3", "TLSv1");
        try {
            NetworkTls.ModernTlsFactory.configure(unsupported);
            throw new AssertionError("API14 TLS must report an explicit compatibility failure");
        } catch (IOException expected) {
            if (!unsupported.closed || !expected.getMessage().contains("TLS 1.2"))
                throw new AssertionError("Unsupported socket must close with an actionable error");
        }
        System.out.println("PASS 3 Lite TLS capability checks");
    }
}
