package com.culpen.browser;

import android.content.Intent;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Test;
import org.junit.runner.RunWith;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public class BrowserAgentTest {
    private final android.app.Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();

    @Test public void websiteControlsRequireReviewAndRejectChangedFormSubmission() throws Exception {
        org.junit.Assume.assumeNotNull(android.webkit.WebView.getCurrentWebViewPackage());
        try (ServerSocket server = new ServerSocket(0)) {
            Thread fixture = new Thread(() -> {
                while (!server.isClosed()) try (Socket socket = server.accept()) {
                    BufferedReader reader = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
                    String line;
                    while ((line = reader.readLine()) != null && !line.isEmpty()) { }
                    byte[] body = ("<title>Agent controls</title><h1>Agent controls</h1><input aria-label='Search' id='q'>"
                            + "<input type='password' aria-label='Password' value='hidden-secret'>"
                            + "<button id='show' formmethod='get' onclick=\"document.querySelector('output').textContent='Found '+document.querySelector('#q').value\">Show result</button><output></output>")
                            .getBytes(StandardCharsets.UTF_8);
                    socket.getOutputStream().write(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " + body.length + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                    socket.getOutputStream().write(body);
                } catch (Exception ignored) { }
            });
            fixture.setDaemon(true); fixture.start();
            MainActivity activity = launch();
            try {
                instrumentation.runOnMainSync(() -> activity.navigateCompatibility(URI.create("http://127.0.0.1:" + server.getLocalPort() + "/controls")));
                MobileBrowserAgent.Snapshot page = snapshot(activity);
                MobileBrowserAgent.Element field = null, button = null;
                for (MobileBrowserAgent.Element element : page.elements) {
                    if (element.kind.equals("input") && element.label.equals("Search")) field = element;
                    if (element.kind.equals("button") && element.label.equals("Show result")) button = element;
                    assertFalse(element.label.equals("Password"));
                }
                assertNotNull(field); assertNotNull(button); assertFalse(page.text.contains("hidden-secret"));
                MobileBrowserAgent.Command type = new MobileBrowserAgent.Command("TYPE " + field.id + " opal");
                try { act(activity, type, page, false); fail("Unapproved type succeeded"); }
                catch (java.util.concurrent.ExecutionException expected) { assertTrue(expected.getCause().getMessage().contains("Approve")); }
                act(activity, type, page, true);
                MobileBrowserAgent.Snapshot filled = snapshot(activity);
                assertFalse(filled.text.contains("opal"));
                MobileBrowserAgent.Command click = new MobileBrowserAgent.Command("CLICK " + button.id);
                js(activity, "document.querySelector('#show').setAttribute('formmethod','post'); true");
                try { act(activity, click, filled, true); fail("Changed form override was accepted"); }
                catch (java.util.concurrent.ExecutionException expected) { assertTrue(expected.getCause().getMessage().contains("page changed")); }
                act(activity, click, snapshot(activity), true);
                assertTrue(snapshot(activity).text.contains("Found opal"));
            } finally { instrumentation.runOnMainSync(activity::finish); }
        }
    }

    @Test public void panelClosesAndReopensAndRejectsOldPageActions() throws Exception {
        MainActivity activity = launch();
        try {
            instrumentation.runOnMainSync(() -> activity.getAgentPanel().show());
            press(activity, "Close agent");
            instrumentation.runOnMainSync(() -> assertFalse(activity.getAgentPanel().isOpen()));
            press(activity, "Toggle agent");
            instrumentation.runOnMainSync(() -> assertTrue(activity.getAgentPanel().isOpen()));
            final CompletableFuture<MobileBrowserAgent.Snapshot>[] snapshot = new CompletableFuture[1];
            instrumentation.runOnMainSync(() -> snapshot[0] = activity.observeAgentPage());
            MobileBrowserAgent.Snapshot home = snapshot[0].get(10, TimeUnit.SECONDS);
            instrumentation.runOnMainSync(() -> activity.navigate(URI.create("browser:demo")));
            final CompletableFuture<Void>[] action = new CompletableFuture[1];
            instrumentation.runOnMainSync(() -> {
                try { action[0] = activity.performAgentAction(new MobileBrowserAgent.Command("CLICK 1"), home, false); }
                catch (Exception error) { throw new AssertionError(error); }
            });
            try { action[0].get(5, TimeUnit.SECONDS); fail("Stale action ran"); }
            catch (java.util.concurrent.ExecutionException expected) { assertTrue(expected.getCause().getMessage().contains("page changed")); }
        } finally { instrumentation.runOnMainSync(activity::finish); }
    }

    @Test public void pairedPCFollowsLinkAndAnswersFromActualMacModel() throws Exception {
        String path = InstrumentationRegistry.getArguments().getString("pairFile");
        org.junit.Assume.assumeTrue("Run with a private Mac pairing fixture file", path != null && path.matches("/data/local/tmp/[a-zA-Z0-9._-]+"));
        String pairing;
        try (ParcelFileDescriptor descriptor = instrumentation.getUiAutomation().executeShellCommand("cat " + path);
             java.io.InputStream input = new ParcelFileDescriptor.AutoCloseInputStream(descriptor);
             java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream()) {
            byte[] buffer = new byte[1024]; int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            pairing = output.toString(StandardCharsets.UTF_8.name()).trim();
        }
        AgentConnection.parse(pairing);
        try (ServerSocket server = new ServerSocket(0)) {
            Thread fixture = new Thread(() -> {
                while (!server.isClosed()) try (Socket socket = server.accept()) {
                    BufferedReader reader = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
                    String request = reader.readLine(), line;
                    while ((line = reader.readLine()) != null && !line.isEmpty()) { }
                    String html = request != null && request.contains("/hours") ? "<title>Museum hours</title><h1>Museum hours</h1><p>The museum opens at 10 AM every day.</p>"
                            : "<title>Museum</title><h1>Visit the museum</h1><a href='/hours'>Opening Hours</a>";
                    byte[] body = html.getBytes(StandardCharsets.UTF_8);
                    socket.getOutputStream().write(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " + body.length + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                    socket.getOutputStream().write(body);
                } catch (Exception ignored) { }
            });
            fixture.setDaemon(true); fixture.start();
            MainActivity activity = launch();
            try {
                instrumentation.runOnMainSync(() -> {
                    assertTrue(activity.getAgentPanel().connect(pairing));
                    activity.navigate(URI.create("http://127.0.0.1:" + server.getLocalPort() + "/museum"));
                    activity.getAgentPanel().show();
                });
                awaitLoaded(activity, "Visit the museum");
                instrumentation.runOnMainSync(() -> {
                    EditText task = (EditText) find(activity.getWindow().getDecorView(), "Agent task");
                    assertNotNull(task); task.setText("What time does the museum open?");
                });
                press(activity, "Run agent");
                long deadline = SystemClock.uptimeMillis() + 120_000;
                final boolean[] complete = {false};
                while (SystemClock.uptimeMillis() < deadline) {
                    instrumentation.runOnMainSync(() -> complete[0] = activity.getAgentPanel().logText().contains("10 AM") || activity.getAgentPanel().logText().contains("10 am"));
                    if (complete[0]) break;
                    SystemClock.sleep(100);
                }
                instrumentation.runOnMainSync(() -> {
                    assertTrue("PC model did not return the fixture opening time", complete[0]);
                    assertEquals("/hours", activity.getCurrentAddress().getPath());
                    activity.getAgentPanel().hide();
                    activity.getAgentPanel().show();
                    assertTrue(activity.getAgentPanel().logText().contains("10 AM") || activity.getAgentPanel().logText().contains("10 am"));
                });
            } finally { instrumentation.runOnMainSync(activity::finish); }
        }
    }
    private MainActivity launch() {
        Intent intent = new Intent(Intent.ACTION_MAIN).setClass(instrumentation.getTargetContext(), MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
        return (MainActivity) instrumentation.startActivitySync(intent);
    }
    private MobileBrowserAgent.Snapshot snapshot(MainActivity activity) throws Exception {
        java.util.concurrent.atomic.AtomicReference<CompletableFuture<MobileBrowserAgent.Snapshot>> result = new java.util.concurrent.atomic.AtomicReference<>();
        instrumentation.runOnMainSync(() -> result.set(activity.observeAgentPage()));
        return result.get().get(30, TimeUnit.SECONDS);
    }
    private void act(MainActivity activity, MobileBrowserAgent.Command command, MobileBrowserAgent.Snapshot page, boolean approved) throws Exception {
        java.util.concurrent.atomic.AtomicReference<CompletableFuture<Void>> result = new java.util.concurrent.atomic.AtomicReference<>();
        instrumentation.runOnMainSync(() -> result.set(activity.performAgentAction(command, page, approved)));
        result.get().get(10, TimeUnit.SECONDS);
    }
    private void js(MainActivity activity, String script) throws Exception {
        CompletableFuture<String> result = new CompletableFuture<>();
        instrumentation.runOnMainSync(() -> activity.getCompatibilityView().evaluateJavascript(script, result::complete));
        result.get(5, TimeUnit.SECONDS);
    }
    private void awaitLoaded(MainActivity activity, String text) throws Exception {
        long deadline = SystemClock.uptimeMillis() + 15_000;
        final boolean[] ready = {false};
        while (SystemClock.uptimeMillis() < deadline) {
            instrumentation.runOnMainSync(() -> ready[0] = !activity.isLoading() && activity.getPageView().getTextContent().replaceAll("\\s+", " ").contains(text));
            if (ready[0]) return;
            SystemClock.sleep(50);
        }
        fail("The fixture page did not load");
    }
    private void press(MainActivity activity, String description) {
        instrumentation.runOnMainSync(() -> {
            View button = find(activity.getWindow().getDecorView(), description);
            assertTrue(button instanceof Button); assertTrue(button.isEnabled()); button.performClick();
        });
    }
    private View find(View view, String description) {
        if (view.getContentDescription() != null && description.contentEquals(view.getContentDescription())) return view;
        if (view instanceof ViewGroup) for (int i = 0; i < ((ViewGroup) view).getChildCount(); i++) {
            View result = find(((ViewGroup) view).getChildAt(i), description);
            if (result != null) return result;
        }
        return null;
    }
}
