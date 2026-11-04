package com.culpen.browser;

import android.content.Intent;
import android.graphics.RectF;
import android.os.SystemClock;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
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
import java.util.concurrent.atomic.AtomicBoolean;

import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public class MainActivityTest {
    private MainActivity activity;
    private final android.app.Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();

    @Before public void launch() throws Exception {
        Intent intent = new Intent(Intent.ACTION_MAIN).setClass(instrumentation.getTargetContext(), MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
        activity = (MainActivity) instrumentation.startActivitySync(intent);
        awaitText("A place to begin.");
    }
    @After public void finish() { if (activity != null) instrumentation.runOnMainSync(() -> activity.finish()); }
    private void awaitText(String text) throws Exception {
        long deadline = SystemClock.uptimeMillis() + 15_000;
        AtomicBoolean ready = new AtomicBoolean();
        while (SystemClock.uptimeMillis() < deadline) {
            instrumentation.runOnMainSync(() -> ready.set(!activity.isLoading() && activity.getPageView().getTextContent().replaceAll("\\s+", " ").contains(text)));
            if (ready.get()) return;
            SystemClock.sleep(40);
        }
        final String[] actual = {""}; instrumentation.runOnMainSync(() -> actual[0] = activity.getPageView().getTextContent());
        fail("Page did not display: " + text + "; actual: " + actual[0]);
    }
    private Button button(View view, String description) {
        if (view instanceof Button && description.contentEquals(view.getContentDescription())) return (Button) view;
        if (view instanceof ViewGroup) for (int i = 0; i < ((ViewGroup) view).getChildCount(); i++) { Button match = button(((ViewGroup) view).getChildAt(i), description); if (match != null) return match; }
        return null;
    }
    private void press(String description) {
        instrumentation.runOnMainSync(() -> { Button b = button(activity.getWindow().getDecorView(), description); assertNotNull(b); assertTrue(b.isEnabled()); b.performClick(); });
    }
    private void tapLink(String ending) {
        instrumentation.runOnMainSync(() -> {
            PageView page = activity.getPageView();
            for (int i = 0; i < page.getLinkCount(); i++) {
                if (page.getLinkUri(i).toString().endsWith(ending)) {
                    RectF bounds = page.getLinkBounds(i); long time = SystemClock.uptimeMillis();
                    MotionEvent down = MotionEvent.obtain(time, time, MotionEvent.ACTION_DOWN, bounds.centerX(), bounds.centerY(), 0);
                    MotionEvent up = MotionEvent.obtain(time, time + 10, MotionEvent.ACTION_UP, bounds.centerX(), bounds.centerY(), 0);
                    page.dispatchTouchEvent(down); page.dispatchTouchEvent(up); down.recycle(); up.recycle(); return;
                }
            }
            fail("Missing link: " + ending);
        });
    }
    @Test public void bundledPageLinksHistoryAndFragments() throws Exception {
        instrumentation.runOnMainSync(() -> activity.navigate(URI.create("browser:demo")));
        awaitText("Engine Garden");
        assertFalse(activity.getPageView().getTextContent().contains("SCRIPT MUST NOT EXECUTE"));
        tapLink("#finish"); awaitText("You reached the finish.");
        // Page text becomes available during measure, before the posted anchor scroll.
        // Observe the scroll itself rather than assuming layout and text finish together.
        long deadline = SystemClock.uptimeMillis() + 5000;
        AtomicBoolean scrolled = new AtomicBoolean();
        while (SystemClock.uptimeMillis() < deadline) {
            instrumentation.runOnMainSync(() -> scrolled.set(activity.getPageScroll().getScrollY() > 0));
            if (scrolled.get()) break;
            SystemClock.sleep(40);
        }
        instrumentation.runOnMainSync(() -> assertTrue("Anchor address=" + activity.getCurrentAddress()
                + ", scroll=" + activity.getPageScroll().getScrollY() + ", pageHeight=" + activity.getPageView().getHeight()
                + ", viewport=" + activity.getPageScroll().getHeight(), activity.getPageScroll().getScrollY() > 0));
        tapLink("second.html"); awaitText("Another page, another beginning.");
        press("Back"); awaitText("Engine Garden");
        // Resubmitting the current URL must preserve its forward entry and mode metadata.
        instrumentation.runOnMainSync(() -> activity.navigate(activity.getCurrentAddress()));
        awaitText("Engine Garden");
        press("Forward"); awaitText("Another page, another beginning.");
        press("Home"); awaitText("A place to begin.");
    }
    @Test public void networkLoadAndSupersededRequestCannotReplaceHome() throws Exception {
        instrumentation.runOnMainSync(() -> activity.navigate(URI.create("browser:demo"))); awaitText("Engine Garden");
        tapLink("second.html"); awaitText("Another page, another beginning.");
        try (ServerSocket server = new ServerSocket(0)) {
            Thread responder = new Thread(() -> {
                for (int i = 0; i < 3; i++) try (Socket socket = server.accept()) {
                    BufferedReader reader = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
                    String request = reader.readLine(); String line;
                    while ((line = reader.readLine()) != null && !line.isEmpty()) { }
                    if (request != null && request.contains("/slow")) SystemClock.sleep(700);
                    byte[] body = "<title>Network test</title><h1>Network arrived</h1><a href='/slow'>Slow page</a>".getBytes(StandardCharsets.UTF_8);
                    socket.getOutputStream().write(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " + body.length + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                    socket.getOutputStream().write(body);
                } catch (Exception ignored) { }
            }); responder.setDaemon(true); responder.start();
            URI target = URI.create("http://127.0.0.1:" + server.getLocalPort() + "/page");
            instrumentation.runOnMainSync(() -> activity.navigate(target)); awaitText("Network arrived");
            press("Back"); awaitText("Another page, another beginning.");
            press("Forward"); awaitText("Network arrived");
            tapLink("/slow");
            press("Home"); awaitText("A place to begin.");
            SystemClock.sleep(1000);
            instrumentation.runOnMainSync(() -> assertEquals(URI.create("browser:home"), activity.getCurrentAddress()));
            awaitText("A place to begin.");
        }
    }
    @Test public void connectionFailureShowsRecoverablePageAndBackWorks() throws Exception {
        int unused; try (ServerSocket socket = new ServerSocket(0)) { unused = socket.getLocalPort(); }
        URI target = URI.create("http://127.0.0.1:" + unused + "/missing");
        instrumentation.runOnMainSync(() -> activity.navigate(target)); awaitText("This page couldn’t be loaded.");
        press("Back"); awaitText("A place to begin.");
    }
    @Test public void restoredExternalLaunchRetainsCurrentPageAndHistory() throws Exception {
        instrumentation.runOnMainSync(() -> activity.setIntent(new Intent(Intent.ACTION_VIEW, android.net.Uri.parse("https://example.com"))));
        instrumentation.runOnMainSync(() -> activity.navigate(URI.create("browser:demo")));
        awaitText("Engine Garden");
        tapLink("second.html"); awaitText("Another page, another beginning.");
        android.app.Instrumentation.ActivityMonitor monitor = instrumentation.addMonitor(MainActivity.class.getName(), null, false);
        instrumentation.runOnMainSync(() -> activity.recreate());
        MainActivity recreated = (MainActivity) instrumentation.waitForMonitorWithTimeout(monitor, 10_000);
        instrumentation.removeMonitor(monitor);
        assertNotNull("Activity recreated", recreated); activity = recreated;
        awaitText("Another page, another beginning.");
        press("Back"); awaitText("Engine Garden");
        press("Back"); awaitText("A place to begin.");
    }
}
