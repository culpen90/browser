package com.culpen.browser;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.HashMap;
import java.util.Map;

/** Nearby advertisements supply addresses only; a saved pairing always supplies the secret key. */
final class AgentDeviceDiscovery {
    private final NsdManager manager;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Runnable changed;
    private final Map<String, NsdServiceInfo> nearby = new HashMap<>();
    private final Map<String, Long> resolvedAt = new HashMap<>();
    private final Map<String, NsdServiceInfo> services = new HashMap<>();
    private final ArrayDeque<NsdServiceInfo> pending = new ArrayDeque<>();
    private final Runnable refresher = this::refreshNearby;
    private NsdManager.DiscoveryListener listener;
    private boolean resolving;
    private int generation;

    AgentDeviceDiscovery(Context context, Runnable changed) {
        manager = (NsdManager) context.getSystemService(Context.NSD_SERVICE);
        this.changed = changed;
    }

    void start() {
        if (listener != null || manager == null) return;
        final int serial = ++generation;
        listener = new NsdManager.DiscoveryListener() {
            @Override public void onDiscoveryStarted(String type) { }
            @Override public void onDiscoveryStopped(String type) { }
            @Override public void onStartDiscoveryFailed(String type, int error) { main.post(() -> {
                if (generation == serial) stop();
            }); }
            @Override public void onStopDiscoveryFailed(String type, int error) { }
            @Override public void onServiceFound(NsdServiceInfo service) { main.post(() -> {
                if (generation != serial || pending.size() >= 16) return;
                if (services.size() < 16) services.put(service.getServiceName(), service);
                pending.add(service); resolveNext(serial);
            }); }
            @Override public void onServiceLost(NsdServiceInfo service) { main.post(() -> {
                if (generation != serial) return;
                services.remove(service.getServiceName());
                nearby.entrySet().removeIf(entry -> {
                    if (!entry.getValue().getServiceName().equals(service.getServiceName())) return false;
                    resolvedAt.remove(entry.getKey()); return true;
                });
                changed.run();
            }); }
        };
        try {
            manager.discoverServices("_browseragent._tcp.", NsdManager.PROTOCOL_DNS_SD, listener);
            main.postDelayed(refresher, 30_000);
        }
        catch (RuntimeException error) { listener = null; }
    }

    private void refreshNearby() {
        if (listener == null) return;
        for (NsdServiceInfo service : services.values()) if (pending.size() < 16) pending.add(service);
        resolveNext(generation);
        changed.run();
        main.postDelayed(refresher, 30_000);
    }

    private void resolveNext(int serial) {
        if (resolving || generation != serial || pending.isEmpty()) return;
        resolving = true;
        NsdServiceInfo service = pending.remove();
        try {
            manager.resolveService(service, new NsdManager.ResolveListener() {
                @Override public void onResolveFailed(NsdServiceInfo ignored, int error) { main.post(() -> {
                    if (generation != serial) return;
                    resolving = false; resolveNext(serial);
                }); }
                @Override public void onServiceResolved(NsdServiceInfo resolved) { main.post(() -> {
                    if (generation != serial) return;
                    byte[] raw = resolved.getAttributes().get("id");
                    if (raw != null && resolved.getHost() != null && nearby.size() < 32) {
                        String id = new String(raw, StandardCharsets.UTF_8).toLowerCase(java.util.Locale.ROOT);
                        if (id.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")) {
                            nearby.put(id, resolved); resolvedAt.put(id, SystemClock.elapsedRealtime()); changed.run();
                        }
                    }
                    resolving = false; resolveNext(serial);
                }); }
            });
        } catch (RuntimeException error) { resolving = false; resolveNext(serial); }
    }

    boolean isNearby(AgentConnection device) {
        if (device == null) return false;
        Long time = resolvedAt.get(device.id);
        return time != null && SystemClock.elapsedRealtime() - time < 60_000 && nearby.containsKey(device.id);
    }

    AgentConnection reachable(AgentConnection saved) {
        if (saved == null || !isNearby(saved)) return saved;
        NsdServiceInfo service = nearby.get(saved.id);
        if (service == null || service.getHost() == null) return saved;
        try { return saved.atDiscoveredAddress(service.getHost().getHostAddress(), service.getPort()); }
        catch (IllegalArgumentException error) { return saved; }
    }

    void stop() {
        generation++;
        main.removeCallbacks(refresher);
        NsdManager.DiscoveryListener existing = listener; listener = null;
        if (existing != null) try { manager.stopServiceDiscovery(existing); } catch (RuntimeException ignored) { }
        pending.clear(); nearby.clear(); resolvedAt.clear(); services.clear(); resolving = false;
    }
}
