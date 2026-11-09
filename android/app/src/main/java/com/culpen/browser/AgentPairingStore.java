package com.culpen.browser;

import android.content.Context;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.Arrays;
import java.util.Base64;
import java.util.List;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class AgentPairingStore {
    private static final String ALIAS = "browser-agent-pairing";
    private static final byte[] DEVICES_AAD = "BrowserAgent/devices/v1".getBytes(StandardCharsets.UTF_8);
    private final android.content.SharedPreferences preferences;

    AgentPairingStore(Context context) {
        preferences = context.getSharedPreferences("agent-connection", Context.MODE_PRIVATE);
    }

    AgentConnection load() { return readDevices().selected(); }
    List<AgentConnection> devices() { return readDevices().devices(); }

    private AgentDeviceList readDevices() {
        String saved = preferences.getString("devices", null);
        boolean legacy = saved == null;
        if (legacy) saved = preferences.getString("pairing", null);
        if (saved == null) return new AgentDeviceList();
        try {
            byte[] bytes = Base64.getDecoder().decode(saved);
            if (bytes.length < 28 || bytes.length > 270_028) return new AgentDeviceList();
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(128, bytes, 0, 12));
            if (!legacy) cipher.updateAAD(DEVICES_AAD);
            byte[] plain = cipher.doFinal(bytes, 12, bytes.length - 12);
            if (!legacy) return AgentDeviceList.decode(plain);
            AgentDeviceList devices = new AgentDeviceList();
            devices.add(AgentConnection.parse(new String(plain, StandardCharsets.UTF_8)));
            writeDevices(devices);
            return devices;
        } catch (Exception error) { return new AgentDeviceList(); }
    }

    void save(String link) throws Exception {
        AgentDeviceList devices = readDevices();
        devices.add(AgentConnection.parse(link));
        writeDevices(devices);
    }

    void select(String identity) throws Exception {
        AgentDeviceList devices = readDevices(); devices.select(identity); writeDevices(devices);
    }

    void forget(String identity) throws Exception {
        AgentDeviceList devices = readDevices(); devices.remove(identity); writeDevices(devices);
    }

    private void writeDevices(AgentDeviceList devices) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, key());
        cipher.updateAAD(DEVICES_AAD);
        byte[] encrypted = cipher.doFinal(devices.encode());
        byte[] bytes = Arrays.copyOf(cipher.getIV(), 12 + encrypted.length);
        System.arraycopy(encrypted, 0, bytes, 12, encrypted.length);
        if (!preferences.edit().putString("devices", Base64.getEncoder().encodeToString(bytes)).remove("pairing").commit()) {
            throw new java.io.IOException("Couldn’t save the device connection.");
        }
    }

    void clear() {
        try { select(null); }
        catch (Exception ignored) { }
    }

    static synchronized SecretKey key() throws Exception {
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
