package com.pilipala.marcomovie;

import java.util.Arrays;

/** Host checks for PIN validation and persisted verifier compatibility. */
public final class PrivacyPinChecks {
    public static void main(String[] args) throws Exception {
        byte[] salt = new byte[16];
        byte[] hash = PrivacyPin.derive("0123", salt);
        if (!PrivacyPin.matches("0123", salt, hash)) throw new AssertionError("correct PIN");
        if (PrivacyPin.matches("1230", salt, hash)) throw new AssertionError("wrong PIN");
        byte[] differentSalt = salt.clone();
        differentSalt[0] = 1;
        if (Arrays.equals(hash, PrivacyPin.derive("0123", differentSalt)))
            throw new AssertionError("salt independence");
        for (String invalid : new String[] {"123", "12345", "１２３４", "abcd", " 123", ""}) {
            try {
                PrivacyPin.derive(invalid, salt);
                throw new AssertionError("invalid PIN accepted");
            } catch (IllegalArgumentException expected) {
            }
        }
        System.out.println("PASS correct/wrong PIN, salted verifier, six invalid PIN inputs");
    }
}
