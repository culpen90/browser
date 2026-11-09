package com.culpen.browser;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.Application;
import android.app.UiAutomation;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ActivityInfo;
import android.net.ConnectivityManager;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.os.Bundle;
import android.os.PowerManager;
import android.os.SystemClock;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.EditText;
import android.widget.TextView;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import static org.junit.Assert.*;

/** Opt-in cellular test on a physical phone using an isolated debug profile. */
@RunWith(AndroidJUnit4.class)
public final class PhysicalInternetTest {
    private final android.app.Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
    private final Context context = instrumentation.getTargetContext();
    private JSONObject lastDiagnostic;
    private final AtomicBoolean activityResumed = new AtomicBoolean();
    private volatile String lastLifecycle = "not-created";
    private volatile long lifecycleChangedAt;
    private MainActivity primaryActivity;
    private final List<MainActivity> createdActivities = new ArrayList<>();

    @Test public void cellularPhoneUsesRealComputerModelAndReceivesComputerSelection() throws Exception {
        org.junit.Assume.assumeTrue("Requires the coordinated physical-phone WAN fixture",
                "true".equals(InstrumentationRegistry.getArguments().getString("physicalInternetFixture")));
        if (Build.VERSION.SDK_INT < 29) throw new org.junit.AssumptionViolatedException("Shell permission adoption requires API29 or newer.");
        assertEquals("This fixture must never alter the installed release profile", "com.culpen.browser.debug", context.getPackageName());
        assertNotEquals("Emulators cannot prove a cellular WAN connection", "1", shell("getprop ro.kernel.qemu"));
        String serial = shell("getprop ro.serialno");
        String expectedSerial = InstrumentationRegistry.getArguments().getString("expectedSerial");
        assertTrue("Pass expectedSerial for the physical phone", expectedSerial != null && !expectedSerial.isEmpty());
        assertTrue("The connected device does not match expectedSerial", expectedSerial.equals(serial));
        String publicHost = InstrumentationRegistry.getArguments().getString("expectedPublicHost");
        assertTrue("Pass expectedPublicHost for the model endpoint", publicHost != null && !publicHost.isEmpty());
        String pairing = readPrivate("physical-internet-pairing.txt").trim();
        AgentConnection computer = AgentConnection.parse(pairing);
        assertEquals("Use the actual router WAN endpoint, never a LAN or forwarded ADB address", publicHost, computer.host);
        InetAddress publicAddress = InetAddress.getByName(computer.host);
        assertFalse(publicAddress.isAnyLocalAddress()); assertFalse(publicAddress.isLoopbackAddress());
        assertFalse(publicAddress.isLinkLocalAddress()); assertFalse(publicAddress.isSiteLocalAddress());

        for (String marker : new String[]{"physical-internet-network.json", "physical-internet-answer.txt", "physical-internet-ready-to-attach.txt", "physical-internet-phone-id.txt", "physical-internet-done.json", "physical-internet-failed.json", "physical-internet-agent-log.txt", "physical-internet-diagnostic.json"}) {
            new File(context.getFilesDir(), marker).delete();
        }
        SharedPreferences preferences = context.getSharedPreferences("agent-connection", Context.MODE_PRIVATE);
        Map<String, ?> original = preferences.getAll();
        UiAutomation automation = instrumentation.getUiAutomation();
        ConnectivityManager manager = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
        assertNotNull(manager);
        Network originalBinding = null;
        Network cellular = null;
        AtomicBoolean lost = new AtomicBoolean();
        CompletableFuture<Network> available = new CompletableFuture<>();
        ConnectivityManager.NetworkCallback callback = new ConnectivityManager.NetworkCallback() {
            private void consider(Network network) {
                try {
                    NetworkCapabilities capabilities = manager.getNetworkCapabilities(network);
                    if (capabilities != null && capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
                            && !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                            && capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) available.complete(network);
                } catch (RuntimeException denied) { available.completeExceptionally(denied); }
            }
            @Override public void onAvailable(Network network) { consider(network); }
            @Override public void onCapabilitiesChanged(Network network, NetworkCapabilities capabilities) { consider(network); }
            @Override public void onUnavailable() { available.completeExceptionally(new java.io.IOException("No cellular internet network became available.")); }
            @Override public void onLost(Network network) { if (network.equals(available.getNow(null))) lost.set(true); }
        };
        boolean adopted = false, requested = false, bound = false;
        Application application = (Application) context.getApplicationContext();
        Application.ActivityLifecycleCallbacks lifecycle = new Application.ActivityLifecycleCallbacks() {
            private void record(Activity current, String event, boolean resumed) {
                if (current != primaryActivity) return;
                lastLifecycle = event; activityResumed.set(resumed); lifecycleChangedAt = System.currentTimeMillis();
            }
            @Override public void onActivityCreated(Activity current, Bundle state) {
                if (current instanceof MainActivity) {
                    MainActivity created = (MainActivity) current; createdActivities.add(created);
                    if (primaryActivity == null) primaryActivity = created;
                    // Keep only this fixture's foreground viewport stable; user auto-rotate settings stay intact.
                    created.setRequestedOrientation(ActivityInfo.SCREEN_ORIENTATION_LOCKED);
                    created.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                }
                record(current, "created", false);
            }
            @Override public void onActivityStarted(Activity current) { record(current, "started", false); }
            @Override public void onActivityResumed(Activity current) { record(current, "resumed", true); }
            @Override public void onActivityPaused(Activity current) { record(current, "paused", false); }
            @Override public void onActivityStopped(Activity current) { record(current, "stopped", false); }
            @Override public void onActivitySaveInstanceState(Activity current, Bundle state) { }
            @Override public void onActivityDestroyed(Activity current) { record(current, "destroyed", false); }
        };
        application.registerActivityLifecycleCallbacks(lifecycle);
        MainActivity activity = null;
        JSONObject evidence = new JSONObject().put("model", Build.MODEL).put("serialVerified", true).put("sdk", Build.VERSION.SDK_INT)
                .put("emulator", false).put("publicHost", computer.host).put("publicPort", computer.port).put("computerID", computer.identity());
        try {
            automation.adoptShellPermissionIdentity(Manifest.permission.ACCESS_NETWORK_STATE, Manifest.permission.CHANGE_NETWORK_STATE);
            adopted = true;
            originalBinding = manager.getBoundNetworkForProcess();
            NetworkRequest request = new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build();
            manager.requestNetwork(request, callback, 45_000); requested = true;
            cellular = available.get(50, TimeUnit.SECONDS);
            assertTrue("The platform refused a cellular-only process binding; no Wi-Fi fallback is allowed", manager.bindProcessToNetwork(cellular));
            bound = true;
            assertEquals(cellular, manager.getBoundNetworkForProcess());
            addCellularEvidence(evidence, manager, cellular, lost);
            AgentPhoneIdentity identity = AgentPhoneIdentity.load(context);
            evidence.put("phoneID", identity.id);
            write("physical-internet-network.json", evidence.toString(2));
            write("physical-internet-phone-id.txt", identity.id);

            try (Museum fixture = new Museum()) {
                activity = launch(); MainActivity current = activity;
                instrumentation.runOnMainSync(() -> {
                    current.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                    assertTrue(current.getAgentPanel().connect(pairing));
                    current.navigate(fixture.url()); current.getAgentPanel().show();
                });
                awaitPage(current, "Visit the museum");
                persistDiagnostic(captureDiagnostic(current, "before-agent"));
                instrumentation.runOnMainSync(() -> {
                    EditText task = (EditText) find(current.getWindow().getDecorView(), "Agent task");
                    assertNotNull(task); task.setText("What time does the museum open?");
                    View run = find(current.getWindow().getDecorView(), "Run agent");
                    assertNotNull(run); assertTrue(run.isEnabled()); run.performClick();
                });
                long deadline = SystemClock.uptimeMillis() + 180_000;
                long nextDiagnostic = 0;
                String previousState = "";
                String answer = ""; boolean answered = false;
                while (SystemClock.uptimeMillis() < deadline) {
                    JSONObject diagnostic = captureDiagnostic(current, "waiting-for-model");
                    answer = diagnostic.optString("agentLog");
                    String state = diagnostic.optString("state"), path = diagnostic.optString("currentPath");
                    String observation = answer + "\n" + diagnostic.optString("currentURL") + "\n" + state
                            + "\n" + diagnostic.optString("approvalMessage");
                    if (!observation.equals(previousState) || SystemClock.uptimeMillis() >= nextDiagnostic) {
                        persistDiagnostic(diagnostic); previousState = observation; nextDiagnostic = SystemClock.uptimeMillis() + 2_000;
                    }
                    if ((answer.contains("10 AM") || answer.contains("10 am")) && "/hours".equals(path)) { answered = true; break; }
                    if (answer.contains("Couldn’t reach") || answer.contains("rejected this connection") || answer.contains("Couldn’t verify")) {
                        throw new AssertionError("The physical cellular model connection failed: " + answer);
                    }
                    if (diagnostic.optBoolean("runEnabled") && (state.equals("Complete") || state.equals("Couldn’t finish") || state.equals("Stopped"))) {
                        throw new AssertionError("The agent finished without the required navigation and answer. State=" + state + "; URL=" + diagnostic.optString("currentURL"));
                    }
                    SystemClock.sleep(100);
                }
                assertTrue("The actual computer model did not navigate to Opening Hours and answer the museum fact", answered);
                persistDiagnostic(captureDiagnostic(current, "model-answered"));
                addCellularEvidence(evidence, manager, cellular, lost);
                evidence.put("modelAnswered", true).put("navigatedPath", "/hours").put("computerID", computer.identity());
                write("physical-internet-answer.txt", answer);
                write("physical-internet-network.json", evidence.toString(2));
                instrumentation.runOnMainSync(() -> assertTrue(current.getAgentPanel().selectDevice(null)));
                AgentPairingStore store = new AgentPairingStore(context);
                assertNull("The phone must be deselected before computer-initiated attach is tested", store.load());
                write("physical-internet-ready-to-attach.txt", identity.id);
                deadline = SystemClock.uptimeMillis() + 180_000;
                nextDiagnostic = 0;
                while (store.load() == null && SystemClock.uptimeMillis() < deadline) {
                    if (SystemClock.uptimeMillis() >= nextDiagnostic) {
                        persistDiagnostic(captureDiagnostic(current, "waiting-for-computer-selection")); nextDiagnostic = SystemClock.uptimeMillis() + 2_000;
                    }
                    SystemClock.sleep(100);
                }
                assertNotNull("Selecting this cellular phone on the computer did not attach the model", store.load());
                assertEquals(computer.identity(), store.load().identity());
                addCellularEvidence(evidence, manager, cellular, lost);
                persistDiagnostic(captureDiagnostic(current, "attached"));
                evidence.put("success", true).put("attached", true);
                write("physical-internet-done.json", evidence.toString(2));
            }
        } catch (Throwable failure) {
            if (activity != null) {
                try { persistDiagnostic(captureDiagnostic(activity, "failed")); }
                catch (Throwable captureFailure) { evidence.put("diagnosticCaptureError", captureFailure.getClass().getSimpleName() + ": " + captureFailure.getMessage()); }
            }
            if (lastDiagnostic != null) evidence.put("diagnostic", lastDiagnostic);
            evidence.put("success", false).put("failure", failure.getClass().getSimpleName() + ": " + failure.getMessage());
            write("physical-internet-failed.json", evidence.toString(2));
            throw failure;
        } finally {
            try {
                MainActivity current = activity;
                instrumentation.runOnMainSync(() -> {
                    if (current != null && !createdActivities.contains(current)) createdActivities.add(current);
                    for (MainActivity created : new ArrayList<>(createdActivities)) if (!created.isDestroyed()) created.finish();
                });
                instrumentation.waitForIdleSync();
            }
            finally {
                application.unregisterActivityLifecycleCallbacks(lifecycle);
                try { if (bound) assertTrue("The original process network binding could not be restored", manager.bindProcessToNetwork(originalBinding)); }
                finally {
                    try { if (requested) manager.unregisterNetworkCallback(callback); }
                    finally {
                        try { if (adopted) automation.dropShellPermissionIdentity(); }
                        finally {
                            SharedPreferences.Editor restore = preferences.edit().clear();
                            for (Map.Entry<String, ?> entry : original.entrySet()) if (entry.getValue() instanceof String) restore.putString(entry.getKey(), (String) entry.getValue());
                            restore.commit();
                            new File(context.getFilesDir(), "physical-internet-pairing.txt").delete();
                        }
                    }
                }
            }
        }
    }

    private JSONObject captureDiagnostic(MainActivity activity, String phase) throws Exception {
        final String[] text = {"", "", "", "", "", "", ""};
        final boolean[] flags = new boolean[8];
        final int[] configuration = new int[4];
        instrumentation.runOnMainSync(() -> {
            BrowserAgentPanel panel = activity.getAgentPanel();
            URI address = activity.getCurrentAddress();
            text[0] = panel.logText();
            text[1] = "browseragent".equals(address.getScheme()) ? "[pairing link omitted]" : address.toString();
            text[2] = address.getPath() == null ? "" : address.getPath();
            text[3] = MobileBrowserAgent.prefix(activity.getPageView().getTextContent(), 2_000);
            View run = find(activity.getWindow().getDecorView(), "Run agent");
            flags[0] = run != null && run.isEnabled();
            flags[1] = activity.hasWindowFocus(); flags[2] = activity.isFinishing(); flags[3] = activity.isDestroyed();
            flags[6] = (activity.getWindow().getAttributes().flags & WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) != 0;
            flags[7] = activity.isChangingConfigurations();
            configuration[0] = activity.getRequestedOrientation(); configuration[1] = activity.getResources().getConfiguration().orientation;
            configuration[2] = activity.getWindowManager().getDefaultDisplay().getRotation(); configuration[3] = createdActivities.size();
            try {
                java.lang.reflect.Field state = BrowserAgentPanel.class.getDeclaredField("state"); state.setAccessible(true);
                text[4] = ((TextView) state.get(panel)).getText().toString();
                java.lang.reflect.Field running = BrowserAgentPanel.class.getDeclaredField("running"); running.setAccessible(true);
                Object task = running.get(panel);
                flags[4] = task != null; flags[5] = task instanceof java.util.concurrent.Future && ((java.util.concurrent.Future<?>) task).isDone();
                java.lang.reflect.Field review = BrowserAgentPanel.class.getDeclaredField("review"); review.setAccessible(true);
                AlertDialog approval = (AlertDialog) review.get(panel);
                if (approval != null && approval.isShowing()) {
                    TextView message = approval.findViewById(android.R.id.message); text[5] = message == null ? "[review showing]" : message.getText().toString();
                }
            } catch (ReflectiveOperationException captureFailure) { text[6] = captureFailure.toString(); }
        });
        lastDiagnostic = new JSONObject().put("phase", phase).put("capturedAt", System.currentTimeMillis() / 1000.0)
                .put("agentLog", text[0]).put("currentURL", text[1]).put("currentPath", text[2]).put("pageText", text[3])
                .put("state", text[4]).put("approvalMessage", text[5]).put("runEnabled", flags[0]).put("hasWindowFocus", flags[1])
                .put("activityFinishing", flags[2]).put("activityDestroyed", flags[3]).put("taskPresent", flags[4]).put("workerDone", flags[5])
                .put("keepScreenOn", flags[6]).put("activityResumed", activityResumed.get()).put("lastLifecycle", lastLifecycle)
                .put("lifecycleChangedAt", lifecycleChangedAt / 1000.0).put("changingConfigurations", flags[7])
                .put("requestedOrientation", configuration[0]).put("configurationOrientation", configuration[1])
                .put("displayRotation", configuration[2]).put("mainActivityInstances", configuration[3]);
        PowerManager power = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        if (power != null) lastDiagnostic.put("screenInteractive", power.isInteractive());
        if (!text[6].isEmpty()) lastDiagnostic.put("captureError", text[6]);
        return lastDiagnostic;
    }

    private void persistDiagnostic(JSONObject diagnostic) throws Exception {
        JSONArray threads = new JSONArray();
        try {
            for (Map.Entry<Thread, StackTraceElement[]> entry : Thread.getAllStackTraces().entrySet()) {
                boolean relevant = false;
                for (StackTraceElement frame : entry.getValue()) {
                    if (frame.getClassName().equals("com.culpen.browser.AgentConnection") || frame.getClassName().equals("com.culpen.browser.MobileBrowserAgent")) { relevant = true; break; }
                }
                if (!relevant || threads.length() >= 8) continue;
                JSONArray stack = new JSONArray();
                for (int i = 0; i < Math.min(entry.getValue().length, 40); i++) stack.put(entry.getValue()[i].toString());
                threads.put(new JSONObject().put("name", entry.getKey().getName()).put("state", entry.getKey().getState().toString()).put("stack", stack));
            }
            diagnostic.put("workerThreads", threads);
        } catch (RuntimeException captureFailure) { diagnostic.put("threadCaptureError", captureFailure.toString()); }
        lastDiagnostic = diagnostic;
        write("physical-internet-agent-log.txt", diagnostic.optString("agentLog"));
        write("physical-internet-diagnostic.json", diagnostic.toString(2));
    }

    private void addCellularEvidence(JSONObject evidence, ConnectivityManager manager, Network network, AtomicBoolean lost) throws Exception {
        assertFalse("The cellular network was lost; Wi-Fi must not substitute for this fixture", lost.get());
        assertEquals(network, manager.getBoundNetworkForProcess());
        NetworkCapabilities capabilities = manager.getNetworkCapabilities(network);
        assertNotNull(capabilities); assertTrue(capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR));
        assertFalse("The test process is using Wi-Fi instead of cellular", capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI));
        LinkProperties properties = manager.getLinkProperties(network);
        assertNotNull(properties); assertNotNull(properties.getInterfaceName());
        JSONArray addresses = new JSONArray(); for (LinkAddress address : properties.getLinkAddresses()) addresses.put(address.toString());
        evidence.put("cellular", true).put("wifi", false).put("networkHandle", network.getNetworkHandle())
                .put("interface", properties.getInterfaceName()).put("linkAddresses", addresses)
                .put("validated", capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED));
    }
    private MainActivity launch() {
        Intent intent = new Intent(Intent.ACTION_MAIN).setClass(context, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
        return (MainActivity) instrumentation.startActivitySync(intent);
    }
    private void awaitPage(MainActivity activity, String text) throws Exception {
        long deadline = SystemClock.uptimeMillis() + 20_000;
        final boolean[] loaded = {false};
        while (SystemClock.uptimeMillis() < deadline) {
            instrumentation.runOnMainSync(() -> loaded[0] = !activity.isLoading() && activity.getPageView().getTextContent().contains(text));
            if (loaded[0]) return;
            SystemClock.sleep(50);
        }
        fail("The phone's loopback museum fixture did not load while its process was bound to cellular.");
    }
    private View find(View view, String description) {
        if (view.getContentDescription() != null && description.contentEquals(view.getContentDescription())) return view;
        if (view instanceof ViewGroup) for (int i = 0; i < ((ViewGroup) view).getChildCount(); i++) {
            View result = find(((ViewGroup) view).getChildAt(i), description); if (result != null) return result;
        }
        return null;
    }
    private String shell(String command) throws Exception {
        try (ParcelFileDescriptor descriptor = instrumentation.getUiAutomation().executeShellCommand(command);
             InputStream input = new ParcelFileDescriptor.AutoCloseInputStream(descriptor)) {
            return read(input, 4096).trim();
        }
    }
    private String readPrivate(String name) throws Exception {
        try (InputStream input = new FileInputStream(new File(context.getFilesDir(), name))) { return read(input, 4096); }
    }
    private String read(InputStream input, int limit) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream(); byte[] buffer = new byte[1024]; int count;
        while ((count = input.read(buffer)) != -1) {
            if (output.size() + count > limit) throw new java.io.IOException("Fixture input was too large."); output.write(buffer, 0, count);
        }
        return output.toString(StandardCharsets.UTF_8.name());
    }
    private void write(String name, String value) throws Exception {
        File target = new File(context.getFilesDir(), name), temporary = new File(context.getFilesDir(), name + ".tmp");
        try {
            try (FileOutputStream output = new FileOutputStream(temporary)) { output.write(value.getBytes(StandardCharsets.UTF_8)); }
            if (!temporary.renameTo(target)) throw new java.io.IOException("Could not save physical-test evidence.");
        } finally { temporary.delete(); }
    }

    private static final class Museum implements AutoCloseable {
        private final ServerSocket server;
        Museum() throws Exception {
            server = new ServerSocket(0, 4, InetAddress.getByName("127.0.0.1"));
            Thread worker = new Thread(() -> {
                while (!server.isClosed()) try (Socket socket = server.accept()) {
                    socket.setSoTimeout(5000);
                    BufferedReader input = new BufferedReader(new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
                    String request = input.readLine(), line; while ((line = input.readLine()) != null && !line.isEmpty()) { }
                    String html = request != null && request.contains("/hours")
                            ? "<title>Museum hours</title><h1>Museum hours</h1><p>The museum opens at 10 AM every day.</p>"
                            : "<title>Museum</title><h1>Visit the museum</h1><a href='/hours'>Opening Hours</a>";
                    byte[] body = html.getBytes(StandardCharsets.UTF_8);
                    socket.getOutputStream().write(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " + body.length + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                    socket.getOutputStream().write(body);
                } catch (Exception ignored) { }
            }, "Physical phone museum fixture");
            worker.setDaemon(true); worker.start();
        }
        URI url() { return URI.create("http://127.0.0.1:" + server.getLocalPort() + "/museum"); }
        @Override public void close() throws Exception { server.close(); }
    }
}
