package com.culpen.browser;

import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Test;
import org.junit.runner.RunWith;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.Arrays;
import java.util.Base64;
import java.util.Map;
import javax.crypto.Cipher;
import javax.crypto.SecretKey;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public final class AgentDevicesTest {
    private final android.app.Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
    private final Context context = instrumentation.getTargetContext();
    private static final String KEY = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    private static final String FIRST = "ca153e73-d573-41cf-87e1-cb64b4567961";
    private static final String SECOND = "ca153e73-d573-41cf-87e1-cb64b4567962";
    private String link(String id, String name) {
        return "browseragent://pair?host=127.0.0.1&port=38765&key=" + KEY + "&id=" + id + "&name=" + name;
    }

    @Test public void selectedComputerSurvivesActivityRestartAndForgetKeepsOthers() throws Exception {
        SharedPreferences preferences = context.getSharedPreferences("agent-connection", Context.MODE_PRIVATE);
        Map<String, ?> original = preferences.getAll();
        preferences.edit().clear().commit();
        MainActivity first = null, second = null;
        try {
            first = launch();
            MainActivity activity = first;
            instrumentation.runOnMainSync(() -> {
                assertTrue(activity.getAgentPanel().connect(link(FIRST, "Office")));
                assertTrue(activity.getAgentPanel().connect(link(SECOND, "Home")));
                assertTrue(activity.getAgentPanel().selectDevice(FIRST));
                activity.finish();
            });
            first = null;
            second = launch();
            MainActivity restored = second;
            instrumentation.runOnMainSync(() -> {
                restored.getAgentPanel().show();
                assertTrue(hasText(restored.getWindow().getDecorView(), "Office · Direct connection"));
            });
            AgentPairingStore store = new AgentPairingStore(context);
            assertEquals(2, store.devices().size());
            assertEquals(FIRST, store.load().identity());
            store.forget(FIRST);
            assertNull(new AgentPairingStore(context).load());
            assertEquals(SECOND, store.devices().get(0).identity());
            String encrypted = preferences.getString("devices", "");
            assertFalse(encrypted.contains("Office"));
            assertFalse(encrypted.contains(KEY));
        } finally {
            if (first != null) { MainActivity activity = first; instrumentation.runOnMainSync(activity::finish); }
            if (second != null) { MainActivity activity = second; instrumentation.runOnMainSync(activity::finish); }
            restore(preferences, original);
        }
    }

    @Test public void migratesExistingEncryptedSinglePairingWithoutLosingIt() throws Exception {
        SharedPreferences preferences = context.getSharedPreferences("agent-connection", Context.MODE_PRIVATE);
        Map<String, ?> original = preferences.getAll();
        preferences.edit().clear().commit();
        try {
            AgentPairingStore store = new AgentPairingStore(context);
            String legacy = "browseragent://pair?host=10.0.2.2&port=8766&key=" + KEY;
            store.save(legacy); // Initializes the existing Android Keystore key.
            KeyStore keys = KeyStore.getInstance("AndroidKeyStore"); keys.load(null);
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, (SecretKey) keys.getKey("browser-agent-pairing", null));
            byte[] encrypted = cipher.doFinal(legacy.getBytes(StandardCharsets.UTF_8));
            byte[] combined = Arrays.copyOf(cipher.getIV(), 12 + encrypted.length);
            System.arraycopy(encrypted, 0, combined, 12, encrypted.length);
            assertTrue(preferences.edit().remove("devices").putString("pairing", Base64.getEncoder().encodeToString(combined)).commit());
            AgentConnection restored = new AgentPairingStore(context).load();
            assertNotNull(restored); assertEquals(legacy, restored.pairingLink());
            assertFalse(preferences.contains("pairing"));
            assertTrue(preferences.contains("devices"));
            store.save(link(FIRST, "Office"));
            assertEquals(2, store.devices().size());
        } finally { restore(preferences, original); }
    }

    @Test public void phoneIdentityPersistsEncryptedAndPerformsNativeKeyAgreement() throws Exception {
        SharedPreferences preferences = context.getSharedPreferences("agent-phone-identity", Context.MODE_PRIVATE);
        Map<String, ?> original = preferences.getAll();
        preferences.edit().clear().commit();
        try {
            AgentPhoneIdentity phone = AgentPhoneIdentity.load(context);
            AgentPhoneIdentity restored = AgentPhoneIdentity.load(context);
            assertEquals(phone.id, restored.id);
            assertArrayEquals(phone.keyPair.getPublic().getEncoded(), restored.keyPair.getPublic().getEncoded());
            java.security.KeyPairGenerator generator = java.security.KeyPairGenerator.getInstance("EC");
            generator.initialize(new java.security.spec.ECGenParameterSpec("secp256r1"));
            java.security.KeyPair computer = generator.generateKeyPair();
            byte[] key = PhoneInviteCrypto.sharedKey(restored.keyPair, computer.getPublic().getEncoded());
            assertEquals(32, key.length); assertTrue(PhoneInviteCrypto.code(key).matches("[0-9]{6}"));
            java.security.KeyPair other = generator.generateKeyPair();
            phone.remember(computer.getPublic().getEncoded(), FIRST);
            phone.remember(other.getPublic().getEncoded(), SECOND);
            assertTrue(phone.trusts(computer.getPublic().getEncoded(), FIRST));
            assertFalse("A trusted key must not silently introduce a different computer identity", phone.trusts(computer.getPublic().getEncoded(), SECOND));
            assertTrue(AgentPhoneIdentity.load(context).trusts(computer.getPublic().getEncoded()));
            phone.forget(FIRST);
            AgentPhoneIdentity revoked = AgentPhoneIdentity.load(context);
            assertFalse(revoked.trusts(computer.getPublic().getEncoded()));
            assertTrue(revoked.trusts(other.getPublic().getEncoded()));
            assertEquals(phone.id, revoked.id);
            assertArrayEquals(phone.keyPair.getPublic().getEncoded(), revoked.keyPair.getPublic().getEncoded());
            String encrypted = preferences.getString("identity", "");
            assertFalse(encrypted.contains(phone.id));
            assertFalse(encrypted.contains(Base64.getEncoder().encodeToString(phone.keyPair.getPrivate().getEncoded())));
        } finally { restore(preferences, original); }
    }

    private void restore(SharedPreferences preferences, Map<String, ?> values) {
        SharedPreferences.Editor editor = preferences.edit().clear();
        for (Map.Entry<String, ?> entry : values.entrySet()) if (entry.getValue() instanceof String) {
            editor.putString(entry.getKey(), (String) entry.getValue());
        }
        editor.commit();
    }
    private MainActivity launch() {
        Intent intent = new Intent(Intent.ACTION_MAIN).setClass(context, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
        return (MainActivity) instrumentation.startActivitySync(intent);
    }
    private boolean hasText(View view, String expected) {
        if (view instanceof TextView && ((TextView) view).getText().toString().equals(expected)) return true;
        if (view instanceof ViewGroup) for (int i = 0; i < ((ViewGroup) view).getChildCount(); i++) {
            if (hasText(((ViewGroup) view).getChildAt(i), expected)) return true;
        }
        return false;
    }
}
