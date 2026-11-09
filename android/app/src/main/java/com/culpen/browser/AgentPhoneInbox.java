package com.culpen.browser;

import android.content.Context;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import org.json.JSONObject;
import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Base64;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.function.BiFunction;
import java.util.function.Function;

/** Foreground-only pairing inbox. No model or browser-control endpoint runs on the phone. */
final class AgentPhoneInbox {
    static final int PORT = 38766;
    private final Context context;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService acceptor = Executors.newSingleThreadExecutor();
    private final ExecutorService workers = Executors.newFixedThreadPool(2);
    private final BiFunction<String, String, CompletableFuture<Boolean>> approve;
    private final Function<String, Boolean> connect;
    private final Set<Socket> clients = new HashSet<>();
    private final Set<String> seenNonces = new HashSet<>();
    private final Map<String, Approval> approved = new HashMap<>();
    private final Object authority = new Object();
    private final Map<String, Integer> revocations = new HashMap<>();
    private volatile AgentPhoneIdentity identity;
    private volatile ServerSocket server;
    private volatile int generation;
    private volatile boolean active;
    private NsdManager.RegistrationListener advertisement;
    private final Set<CompletableFuture<Boolean>> reviews = new HashSet<>();

    AgentPhoneInbox(Context context, BiFunction<String, String, CompletableFuture<Boolean>> approve, Function<String, Boolean> connect) {
        this.context = context; this.approve = approve; this.connect = connect;
    }

    static String deviceName() {
        String model = Build.MODEL == null ? "Phone" : Build.MODEL.trim();
        if (model.isEmpty()) return "Phone";
        while (model.getBytes(StandardCharsets.UTF_8).length > 60) model = model.substring(0, model.offsetByCodePoints(model.length(), -1));
        return model;
    }

    void start() {
        if (active) return;
        active = true; int serial = ++generation;
        acceptor.execute(() -> {
            ServerSocket listener = null;
            try {
                identity = AgentPhoneIdentity.load(context);
                listener = new ServerSocket(); listener.setReuseAddress(true); listener.bind(new InetSocketAddress(PORT));
                if (!active || generation != serial) { listener.close(); return; }
                server = listener; main.post(() -> advertise(serial));
                while (active && generation == serial) {
                    Socket socket = listener.accept(); socket.setSoTimeout(8_000);
                    synchronized (clients) {
                        if (clients.size() >= 2) { socket.close(); continue; }
                        clients.add(socket);
                    }
                    workers.execute(() -> handle(socket, serial));
                }
            } catch (Exception ignored) {
                // Manual pairing and outbound model access remain available when the port is unavailable.
            } finally {
                if (listener != null) try { listener.close(); } catch (Exception ignored) { }
                if (generation == serial) server = null;
            }
        });
    }

    boolean isRunning() { return active && server != null && identity != null; }
    String phoneID() { return identity == null ? null : identity.id; }

    String pairingLink(String host) throws Exception {
        AgentPhoneIdentity current = identity;
        if (!isRunning() || current == null) throw new java.io.IOException("Phone pairing is starting. Try again in a moment.");
        String name = deviceName(), publicKey = Base64.getUrlEncoder().withoutPadding().encodeToString(current.keyPair.getPublic().getEncoded());
        // Reuse endpoint validation without exposing a model key in the phone invitation.
        AgentConnection.parse("browseragent://pair?host=" + URLEncoder.encode(host, "UTF-8").replace("+", "%20")
                + "&port=" + PORT + "&key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        return "browseragent://phone?host=" + URLEncoder.encode(host, "UTF-8").replace("+", "%20") + "&port=" + PORT
                + "&id=" + current.id + "&name=" + URLEncoder.encode(name, "UTF-8").replace("+", "%20") + "&pub=" + publicKey;
    }

    static String localAddress() {
        try {
            java.util.Enumeration<NetworkInterface> interfaces = NetworkInterface.getNetworkInterfaces();
            String ipv6 = null;
            while (interfaces != null && interfaces.hasMoreElements()) {
                NetworkInterface network = interfaces.nextElement();
                if (!network.isUp() || network.isLoopback()) continue;
                java.util.Enumeration<InetAddress> addresses = network.getInetAddresses();
                while (addresses.hasMoreElements()) {
                    InetAddress address = addresses.nextElement();
                    if (address.isLoopbackAddress() || address.isLinkLocalAddress() || address.isMulticastAddress()) continue;
                    if (address instanceof java.net.Inet4Address) return address.getHostAddress();
                    ipv6 = address.getHostAddress();
                }
            }
            if (ipv6 != null) return ipv6;
        } catch (Exception ignored) { }
        return "127.0.0.1";
    }

    private void advertise(int serial) {
        if (!active || generation != serial || identity == null) return;
        NsdManager manager = (NsdManager) context.getSystemService(Context.NSD_SERVICE);
        if (manager == null) return;
        NsdServiceInfo service = new NsdServiceInfo();
        service.setServiceType("_browseragent-phone._tcp."); service.setServiceName("Browser " + deviceName()); service.setPort(PORT);
        service.setAttribute("id", identity.id); service.setAttribute("name", deviceName());
        service.setAttribute("pub", Base64.getUrlEncoder().withoutPadding().encodeToString(identity.keyPair.getPublic().getEncoded()));
        advertisement = new NsdManager.RegistrationListener() {
            @Override public void onServiceRegistered(NsdServiceInfo value) { }
            @Override public void onRegistrationFailed(NsdServiceInfo value, int code) { }
            @Override public void onServiceUnregistered(NsdServiceInfo value) { }
            @Override public void onUnregistrationFailed(NsdServiceInfo value, int code) { }
        };
        try { manager.registerService(service, NsdManager.PROTOCOL_DNS_SD, advertisement); }
        catch (RuntimeException ignored) { advertisement = null; }
    }

    private void handle(Socket socket, int serial) {
        try {
            Socket client = socket;
            BufferedInputStream input = new BufferedInputStream(client.getInputStream());
            Request request = readRequest(input);
            AgentPhoneIdentity phone = identity;
            if (phone == null || !active || generation != serial) return;
            JSONObject envelope = new JSONObject(new String(request.body, StandardCharsets.UTF_8));
            if (envelope.length() != 2) throw new java.io.IOException();
            byte[] sender = Base64.getDecoder().decode(envelope.getString("publicKey"));
            byte[] body = Base64.getDecoder().decode(envelope.getString("data"));
            byte[] key = PhoneInviteCrypto.sharedKey(phone.keyPair, sender);
            JSONObject plain = new JSONObject(new String(PhoneInviteCrypto.open(body, key), StandardCharsets.UTF_8));
            long timestamp = plain.getLong("createdAt");
            long now = System.currentTimeMillis() / 1000;
            if (timestamp < now - 90 || timestamp > now + 90) throw new java.io.IOException();
            String senderID = Base64.getEncoder().encodeToString(sender);
            String nonce = senderID + ":" + Base64.getEncoder().encodeToString(Arrays.copyOf(body, 12));
            synchronized (seenNonces) {
                if (seenNonces.size() >= 1000 || !seenNonces.add(nonce)) throw new java.io.IOException();
            }
            JSONObject result;
            if (request.path.equals("/v1/offer")) {
                if (plain.length() != 3) throw new java.io.IOException();
                String name = plain.getString("name"), id = UUID.fromString(plain.getString("id")).toString();
                final int revision;
                synchronized (authority) { revision = revocations.getOrDefault(id, 0); }
                if (name.trim().isEmpty() || name.getBytes(StandardCharsets.UTF_8).length > 200 || name.codePoints().anyMatch(Character::isISOControl)) throw new java.io.IOException();
                boolean remembered = phone.trusts(sender, id);
                boolean accepted = remembered;
                if (!accepted) {
                    CompletableFuture<Boolean> review = new CompletableFuture<>();
                    synchronized (reviews) { reviews.add(review); }
                    main.post(() -> {
                        if (!active || generation != serial) { review.complete(false); return; }
                        try { approve.apply(name, code(key)).whenComplete((value, error) -> review.complete(error == null && Boolean.TRUE.equals(value))); }
                        catch (Exception error) { review.complete(false); }
                    });
                    try { accepted = review.get(65, TimeUnit.SECONDS); }
                    finally { synchronized (reviews) { reviews.remove(review); } }
                }
                if (!active || generation != serial) return;
                synchronized (authority) {
                    if (revocations.getOrDefault(id, 0) != revision) accepted = false;
                    if (accepted) approved.put(senderID, new Approval(id, System.currentTimeMillis() + 90_000, revision));
                }
                result = new JSONObject().put("accepted", accepted).put("remembered", remembered);
            } else {
                if (plain.length() != 2) throw new java.io.IOException();
                Approval permission;
                synchronized (authority) { permission = approved.remove(senderID); }
                if (permission == null || permission.expires < System.currentTimeMillis()) throw new java.io.IOException();
                String link = plain.getString("pairingLink"); AgentConnection proposed = AgentConnection.parse(link);
                if (proposed.id == null || !permission.id.equals(proposed.id)) throw new java.io.IOException();
                CompletableFuture<Boolean> connected = new CompletableFuture<>();
                main.post(() -> {
                    synchronized (authority) {
                        if (!active || generation != serial || revocations.getOrDefault(permission.id, 0) != permission.revision) {
                            connected.complete(false); return;
                        }
                        try {
                            boolean accepted = connect.apply(link);
                            if (accepted) phone.remember(sender, proposed.identity());
                            connected.complete(accepted);
                        } catch (Exception error) { connected.complete(false); }
                    }
                });
                boolean accepted = connected.get(5, TimeUnit.SECONDS);
                result = new JSONObject().put("accepted", accepted);
            }
            byte[] encrypted = PhoneInviteCrypto.reply(result.toString().getBytes(StandardCharsets.UTF_8), key, body);
            byte[] response = new JSONObject().put("publicKey", Base64.getEncoder().encodeToString(phone.keyPair.getPublic().getEncoded()))
                    .put("data", Base64.getEncoder().encodeToString(encrypted)).toString().getBytes(StandardCharsets.UTF_8);
            respond(client, 200, response);
        } catch (Exception ignored) {
            try { respond(socket, 401, new byte[0]); } catch (Exception unavailable) { }
        } finally {
            try { socket.close(); } catch (Exception ignored) { }
            synchronized (clients) { clients.remove(socket); }
        }
    }

    private static String code(byte[] key) {
        try { return PhoneInviteCrypto.code(key); } catch (Exception error) { throw new IllegalStateException(error); }
    }

    private static Request readRequest(BufferedInputStream input) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(); int matched = 0;
        byte[] end = {13, 10, 13, 10};
        while (bytes.size() < 8192 && matched < 4) {
            int next = input.read(); if (next < 0) throw new java.io.IOException(); bytes.write(next);
            matched = next == end[matched] ? matched + 1 : next == 13 ? 1 : 0;
        }
        if (matched != 4) throw new java.io.IOException();
        String[] lines = bytes.toString("US-ASCII").split("\r\n");
        if (lines.length > 33 || !(lines[0].equals("POST /v1/offer HTTP/1.1") || lines[0].equals("POST /v1/connect HTTP/1.1"))) throw new java.io.IOException();
        int length = -1;
        for (int i = 1; i < lines.length; i++) {
            int split = lines[i].indexOf(':'); if (split < 1) throw new java.io.IOException();
            String name = lines[i].substring(0, split).toLowerCase(java.util.Locale.ROOT);
            if (name.equals("transfer-encoding")) throw new java.io.IOException();
            if (name.equals("content-length")) {
                if (length != -1 || !lines[i].substring(split + 1).trim().matches("[0-9]{1,5}")) throw new java.io.IOException();
                length = Integer.parseInt(lines[i].substring(split + 1).trim());
            }
        }
        if (length < 28 || length > 16_384) throw new java.io.IOException();
        byte[] body = new byte[length]; new DataInputStream(input).readFully(body);
        return new Request(lines[0].contains("/v1/offer") ? "/v1/offer" : "/v1/connect", body);
    }

    private static void respond(Socket socket, int status, byte[] body) throws Exception {
        socket.getOutputStream().write(("HTTP/1.1 " + status + (status == 200 ? " OK" : " Unauthorized")
                + "\r\nContent-Type: application/json\r\nContent-Length: " + body.length + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
        socket.getOutputStream().write(body); socket.getOutputStream().flush();
    }

    void stop() {
        active = false; generation++;
        ServerSocket listener = server; server = null;
        if (listener != null) try { listener.close(); } catch (Exception ignored) { }
        synchronized (clients) { for (Socket client : clients) try { client.close(); } catch (Exception ignored) { } clients.clear(); }
        synchronized (seenNonces) { seenNonces.clear(); }
        synchronized (authority) { approved.clear(); revocations.clear(); }
        synchronized (reviews) { for (CompletableFuture<Boolean> review : reviews) review.complete(false); reviews.clear(); }
        if (advertisement != null) {
            NsdManager manager = (NsdManager) context.getSystemService(Context.NSD_SERVICE);
            try { if (manager != null) manager.unregisterService(advertisement); } catch (RuntimeException ignored) { }
            advertisement = null;
        }
    }
    void destroy() { stop(); acceptor.shutdownNow(); workers.shutdownNow(); }

    void forgetComputer(String computerID) throws Exception {
        synchronized (authority) {
            if (identity == null) throw new java.io.IOException("Phone pairing is still starting. Try forgetting the computer again.");
            revocations.put(computerID, revocations.getOrDefault(computerID, 0) + 1);
            approved.values().removeIf(approval -> approval.id.equals(computerID));
            identity.forget(computerID);
        }
    }

    private static final class Request {
        final String path; final byte[] body;
        Request(String path, byte[] body) { this.path = path; this.body = body; }
    }
    private static final class Approval {
        final String id; final long expires; final int revision;
        Approval(String id, long expires, int revision) { this.id = id; this.expires = expires; this.revision = revision; }
    }
}
