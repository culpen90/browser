package com.culpen.browser;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.Arrays;
import java.util.Base64;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class AgentPairingStore {
    private static final String ALIAS = "browser-agent-pairing";
    private final android.content.SharedPreferences preferences;

    AgentPairingStore(Context context) {
        preferences = context.getSharedPreferences("agent-connection", Context.MODE_PRIVATE);
    }

    AgentConnection load() {
        String saved = preferences.getString("pairing", null);
        if (saved == null) return null;
        try {
            byte[] bytes = Base64.getDecoder().decode(saved);
            if (bytes.length < 28 || bytes.length > 1024) return null;
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, bytes, 0, 12));
            return AgentConnection.parse(new String(cipher.doFinal(bytes, 12, bytes.length - 12), StandardCharsets.UTF_8));
        } catch (Exception error) { return null; }
    }

    void save(String link) throws Exception {
        AgentConnection.parse(link);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, key());
        byte[] encrypted = cipher.doFinal(link.trim().getBytes(StandardCharsets.UTF_8));
        byte[] bytes = Arrays.copyOf(cipher.getIV(), 12 + encrypted.length);
        System.arraycopy(encrypted, 0, bytes, 12, encrypted.length);
        if (!preferences.edit().putString("pairing", Base64.getEncoder().encodeToString(bytes)).commit()) {
            throw new java.io.IOException("Couldn’t save the PC connection.");
        }
    }

    void clear() { preferences.edit().remove("pairing").apply(); }

    private static SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        SecretKey existing = (SecretKey) store.getKey(ALIAS, null);
        if (existing != null) return existing;
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }
}
