package com.culpen.browser;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/** A paired PC endpoint. Only encrypted application data crosses the local network. */
final class AgentConnection {
    static final int MAX_BODY = 32_768;
    private static final byte[] REQUEST_AAD = "BrowserAgent/v1 request".getBytes(StandardCharsets.UTF_8);
    private static final byte[] RESPONSE_AAD = "BrowserAgent/v1 response".getBytes(StandardCharsets.UTF_8);
    final String host;
    final int port;
    private final byte[] key;
    private volatile HttpURLConnection active;

    private AgentConnection(String host, int port, byte[] key) {
        this.host = host; this.port = port; this.key = key.clone();
    }

    static AgentConnection parse(String link) {
        try {
            if (link == null || link.length() > 512) throw new IllegalArgumentException();
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
            if (fields.size() != 3 || !fields.containsKey("host") || !fields.containsKey("port") || !fields.containsKey("key")) {
                throw new IllegalArgumentException();
            }
            String host = fields.get("host");
            String[] octets = host.split("\\.", -1);
            if (octets.length != 4) throw new IllegalArgumentException();
            int[] address = new int[4];
            for (int i = 0; i < 4; i++) {
                if (!octets[i].matches("0|[1-9][0-9]{0,2}")) throw new IllegalArgumentException();
                address[i] = Integer.parseInt(octets[i]);
                if (address[i] > 255) throw new IllegalArgumentException();
            }
            if (!(address[0] == 10 || address[0] == 172 && address[1] >= 16 && address[1] <= 31
                    || address[0] == 192 && address[1] == 168)) throw new IllegalArgumentException();
            if (!fields.get("port").matches("[1-9][0-9]{0,4}")) throw new IllegalArgumentException();
            int port = Integer.parseInt(fields.get("port"));
            if (port > 65535 || !fields.get("key").matches("[A-Za-z0-9_-]{43}")) throw new IllegalArgumentException();
            byte[] key = Base64.getUrlDecoder().decode(fields.get("key"));
            if (key.length != 32) throw new IllegalArgumentException();
            return new AgentConnection(host, port, key);
        } catch (Exception error) {
            throw new IllegalArgumentException("Paste the complete pairing link shown by Browser on your PC.");
        }
    }

    String label() { return host + ":" + port; }

    byte[] generate(byte[] json) throws IOException {
        if (json.length + 28 > MAX_BODY) throw new IOException("The task is too long for the PC connection.");
        byte[] nonce = new byte[12];
        new SecureRandom().nextBytes(nonce);
        final byte[] body;
        try { body = seal(json, nonce, REQUEST_AAD); }
        catch (GeneralSecurityException error) { throw new IOException("Couldn’t encrypt the request."); }
        HttpURLConnection connection = (HttpURLConnection) URI.create("http://" + host + ":" + port + "/v1/generate").toURL().openConnection();
        active = connection;
        try {
            if (Thread.currentThread().isInterrupted()) throw new InterruptedException();
            connection.setInstanceFollowRedirects(false);
            connection.setConnectTimeout(8_000); connection.setReadTimeout(240_000);
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
        } catch (java.net.ConnectException | java.net.SocketTimeoutException error) {
            throw new IOException("Couldn’t reach the paired PC. Keep Browser and Connect Phone open on the PC, and check that both devices share the local network.");
        } finally {
            if (active == connection) active = null;
            connection.disconnect();
        }
    }

    void cancel() { HttpURLConnection connection = active; if (connection != null) connection.disconnect(); }

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
