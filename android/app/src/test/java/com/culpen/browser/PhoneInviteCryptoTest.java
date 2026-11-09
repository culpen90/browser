package com.culpen.browser;

import org.junit.Test;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyFactory;
import java.security.AlgorithmParameters;
import java.security.KeyPairGenerator;
import java.security.MessageDigest;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPrivateKeySpec;
import java.security.spec.X509EncodedKeySpec;
import java.math.BigInteger;
import java.util.Arrays;
import java.util.Base64;
import javax.crypto.Cipher;
import javax.crypto.KeyAgreement;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import static org.junit.Assert.*;

public final class PhoneInviteCryptoTest {
    private KeyPair identity() throws Exception {
        KeyPairGenerator generator = KeyPairGenerator.getInstance("EC"); generator.initialize(new ECGenParameterSpec("secp256r1")); return generator.generateKeyPair();
    }
    @Test public void matchesNativeComputerCrossPlatformKnownVector() throws Exception {
        byte[] sender = Base64.getDecoder().decode("MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEaxfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n60p8D54WK84zV2sxXs7LtkBoN79R9Q==");
        byte[] phonePublic = Base64.getDecoder().decode("MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEfPJ7GI0DT36KUjgDBLUaw8CJaeJ38hs1pgtI/EdmmXgHd1UQ247QQCk9msafdDDbun2t5jzpgimeBLedInhz0Q==");
        AlgorithmParameters parameters = AlgorithmParameters.getInstance("EC"); parameters.init(new ECGenParameterSpec("secp256r1"));
        KeyFactory factory = KeyFactory.getInstance("EC");
        KeyPair phone = new KeyPair(factory.generatePublic(new X509EncodedKeySpec(phonePublic)),
                factory.generatePrivate(new ECPrivateKeySpec(BigInteger.valueOf(2), parameters.getParameterSpec(ECParameterSpec.class))));
        byte[] key = PhoneInviteCrypto.sharedKey(phone, sender);
        StringBuilder hex = new StringBuilder(); for (byte value : key) hex.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
        assertEquals("e1874eff53a65e2883977044a23e89c8b8ba49f737b35f52e9c975861dd1652d", hex.toString());
        assertEquals("021671", PhoneInviteCrypto.code(key));
    }
    @Test public void invitationDerivationMatchesSenderAndRepliesBindToRequest() throws Exception {
        KeyPair phone = identity(), sender = identity();
        byte[] key = PhoneInviteCrypto.sharedKey(phone, sender.getPublic().getEncoded());
        KeyAgreement agreement = KeyAgreement.getInstance("ECDH"); agreement.init(sender.getPrivate()); agreement.doPhase(phone.getPublic(), true);
        MessageDigest hash = MessageDigest.getInstance("SHA-256"); hash.update("BrowserAgent/phone-invite/v1".getBytes(StandardCharsets.UTF_8)); hash.update(agreement.generateSecret());
        hash.update(sender.getPublic().getEncoded()); hash.update(phone.getPublic().getEncoded()); assertArrayEquals(hash.digest(), key);
        assertTrue(PhoneInviteCrypto.code(key).matches("[0-9]{6}"));
        byte[] plain = "An authenticated invitation".getBytes(StandardCharsets.UTF_8), nonce = new byte[12]; Arrays.fill(nonce, (byte) 3);
        Cipher encrypt = Cipher.getInstance("AES/GCM/NoPadding"); encrypt.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce)); encrypt.updateAAD(PhoneInviteCrypto.REQUEST_AAD);
        byte[] encrypted = encrypt.doFinal(plain), request = Arrays.copyOf(nonce, 12 + encrypted.length); System.arraycopy(encrypted, 0, request, 12, encrypted.length);
        assertArrayEquals(plain, PhoneInviteCrypto.open(request, key));
        byte[] response = PhoneInviteCrypto.reply(plain, key, request);
        Cipher decrypt = Cipher.getInstance("AES/GCM/NoPadding"); decrypt.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, response, 0, 12));
        decrypt.updateAAD(PhoneInviteCrypto.RESPONSE_AAD); decrypt.updateAAD(nonce); assertArrayEquals(plain, decrypt.doFinal(response, 12, response.length - 12));
        request[request.length - 1] ^= 1;
        try { PhoneInviteCrypto.open(request, key); fail("Tampered invitation accepted"); } catch (java.security.GeneralSecurityException expected) { }
    }
}
