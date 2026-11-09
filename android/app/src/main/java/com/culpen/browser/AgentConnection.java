package com.culpen.browser;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.IDN;
import java.net.InetAddress;
import java.net.URI;
import java.net.Proxy;
import java.net.URISyntaxException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** A paired model host. HTTP transports only authenticated, encrypted application data. */
final class AgentConnection {
    static final int MAX_BODY = 32_768;
    private static final byte[] REQUEST_AAD = "BrowserAgent/v1 request".getBytes(StandardCharsets.UTF_8);
    private static final byte[] RESPONSE_AAD = "BrowserAgent/v1 response".getBytes(StandardCharsets.UTF_8);
    private static final ThreadPoolExecutor DISCONNECTS = new ThreadPoolExecutor(2, 2, 30, TimeUnit.SECONDS,
            new ArrayBlockingQueue<>(32), task -> {
                Thread thread = new Thread(task, "Browser model disconnect"); thread.setDaemon(true); return thread;
            }, new ThreadPoolExecutor.DiscardPolicy());
    static { DISCONNECTS.allowCoreThreadTimeOut(true); }
    final String host;
    final int port;
    final String id;
    final String name;
    private final byte[] key;
    private final String link;
    private AgentConnection fallback;
    private volatile HttpURLConnection active;

    private AgentConnection(String host, int port, byte[] key, String id, String name, String link) {
        this.host = host; this.port = port; this.key = key.clone();
        this.id = id; this.name = name; this.link = link;
    }

    static AgentConnection parse(String link) {
        try {
            if (link == null || link.length() > 2048) throw new IllegalArgumentException();
            URI uri = URI.create(link.trim());
            if (!"browseragent".equals(uri.getScheme()) || !"pair".equals(uri.getHost())
                    || uri.getRawUserInfo() != null || uri.getPort() != -1 || uri.getRawFragment() != null
                    || !(uri.getRawPath().isEmpty() || uri.getRawPath().equals("/")) || uri.getRawQuery() == null) {
                throw new IllegalArgumentException();
            }
            Map<String, String> fields = new LinkedHashMap<>();
            for (String part : uri.getRawQuery().split("&")) {
                String[] pair = part.split("=", 2);
                if (pair.length != 2) throw new IllegalArgumentException();
                String name = URLDecoder.decode(pair[0], StandardCharsets.UTF_8.name());
                String value = URLDecoder.decode(pair[1], StandardCharsets.UTF_8.name());
                if (fields.put(name, value) != null) throw new IllegalArgumentException();
            }
            if (!fields.containsKey("host") || !fields.containsKey("port") || !fields.containsKey("key")
                    || !Arrays.asList("host", "port", "key", "id", "name").containsAll(fields.keySet())) {
                throw new IllegalArgumentException();
            }
            String host = validHost(fields.get("host"));
            if (!fields.get("port").matches("[1-9][0-9]{0,4}")) throw new IllegalArgumentException();
            int port = Integer.parseInt(fields.get("port"));
            if (port > 65535 || !fields.get("key").matches("[A-Za-z0-9_-]{43}")) throw new IllegalArgumentException();
            byte[] key = Base64.getUrlDecoder().decode(fields.get("key"));
            if (key.length != 32) throw new IllegalArgumentException();
            String id = fields.get("id"), name = fields.get("name");
            if (id != null && (!id.matches("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
                    || !UUID.fromString(id).toString().equalsIgnoreCase(id))) throw new IllegalArgumentException();
            if (name != null && (name.trim().isEmpty() || name.getBytes(StandardCharsets.UTF_8).length > 200
                    || name.codePoints().anyMatch(Character::isISOControl))) throw new IllegalArgumentException();
            return new AgentConnection(host, port, key, id == null ? null : id.toLowerCase(Locale.ROOT),
                    name == null ? null : name.trim(), link.trim());
        } catch (Exception error) {
            throw new IllegalArgumentException("Paste the complete pairing link shown by Browser on the model computer.");
        }
    }

    private static String validHost(String value) throws Exception {
        String host = value;
        if (host.startsWith("[") && host.endsWith("]")) host = host.substring(1, host.length() - 1);
        if (host.isEmpty() || host.length() > 253) throw new IllegalArgumentException();
        if (host.contains(":")) {
            String[] scoped = host.split("%", -1);
            if (scoped.length > 2 || !scoped[0].matches("[0-9A-Fa-f:.]+")
                    || scoped.length == 2 && !scoped[1].matches("[A-Za-z0-9_.-]{1,32}")) throw new IllegalArgumentException();
            InetAddress.getByName(scoped[0]); // A colon makes this a literal parse, never a DNS query.
            return host;
        }
        if (host.matches("[0-9.]+")) {
            String[] octets = host.split("\\.", -1);
            if (octets.length != 4) throw new IllegalArgumentException();
            for (String octet : octets) {
                if (!octet.matches("0|[1-9][0-9]{0,2}") || Integer.parseInt(octet) > 255) throw new IllegalArgumentException();
            }
            return host;
        }
        host = IDN.toASCII(host, IDN.USE_STD3_ASCII_RULES).toLowerCase(Locale.ROOT);
        String domain = host.endsWith(".") ? host.substring(0, host.length() - 1) : host;
        for (String label : domain.split("\\.", -1)) {
            if (!label.matches("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")) throw new IllegalArgumentException();
        }
        return host;
    }

    String label() { return name == null ? addressLabel() : name; }
    String addressLabel() { return (host.contains(":") ? "[" + host + "]" : host) + ":" + port; }
    String identity() { return id == null ? "address:" + addressLabel() : id; }
    String pairingLink() { return link; }

    AgentConnection atDiscoveredAddress(String host, int port) {
        try {
            if (port < 1 || port > 65535) throw new IllegalArgumentException();
            AgentConnection local = new AgentConnection(validHost(host), port, key, id, name, link);
            if (!local.host.equals(this.host) || local.port != this.port) local.fallback = this;
            return local;
        } catch (Exception error) { throw new IllegalArgumentException("Invalid nearby device address."); }
    }

    URI endpoint() {
        return endpoint("/v1/generate");
    }
    private URI endpoint(String path) {
        try { return new URI("http", null, host, port, path, null, null); }
        catch (URISyntaxException error) { throw new IllegalStateException("Invalid device address."); }
    }

    byte[] generate(byte[] json) throws IOException {
        return post("/v1/generate", json, 8_000, 240_000);
    }

    byte[] phonePresence(byte[] json) throws IOException { return post("/v1/phone", json, 1_500, 2_500); }

    AgentConnection independentCopy() {
        AgentConnection copy = new AgentConnection(host, port, key, id, name, link);
        if (fallback != null) copy.fallback = fallback.independentCopy();
        return copy;
    }

    private byte[] post(String path, byte[] json, int connectTimeout, int readTimeout) throws IOException {
        if (json.length + 28 > MAX_BODY) throw new IOException("The task is too long for the PC connection.");
        byte[] nonce = new byte[12];
        new SecureRandom().nextBytes(nonce);
        final byte[] body;
        try { body = seal(json, nonce, REQUEST_AAD); }
        catch (GeneralSecurityException error) { throw new IOException("Couldn’t encrypt the request."); }
        HttpURLConnection connection = (HttpURLConnection) endpoint(path).toURL().openConnection(Proxy.NO_PROXY);
        active = connection;
        try {
            if (Thread.currentThread().isInterrupted()) throw new InterruptedException();
            connection.setInstanceFollowRedirects(false);
            connection.setConnectTimeout(connectTimeout); connection.setReadTimeout(readTimeout);
            connection.setRequestMethod("POST"); connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/octet-stream");
            connection.setFixedLengthStreamingMode(body.length);
            try (java.io.OutputStream output = connection.getOutputStream()) { output.write(body); }
            int status = connection.getResponseCode();
            if (status != 200 && status != 429 && status != 500) throw new IOException("The PC rejected this connection. Pair again from its Connect Phone window.");
            InputStream stream = status >= 400 ? connection.getErrorStream() : connection.getInputStream();
            if (stream == null) throw new IOException("The PC returned an empty response.");
            byte[] encrypted;
            try (InputStream input = stream) { encrypted = readBounded(input); }
            byte[] aad = Arrays.copyOf(RESPONSE_AAD, RESPONSE_AAD.length + nonce.length);
            System.arraycopy(nonce, 0, aad, RESPONSE_AAD.length, nonce.length);
            try { return open(encrypted, aad); }
            catch (GeneralSecurityException error) { throw new IOException("Couldn’t verify the PC response. Pair again from Connect Phone."); }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new IOException("Stopped.");
        } catch (java.net.SocketException | java.net.SocketTimeoutException | java.net.UnknownHostException error) {
            if (fallback != null && !Thread.currentThread().isInterrupted()) return fallback.post(path, json, connectTimeout, readTimeout);
            throw new IOException("Couldn’t reach " + label() + ". Keep the computer awake with model sharing on. Its saved address and port must be reachable from this network.");
        } finally {
            if (active == connection) active = null;
            connection.disconnect();
        }
    }

    void cancel() {
        HttpURLConnection connection = active;
        if (connection != null) DISCONNECTS.execute(() -> {
            try { connection.disconnect(); } catch (RuntimeException ignored) { }
        });
        if (fallback != null) fallback.cancel();
    }

    private byte[] seal(byte[] plain, byte[] nonce, byte[] aad) throws GeneralSecurityException {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
        cipher.updateAAD(aad);
        byte[] encrypted = cipher.doFinal(plain);
        byte[] combined = Arrays.copyOf(nonce, nonce.length + encrypted.length);
        System.arraycopy(encrypted, 0, combined, nonce.length, encrypted.length);
        return combined;
    }

    private byte[] open(byte[] combined, byte[] aad) throws GeneralSecurityException {
        if (combined.length < 28 || combined.length > MAX_BODY) throw new GeneralSecurityException();
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, combined, 0, 12));
        cipher.updateAAD(aad);
        return cipher.doFinal(combined, 12, combined.length - 12);
    }

    private static byte[] readBounded(InputStream input) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        int count;
        while ((count = input.read(buffer)) != -1) {
            if (output.size() + count > MAX_BODY) throw new IOException("The PC response was too large.");
            output.write(buffer, 0, count);
        }
        return output.toByteArray();
    }
}
