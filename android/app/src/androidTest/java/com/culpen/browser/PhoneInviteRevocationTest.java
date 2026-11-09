package com.culpen.browser;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.SystemClock;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import java.net.HttpURLConnection;
import java.net.Proxy;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.spec.ECGenParameterSpec;
import java.util.Arrays;
import java.util.Base64;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public final class PhoneInviteRevocationTest {
    @Test public void forgettingComputerInvalidatesItsPendingOfferBeforeModelCanBeSaved() throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        SharedPreferences preferences = context.getSharedPreferences("agent-phone-identity", Context.MODE_PRIVATE);
        Map<String, ?> original = preferences.getAll(); preferences.edit().clear().commit();
        CompletableFuture<Boolean> consent = new CompletableFuture<>(); CountDownLatch offered = new CountDownLatch(1);
        AtomicBoolean saved = new AtomicBoolean();
        AgentPhoneInbox inbox = new AgentPhoneInbox(context, (name, code) -> { offered.countDown(); return consent; }, link -> { saved.set(true); return true; });
        try {
            AgentPhoneIdentity phone = AgentPhoneIdentity.load(context);
            KeyPairGenerator generator = KeyPairGenerator.getInstance("EC"); generator.initialize(new ECGenParameterSpec("secp256r1")); KeyPair computer = generator.generateKeyPair();
            byte[] key = PhoneInviteCrypto.sharedKey(phone.keyPair, computer.getPublic().getEncoded());
            String id = "ca153e73-d573-41cf-87e1-cb64b4567961";
            inbox.start(); long deadline = SystemClock.uptimeMillis() + 10_000;
            while (!inbox.isRunning() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(20);
            assertTrue(inbox.isRunning());
            byte[] offer = envelope(new JSONObject().put("name", "Computer").put("id", id).put("createdAt", System.currentTimeMillis() / 1000), computer, key);
            CompletableFuture<Integer> result = CompletableFuture.supplyAsync(() -> {
                try { return post("offer", offer); } catch (Exception error) { throw new java.util.concurrent.CompletionException(error); }
            });
            assertTrue("Offer never reached the approval dialog", offered.await(10, TimeUnit.SECONDS));
            inbox.forgetComputer(id); consent.complete(true);
            assertEquals(200, result.get(10, TimeUnit.SECONDS).intValue());
            String link = "browseragent://pair?host=127.0.0.1&port=38765&key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&id=" + id;
            byte[] connect = envelope(new JSONObject().put("pairingLink", link).put("createdAt", System.currentTimeMillis() / 1000), computer, key);
            assertEquals("A forgotten pending offer still authorized model delivery", 401, post("connect", connect));
            assertFalse(saved.get()); assertFalse(AgentPhoneIdentity.load(context).trusts(computer.getPublic().getEncoded()));
        } finally {
            consent.complete(false); inbox.destroy();
            SharedPreferences.Editor editor = preferences.edit().clear();
            for (Map.Entry<String, ?> entry : original.entrySet()) if (entry.getValue() instanceof String) editor.putString(entry.getKey(), (String) entry.getValue());
            editor.commit();
        }
    }

    private byte[] envelope(JSONObject plain, KeyPair computer, byte[] key) throws Exception {
        byte[] nonce = new byte[12]; new java.security.SecureRandom().nextBytes(nonce);
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce)); cipher.updateAAD(PhoneInviteCrypto.REQUEST_AAD);
        byte[] encrypted = cipher.doFinal(plain.toString().getBytes(StandardCharsets.UTF_8)), combined = Arrays.copyOf(nonce, 12 + encrypted.length); System.arraycopy(encrypted, 0, combined, 12, encrypted.length);
        return new JSONObject().put("publicKey", Base64.getEncoder().encodeToString(computer.getPublic().getEncoded()))
                .put("data", Base64.getEncoder().encodeToString(combined)).toString().getBytes(StandardCharsets.UTF_8);
    }
    private int post(String path, byte[] body) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL("http://127.0.0.1:" + AgentPhoneInbox.PORT + "/v1/" + path).openConnection(Proxy.NO_PROXY);
        try {
            connection.setConnectTimeout(2000); connection.setReadTimeout(10_000); connection.setRequestMethod("POST"); connection.setDoOutput(true);
            connection.setFixedLengthStreamingMode(body.length); connection.setRequestProperty("Content-Type", "application/json");
            try (java.io.OutputStream output = connection.getOutputStream()) { output.write(body); }
            return connection.getResponseCode();
        } finally { connection.disconnect(); }
    }
}
