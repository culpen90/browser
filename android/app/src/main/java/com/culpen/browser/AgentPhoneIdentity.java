package com.culpen.browser;

import android.content.Context;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.X509EncodedKeySpec;
import java.util.Arrays;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;

/** Private identity and approved computer identities stay encrypted by Android Keystore. */
final class AgentPhoneIdentity {
    private static final byte[] AAD = "BrowserAgent/phone-identity/v1".getBytes(StandardCharsets.UTF_8);
    final String id;
    final KeyPair keyPair;
    private final Map<String, String> trusted;
    private final android.content.SharedPreferences preferences;

    private AgentPhoneIdentity(String id, KeyPair keyPair, Map<String, String> trusted, android.content.SharedPreferences preferences) {
        this.id = id; this.keyPair = keyPair; this.trusted = trusted; this.preferences = preferences;
    }

    static synchronized AgentPhoneIdentity load(Context context) throws Exception {
        android.content.SharedPreferences preferences = context.getSharedPreferences("agent-phone-identity", Context.MODE_PRIVATE);
        String saved = preferences.getString("identity", null);
        if (saved != null) {
            byte[] bytes = Base64.getDecoder().decode(saved);
            if (bytes.length < 28 || bytes.length > 64_000) throw new java.io.IOException("Invalid phone identity.");
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, AgentPairingStore.key(), new GCMParameterSpec(128, bytes, 0, 12));
            cipher.updateAAD(AAD);
            try (DataInputStream input = new DataInputStream(new ByteArrayInputStream(cipher.doFinal(bytes, 12, bytes.length - 12)))) {
                int version = input.readInt();
                if (version != 1 && version != 2) throw new java.io.IOException("Invalid phone identity.");
                String id = UUID.fromString(input.readUTF()).toString();
                KeyFactory factory = KeyFactory.getInstance("EC");
                byte[] privateDER = Base64.getDecoder().decode(input.readUTF()), publicDER = Base64.getDecoder().decode(input.readUTF());
                KeyPair pair = new KeyPair(factory.generatePublic(new X509EncodedKeySpec(publicDER)), factory.generatePrivate(new PKCS8EncodedKeySpec(privateDER)));
                int count = input.readInt();
                if (count < 0 || count > 32) throw new java.io.IOException("Invalid trusted devices.");
                Map<String, String> trusted = new HashMap<>();
                for (int i = 0; i < count; i++) {
                    String publicKey = input.readUTF();
                    if (version == 2) trusted.put(publicKey, UUID.fromString(input.readUTF()).toString());
                }
                if (input.read() != -1) throw new java.io.IOException("Invalid phone identity.");
                AgentPhoneIdentity identity = new AgentPhoneIdentity(id, pair, trusted, preferences);
                if (version == 1) identity.save(); // Unassociated prerelease approvals require verification again.
                return identity;
            }
        }
        KeyPairGenerator generator = KeyPairGenerator.getInstance("EC"); generator.initialize(new ECGenParameterSpec("secp256r1"));
        AgentPhoneIdentity identity = new AgentPhoneIdentity(UUID.randomUUID().toString(), generator.generateKeyPair(), new HashMap<>(), preferences);
        identity.save(); return identity;
    }

    synchronized boolean trusts(byte[] publicDER) { return trusted.containsKey(Base64.getEncoder().encodeToString(publicDER)); }
    synchronized boolean trusts(byte[] publicDER, String computerID) {
        return computerID.equals(trusted.get(Base64.getEncoder().encodeToString(publicDER)));
    }
    synchronized void remember(byte[] publicDER, String computerID) throws Exception {
        if (trusted.size() >= 32 && !trusts(publicDER)) throw new java.io.IOException("Too many approved computers.");
        trusted.put(Base64.getEncoder().encodeToString(publicDER), UUID.fromString(computerID).toString()); save();
    }
    synchronized void forget(String computerID) throws Exception {
        trusted.values().removeIf(id -> id.equals(computerID)); save();
    }

    private synchronized void save() throws Exception {
        ByteArrayOutputStream plain = new ByteArrayOutputStream();
        try (DataOutputStream output = new DataOutputStream(plain)) {
            output.writeInt(2); output.writeUTF(id);
            output.writeUTF(Base64.getEncoder().encodeToString(keyPair.getPrivate().getEncoded()));
            output.writeUTF(Base64.getEncoder().encodeToString(keyPair.getPublic().getEncoded()));
            output.writeInt(trusted.size());
            for (Map.Entry<String, String> computer : trusted.entrySet()) { output.writeUTF(computer.getKey()); output.writeUTF(computer.getValue()); }
        }
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, AgentPairingStore.key()); cipher.updateAAD(AAD);
        byte[] encrypted = cipher.doFinal(plain.toByteArray()), combined = Arrays.copyOf(cipher.getIV(), 12 + encrypted.length);
        System.arraycopy(encrypted, 0, combined, 12, encrypted.length);
        if (!preferences.edit().putString("identity", Base64.getEncoder().encodeToString(combined)).commit()) throw new java.io.IOException("Couldn’t save phone identity.");
    }
}
