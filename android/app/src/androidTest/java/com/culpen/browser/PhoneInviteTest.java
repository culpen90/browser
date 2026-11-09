package com.culpen.browser;

import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.SystemClock;
import android.widget.TextView;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import static org.junit.Assert.*;

/** Opt-in cross-platform fixture. The coordinator forwards port38766 to the emulator. */
@RunWith(AndroidJUnit4.class)
public final class PhoneInviteTest {
    private final android.app.Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
    private final Context context = instrumentation.getTargetContext();

    @Test public void receiveComputerOfferAndAttachViaPresence() throws Exception {
        org.junit.Assume.assumeTrue("Requires the live Mac invitation fixture", "true".equals(InstrumentationRegistry.getArguments().getString("phoneInviteFixture")));
        SharedPreferences paired = context.getSharedPreferences("agent-connection", Context.MODE_PRIVATE);
        SharedPreferences identity = context.getSharedPreferences("agent-phone-identity", Context.MODE_PRIVATE);
        Map<String, ?> oldPaired = paired.getAll(), oldIdentity = identity.getAll();
        paired.edit().clear().commit(); identity.edit().clear().commit();
        String[] markers = {"phone-invite-link.txt", "phone-invite-code.txt", "phone-invite-paired.txt", "phone-invite-awaiting-attach.txt", "phone-invite-model-answer.txt", "phone-invite-done.txt"};
        for (String marker : markers) new File(context.getFilesDir(), marker).delete();
        MainActivity activity = launch();
        try {
            long deadline = SystemClock.uptimeMillis() + 180_000;
            final String[] link = {null};
            while (link[0] == null && SystemClock.uptimeMillis() < deadline) {
                instrumentation.runOnMainSync(() -> {
                    try { link[0] = activity.getAgentPanel().phonePairingLink("127.0.0.1"); } catch (Exception ignored) { }
                });
                if (link[0] == null) SystemClock.sleep(100);
            }
            assertNotNull("Phone inbox did not start", link[0]); write("phone-invite-link.txt", link[0]);

            final boolean[] accepted = {false};
            while (!accepted[0] && SystemClock.uptimeMillis() < deadline) {
                instrumentation.runOnMainSync(() -> {
                    try {
                        java.lang.reflect.Field field = BrowserAgentPanel.class.getDeclaredField("phoneReview"); field.setAccessible(true);
                        AlertDialog dialog = (AlertDialog) field.get(activity.getAgentPanel());
                        if (dialog == null || !dialog.isShowing()) return;
                        TextView message = dialog.findViewById(android.R.id.message);
                        Matcher match = Pattern.compile("Connection code: ([0-9]{6})").matcher(message.getText());
                        assertTrue("Phone invitation omitted its verification code", match.find());
                        write("phone-invite-code.txt", match.group(1));
                        dialog.getButton(AlertDialog.BUTTON_POSITIVE).performClick(); accepted[0] = true;
                    } catch (Exception error) { throw new AssertionError(error); }
                });
                if (!accepted[0]) SystemClock.sleep(100);
            }
            assertTrue("The computer did not offer a connection", accepted[0]);
            AgentPairingStore store = new AgentPairingStore(context);
            while (store.load() == null && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(100);
            AgentConnection computer = store.load(); assertNotNull("The confirmed model connection was not saved", computer);
            write("phone-invite-paired.txt", computer.identity());

            JSONObject question = new JSONObject().put("system", "Answer the question briefly using the provided facts.")
                    .put("user", "The museum opens at 10 AM every day. What time does the museum open?").put("maxTokens", 40);
            JSONObject answer = new JSONObject(new String(computer.generate(question.toString().getBytes(StandardCharsets.UTF_8)), StandardCharsets.UTF_8));
            assertFalse(answer.has("error")); assertTrue("Actual computer model did not answer the fixture fact", answer.getString("text").contains("10"));
            write("phone-invite-model-answer.txt", answer.getString("text"));

            instrumentation.runOnMainSync(() -> assertTrue(activity.getAgentPanel().selectDevice(null)));
            assertNull(store.load()); write("phone-invite-awaiting-attach.txt", "ready");
            while (store.load() == null && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(100);
            assertNotNull("Selecting the phone on the computer did not attach its model", store.load());
            assertEquals(computer.identity(), store.load().identity());
            write("phone-invite-done.txt", "paired, answered, and attached through outbound presence");
        } finally {
            instrumentation.runOnMainSync(activity::finish);
            instrumentation.waitForIdleSync();
            restore(paired, oldPaired); restore(identity, oldIdentity);
        }
    }

    private MainActivity launch() {
        Intent intent = new Intent(Intent.ACTION_MAIN).setClass(context, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
        return (MainActivity) instrumentation.startActivitySync(intent);
    }
    private void write(String name, String value) throws Exception {
        try (FileOutputStream output = new FileOutputStream(new File(context.getFilesDir(), name))) { output.write(value.getBytes(StandardCharsets.UTF_8)); }
    }
    private void restore(SharedPreferences preferences, Map<String, ?> values) {
        SharedPreferences.Editor editor = preferences.edit().clear();
        for (Map.Entry<String, ?> entry : values.entrySet()) if (entry.getValue() instanceof String) editor.putString(entry.getKey(), (String) entry.getValue());
        editor.commit();
    }
}
