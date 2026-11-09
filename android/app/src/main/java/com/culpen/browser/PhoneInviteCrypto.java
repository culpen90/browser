package com.culpen.browser;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.security.interfaces.ECPublicKey;
import java.security.spec.X509EncodedKeySpec;
import java.util.Arrays;
import java.util.Locale;
import javax.crypto.Cipher;
import javax.crypto.KeyAgreement;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** The invitation exchange protects model pairing links and binds replies to each request. */
final class PhoneInviteCrypto {
    static final byte[] REQUEST_AAD = bytes("BrowserAgent/phone-invite/v1 request");
    static final byte[] RESPONSE_AAD = bytes("BrowserAgent/phone-invite/v1 response");
    private static byte[] bytes(String value) { return value.getBytes(StandardCharsets.UTF_8); }

    static byte[] sharedKey(KeyPair phone, byte[] senderDER) throws Exception {
        if (senderDER.length < 64 || senderDER.length > 200) throw new java.security.GeneralSecurityException();
        ECPublicKey sender = (ECPublicKey) KeyFactory.getInstance("EC").generatePublic(new X509EncodedKeySpec(senderDER));
        ECPublicKey local = (ECPublicKey) phone.getPublic();
        if (!sender.getParams().getOrder().equals(local.getParams().getOrder())
                || !sender.getParams().getCurve().equals(local.getParams().getCurve())
                || !sender.getParams().getGenerator().equals(local.getParams().getGenerator())) {
            throw new java.security.GeneralSecurityException();
        }
        KeyAgreement agreement = KeyAgreement.getInstance("ECDH");
        agreement.init(phone.getPrivate()); agreement.doPhase(sender, true);
        MessageDigest hash = MessageDigest.getInstance("SHA-256");
        hash.update(bytes("BrowserAgent/phone-invite/v1")); hash.update(agreement.generateSecret());
        hash.update(senderDER); hash.update(phone.getPublic().getEncoded());
        return hash.digest();
    }

    static byte[] open(byte[] combined, byte[] key) throws Exception {
        if (combined.length < 28 || combined.length > 16_384) throw new java.security.GeneralSecurityException();
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, combined, 0, 12));
        cipher.updateAAD(REQUEST_AAD);
        return cipher.doFinal(combined, 12, combined.length - 12);
    }

    static byte[] reply(byte[] plain, byte[] key, byte[] request) throws Exception {
        byte[] nonce = new byte[12]; new SecureRandom().nextBytes(nonce);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
        cipher.updateAAD(RESPONSE_AAD); cipher.updateAAD(Arrays.copyOf(request, 12));
        byte[] encrypted = cipher.doFinal(plain), result = Arrays.copyOf(nonce, nonce.length + encrypted.length);
        System.arraycopy(encrypted, 0, result, nonce.length, encrypted.length); return result;
    }

    static String code(byte[] key) throws Exception {
        MessageDigest hash = MessageDigest.getInstance("SHA-256"); hash.update(key); hash.update(bytes("verify"));
        long number = ByteBuffer.wrap(hash.digest()).getInt() & 0xffffffffL;
        return String.format(Locale.ROOT, "%06d", number % 1_000_000);
    }
}
