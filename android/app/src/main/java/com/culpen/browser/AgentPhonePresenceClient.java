package com.culpen.browser;

import android.os.Handler;
import android.os.Looper;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;
import java.util.function.Supplier;

/** A phone behind NAT keeps direct outbound contact with its previously paired computers. */
final class AgentPhonePresenceClient {
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ScheduledExecutorService scheduler = Executors.newSingleThreadScheduledExecutor();
    private final ExecutorService workers = Executors.newFixedThreadPool(4);
    private final Supplier<String> phoneID;
    private final Consumer<String> attach;
    private final Object lock = new Object();
    private List<AgentConnection> devices = new ArrayList<>();
    private String selected;
    private final Map<String, Long> nextAttempt = new HashMap<>();
    private final Map<String, String> lastToken = new HashMap<>();
    private final Set<String> inFlight = new HashSet<>();
    private final Set<AgentConnection> connections = new HashSet<>();
    private ScheduledFuture<?> timer;
    private int generation, cursor;

    AgentPhonePresenceClient(Supplier<String> phoneID, Consumer<String> attach) { this.phoneID = phoneID; this.attach = attach; }

    void updateDevices(List<AgentConnection> devices, String selected) {
        synchronized (lock) { this.devices = new ArrayList<>(devices); this.selected = selected; }
    }
    void start() {
        synchronized (lock) {
            if (timer != null) return;
            generation++;
            timer = scheduler.scheduleWithFixedDelay(this::poll, 0, 3, TimeUnit.SECONDS);
        }
    }
    private void poll() {
        String id = phoneID.get(); if (id == null) return;
        List<AgentConnection> batch = new ArrayList<>(); final int serial;
        synchronized (lock) {
            if (timer == null || devices.isEmpty()) return;
            serial = generation;
            long now = System.currentTimeMillis(); int count = devices.size();
            for (int i = 0; i < count && inFlight.size() < 4; i++) {
                AgentConnection device = devices.get(cursor++ % count);
                String identity = device.identity();
                if (inFlight.contains(identity) || nextAttempt.getOrDefault(identity, 0L) > now) continue;
                inFlight.add(identity); batch.add(device.independentCopy());
            }
            connections.addAll(batch);
        }
        for (AgentConnection device : batch) workers.execute(() -> heartbeat(device, id, serial));
    }
    private void heartbeat(AgentConnection device, String phone, int serial) {
        boolean success = false;
        try {
            synchronized (lock) { if (timer == null || generation != serial) return; }
            JSONObject request = new JSONObject().put("id", phone).put("name", AgentPhoneInbox.deviceName()).put("createdAt", System.currentTimeMillis() / 1000.0);
            byte[] response = device.phonePresence(request.toString().getBytes(StandardCharsets.UTF_8));
            JSONObject result = new JSONObject(new String(response, StandardCharsets.UTF_8));
            if (result.has("error")) return;
            success = true;
            if (result.has("attach")) {
                String token = UUID.fromString(result.getString("attach")).toString();
                boolean changed;
                synchronized (lock) {
                    changed = timer != null && generation == serial && !token.equals(lastToken.get(device.identity()));
                    if (changed) lastToken.put(device.identity(), token);
                }
                if (changed) main.post(() -> {
                    synchronized (lock) { if (timer == null || generation != serial) return; }
                    attach.accept(device.identity());
                });
            }
        } catch (Exception ignored) {
            // Unreachable saved peers back off without interrupting browsing or model requests.
        } finally {
            synchronized (lock) {
                connections.remove(device);
                if (generation == serial) {
                    inFlight.remove(device.identity());
                    nextAttempt.put(device.identity(), System.currentTimeMillis()
                            + (success ? device.identity().equals(selected) ? 3_000 : 15_000 : 30_000));
                }
            }
        }
    }
    void stop() {
        List<AgentConnection> closing;
        synchronized (lock) {
            generation++; if (timer != null) timer.cancel(false); timer = null;
            closing = new ArrayList<>(connections);
            connections.clear(); inFlight.clear(); nextAttempt.clear();
        }
        for (AgentConnection connection : closing) connection.cancel();
    }
    void destroy() { stop(); scheduler.shutdownNow(); workers.shutdownNow(); }
}
