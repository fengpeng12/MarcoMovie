package com.pilipala.marcomovie;

import java.security.MessageDigest;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;

/** API 23-compatible salted PIN derivation; plaintext PINs are never persisted. */
final class PrivacyPin {
    static final int ITERATIONS = 120000;

    static byte[] derive(String pin, byte[] salt) throws Exception {
        if (pin == null || !pin.matches("[0-9]{4}") || salt.length != 16)
            throw new IllegalArgumentException("请输入 4 位数字密码");
        PBEKeySpec spec = new PBEKeySpec(pin.toCharArray(), salt, ITERATIONS, 256);
        try {
            return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA1")
                    .generateSecret(spec)
                    .getEncoded();
        } finally {
            spec.clearPassword();
        }
    }

    static boolean matches(String pin, byte[] salt, byte[] expected) throws Exception {
        return MessageDigest.isEqual(derive(pin, salt), expected);
    }
}
