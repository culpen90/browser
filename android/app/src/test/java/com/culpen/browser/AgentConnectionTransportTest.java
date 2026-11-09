package com.culpen.browser;

import org.junit.Test;
import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import static org.junit.Assert.*;

public final class AgentConnectionTransportTest {
    private static final String KEY = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    private static final byte[] SECRET = new byte[32];
    private static final byte[] REQUEST_AAD = "BrowserAgent/v1 request".getBytes(StandardCharsets.UTF_8);
    private static final byte[] RESPONSE_AAD = "BrowserAgent/v1 response".getBytes(StandardCharsets.UTF_8);

    @Test public void directTransportAuthenticatesEncryptedRequestAndResponse() throws Exception {
        roundTrip(false);
    }

    @Test public void responseFromAnotherRequestCannotBeAccepted() throws Exception {
        roundTrip(true);
    }

    @Test public void cancellationNeverWaitsForBlockingHttpDisconnect() throws Exception {
        AgentConnection connection = AgentConnection.parse("browseragent://pair?host=127.0.0.1&port=38765&key=" + KEY);
        java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1), release = new java.util.concurrent.CountDownLatch(1);
        java.net.HttpURLConnection blocked = new java.net.HttpURLConnection(new java.net.URL("http://127.0.0.1")) {
            @Override public void disconnect() { entered.countDown(); try { release.await(); } catch (InterruptedException error) { Thread.currentThread().interrupt(); } }
            @Override public boolean usingProxy() { return false; }
            @Override public void connect() { }
        };
        java.lang.reflect.Field active = AgentConnection.class.getDeclaredField("active"); active.setAccessible(true); active.set(connection, blocked);
        try {
            CompletableFuture.runAsync(connection::cancel).get(1, TimeUnit.SECONDS);
            assertTrue("HTTP cleanup did not run", entered.await(1, TimeUnit.SECONDS));
        } finally { release.countDown(); }
    }

    private void roundTrip(boolean staleResponse) throws Exception {
        byte[] task = "{\"user\":\"Private page text\"}".getBytes(StandardCharsets.UTF_8);
        byte[] answer = "{\"text\":\"A direct answer\"}".getBytes(StandardCharsets.UTF_8);
        try (ServerSocket server = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))) {
            server.setSoTimeout(5000);
            CompletableFuture<Void> fixture = CompletableFuture.runAsync(() -> {
                try (Socket socket = server.accept()) {
                    socket.setSoTimeout(5000);
                    BufferedInputStream input = new BufferedInputStream(socket.getInputStream());
                    String headers = header(input);
                    assertTrue(headers.startsWith("POST /v1/generate HTTP/1.1\r\n"));
                    assertFalse(headers.contains(KEY));
                    int length = -1;
                    for (String line : headers.split("\r\n")) if (line.toLowerCase(java.util.Locale.ROOT).startsWith("content-length:")) {
                        length = Integer.parseInt(line.substring(line.indexOf(':') + 1).trim());
                    }
                    assertTrue(length >= 28 && length <= AgentConnection.MAX_BODY);
                    byte[] request = new byte[length]; new DataInputStream(input).readFully(request);
                    Cipher decrypt = Cipher.getInstance("AES/GCM/NoPadding");
                    decrypt.init(Cipher.DECRYPT_MODE, new SecretKeySpec(SECRET, "AES"), new GCMParameterSpec(128, request, 0, 12));
                    decrypt.updateAAD(REQUEST_AAD);
                    assertArrayEquals(task, decrypt.doFinal(request, 12, request.length - 12));
                    byte[] aad = Arrays.copyOf(RESPONSE_AAD, RESPONSE_AAD.length + 12);
                    if (!staleResponse) System.arraycopy(request, 0, aad, RESPONSE_AAD.length, 12);
                    byte[] nonce = new byte[12]; Arrays.fill(nonce, (byte) 7);
                    Cipher encrypt = Cipher.getInstance("AES/GCM/NoPadding");
                    encrypt.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(SECRET, "AES"), new GCMParameterSpec(128, nonce));
                    encrypt.updateAAD(aad);
                    byte[] encrypted = encrypt.doFinal(answer), combined = Arrays.copyOf(nonce, nonce.length + encrypted.length);
                    System.arraycopy(encrypted, 0, combined, nonce.length, encrypted.length);
                    socket.getOutputStream().write(("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: "
                            + combined.length + "\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                    socket.getOutputStream().write(combined);
                } catch (Exception error) { throw new java.util.concurrent.CompletionException(error); }
            });
            AgentConnection connection = AgentConnection.parse("browseragent://pair?host=127.0.0.1&port=" + server.getLocalPort() + "&key=" + KEY);
            if (staleResponse) {
                try { connection.generate(task); fail("An answer bound to a different request was accepted"); }
                catch (java.io.IOException expected) { assertTrue(expected.getMessage().contains("verify")); }
            } else assertArrayEquals(answer, connection.generate(task));
            fixture.get(5, TimeUnit.SECONDS);
        }
    }

    private String header(BufferedInputStream input) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        while (bytes.size() < 8192) {
            int value = input.read();
            if (value < 0) break;
            bytes.write(value);
            byte[] current = bytes.toByteArray(); int n = current.length;
            if (n >= 4 && current[n - 4] == 13 && current[n - 3] == 10 && current[n - 2] == 13 && current[n - 1] == 10) {
                return bytes.toString(StandardCharsets.US_ASCII.name());
            }
        }
        throw new java.io.IOException("Fixture request header was incomplete.");
    }
}
