package com.culpen.browser;

import android.app.Instrumentation;
import android.content.Intent;
import android.os.SystemClock;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.widget.Button;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import static org.junit.Assert.*;

/** Controlled local site exercises real JavaScript, POST sign-in, storage and window.opener. */
@RunWith(AndroidJUnit4.class)
public class CompatibilityTest {
    private final Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
    private MainActivity activity;
    private Fixture fixture;
    @Before public void launch() throws Exception {
        fixture = new Fixture();
        Intent intent = new Intent(Intent.ACTION_MAIN).setClass(instrumentation.getTargetContext(), MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
        activity = (MainActivity) instrumentation.startActivitySync(intent);
    }
    @After public void finish() throws Exception {
        if (activity != null) instrumentation.runOnMainSync(() -> activity.finish());
        if (fixture != null) fixture.close();
    }
    private String js(String script) throws Exception {
        AtomicReference<String> result = new AtomicReference<>(); CountDownLatch done = new CountDownLatch(1);
        instrumentation.runOnMainSync(() -> activity.getCompatibilityView().evaluateJavascript(script, value -> { result.set(value); done.countDown(); }));
        assertTrue("JavaScript callback", done.await(5, TimeUnit.SECONDS)); return result.get();
    }
    private void awaitJs(String expression, String expected) throws Exception {
        long deadline = SystemClock.uptimeMillis() + 15_000; String actual = "";
        while (SystemClock.uptimeMillis() < deadline) {
            actual = js(expression); if (actual.equals(expected)) return; SystemClock.sleep(60);
        }
        fail("Expected " + expected + " but JavaScript returned " + actual);
    }
    private Button button(View root, String label) {
        if (root instanceof Button && label.contentEquals(root.getContentDescription())) return (Button) root;
        if (root instanceof ViewGroup) for (int i = 0; i < ((ViewGroup) root).getChildCount(); i++) {
            Button result = button(((ViewGroup) root).getChildAt(i), label); if (result != null) return result;
        }
        return null;
    }
    private void press(String label) {
        instrumentation.runOnMainSync(() -> {
            Button target = button(activity.getWindow().getDecorView(), label); assertNotNull(label, target); assertTrue(label, target.isEnabled()); target.performClick();
        });
    }
    private void awaitAddress(String ending) throws Exception {
        long deadline = SystemClock.uptimeMillis() + 10_000; AtomicReference<String> current = new AtomicReference<>();
        while (SystemClock.uptimeMillis() < deadline) {
            instrumentation.runOnMainSync(() -> current.set(activity.getCurrentAddress().toString()));
            if (current.get().endsWith(ending)) return; SystemClock.sleep(50);
        }
        fail("Address did not end in " + ending + ": " + current.get());
    }
    @Test public void formsCookiesStorageSpaAndHistoryWorkAcrossNativeBoundary() throws Exception {
        instrumentation.runOnMainSync(() -> activity.navigateCompatibility(fixture.url("/login")));
        awaitJs("document.body.innerText.includes('JavaScript ready')", "true");
        Instrumentation.ActivityMonitor monitor = instrumentation.addMonitor(MainActivity.class.getName(), null, false);
        instrumentation.runOnMainSync(() -> activity.recreate());
        MainActivity recreated = (MainActivity) instrumentation.waitForMonitorWithTimeout(monitor, 10_000);
        instrumentation.removeMonitor(monitor);
        assertNotNull("Activity recreated", recreated); activity = recreated;
        awaitJs("document.body.innerText.includes('JavaScript ready')", "true");
        instrumentation.runOnMainSync(() -> {
            WebSettings settings = activity.getCompatibilityView().getSettings();
            assertTrue(settings.getJavaScriptEnabled()); assertTrue(settings.getDomStorageEnabled());
            assertFalse(settings.getAllowFileAccess()); assertFalse(settings.getAllowContentAccess());
            assertEquals(WebSettings.MIXED_CONTENT_NEVER_ALLOW, settings.getMixedContentMode());
        });
        js("document.getElementById('user').value='fixture-user';document.getElementById('form').requestSubmit();");
        awaitJs("document.body.innerText.includes('Signed in fixture-user')", "true");
        assertEquals(1, fixture.posts.get());
        awaitJs("localStorage.getItem('fixture')", "\"retained\"");
        awaitJs("document.cookie.includes('fixtureSession=yes')", "false");
        js("history.pushState({},'', '/session?view=comments');document.getElementById('view').textContent='comments';");
        awaitAddress("/session?view=comments");
        press("Back"); awaitAddress("/session");
        press("Back"); awaitAddress("/login");
        press("Back"); awaitAddress("browser:home");
        instrumentation.runOnMainSync(() -> assertFalse(activity.isCompatibilityVisible()));
        press("Forward"); awaitAddress("/login");
        press("Forward"); awaitAddress("/session");
        awaitJs("document.body.innerText.includes('Signed in fixture-user')", "true");
        assertEquals("History must restore the native POST entry without resubmitting it", 1, fixture.posts.get());
        instrumentation.runOnMainSync(() -> activity.navigate(URI.create("browser:home")));
        instrumentation.runOnMainSync(() -> activity.navigateCompatibility(fixture.url("/cookie")));
        awaitJs("document.body.innerText.includes('Cookie retained')", "true");
        awaitJs("localStorage.getItem('fixture')", "\"retained\"");
        instrumentation.runOnMainSync(() -> activity.navigate(fixture.url("/plain")));
        instrumentation.runOnMainSync(() -> assertFalse("Manually entering another site returns to the independent engine", activity.isCompatibilityVisible()));
    }
    @Test public void popupRetainsOpenerAndCanCloseItself() throws Exception {
        instrumentation.runOnMainSync(() -> activity.navigateCompatibility(fixture.url("/login")));
        awaitJs("document.body.innerText.includes('JavaScript ready')", "true");
        String coordinates = js("(function(){var r=document.getElementById('popup').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2];})()");
        org.json.JSONArray values = new org.json.JSONArray(coordinates);
        float x = (float) values.getDouble(0), y = (float) values.getDouble(1);
        instrumentation.runOnMainSync(() -> {
            WebView view = activity.getCompatibilityView();
            @SuppressWarnings("deprecation") float scale = view.getScale();
            long time = SystemClock.uptimeMillis();
            MotionEvent down = MotionEvent.obtain(time, time, MotionEvent.ACTION_DOWN, x * scale, y * scale, 0);
            MotionEvent up = MotionEvent.obtain(time, time + 80, MotionEvent.ACTION_UP, x * scale, y * scale, 0);
            view.dispatchTouchEvent(down); view.dispatchTouchEvent(up); down.recycle(); up.recycle();
        });
        awaitJs("document.getElementById('popup-result').textContent", "\"popup returned\"");
        awaitAddress("/login");
    }
    private static final class Fixture implements AutoCloseable {
        final ServerSocket listener = new ServerSocket(0);
        final AtomicInteger posts = new AtomicInteger();
        final java.util.concurrent.ExecutorService workers = java.util.concurrent.Executors.newCachedThreadPool();
        volatile boolean closed;
        Fixture() throws Exception {
            workers.submit(() -> {
                while (!closed) try {
                    Socket socket = listener.accept(); workers.submit(() -> respond(socket));
                } catch (Exception ignored) { }
            });
        }
        URI url(String path) { return URI.create("http://127.0.0.1:" + listener.getLocalPort() + path); }
        void respond(Socket socket) {
            try (Socket connection = socket) {
                connection.setSoTimeout(5000);
                BufferedReader input = new BufferedReader(new InputStreamReader(connection.getInputStream(), StandardCharsets.UTF_8));
                String request = input.readLine(); if (request == null) return;
                int length = 0; String cookie = "";
                for (String line; (line = input.readLine()) != null && !line.isEmpty();) {
                    if (line.toLowerCase(java.util.Locale.ROOT).startsWith("content-length:")) length = Integer.parseInt(line.split(":", 2)[1].trim());
                    if (line.toLowerCase(java.util.Locale.ROOT).startsWith("cookie:")) cookie = line;
                }
                String path = request.split(" ")[1]; char[] posted = new char[length]; int read = 0;
                while (read < length) { int count = input.read(posted, read, length - read); if (count < 0) break; read += count; }
                boolean post = request.startsWith("POST ");
                String body;
                if (path.startsWith("/session")) {
                    if (post) posts.incrementAndGet();
                    body = "<h1>Signed in " + (post && new String(posted).contains("user=fixture-user") ? "fixture-user" : "missing user") + "</h1><div id='view'>posts</div>";
                } else if (path.equals("/popup")) {
                    body = "<script>opener.document.getElementById('popup-result').textContent='popup returned';window.close();</script>";
                } else if (path.equals("/cookie")) body = "<h1>" + (cookie.contains("fixtureSession=yes") ? "Cookie retained" : "Cookie missing") + "</h1>";
                else body = "<h1 id='ready'>Loading</h1><form id='form' action='/session' method='post'><input id='user' name='user'><button>Sign in fixture</button></form>"
                            + "<button id='popup' style='font-size:24px;margin:20px' onclick=\"var w=window.open('', 'fixtureAuth');w.location='/popup';\">Open popup</button><p id='popup-result'>waiting</p>"
                            + "<script>document.getElementById('ready').textContent='JavaScript ready';localStorage.setItem('fixture','retained');</script>";
                byte[] bytes = ("<!doctype html><meta name='viewport' content='width=device-width,initial-scale=1'><title>Compatibility fixture</title>" + body).getBytes(StandardCharsets.UTF_8);
                String header = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " + bytes.length + "\r\n"
                        + (post ? "Set-Cookie: fixtureSession=yes; Max-Age=3600; Path=/; HttpOnly; SameSite=Lax\r\n" : "") + "\r\n";
                connection.getOutputStream().write(header.getBytes(StandardCharsets.US_ASCII)); connection.getOutputStream().write(bytes);
            } catch (Exception ignored) { }
        }
        @Override public void close() throws Exception { closed = true; listener.close(); workers.shutdownNow(); }
    }
}
