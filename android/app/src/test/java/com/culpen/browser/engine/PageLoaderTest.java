package com.culpen.browser.engine;

import org.junit.Test;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InterruptedIOException;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import static org.junit.Assert.*;

public class PageLoaderTest {
    @Test public void enforcesRemoteLocalResourceBoundary() {
        URI remote = URI.create("https://example.com/");
        assertTrue(PageLoader.resourceAllowed(URI.create("http://example.com/image.png"), remote));
        assertFalse(PageLoader.resourceAllowed(URI.create("file:///sdcard/private.txt"), remote));
        assertFalse(PageLoader.resourceAllowed(URI.create("content://provider/document/secret"), remote));
        assertFalse(PageLoader.resourceAllowed(URI.create("asset:/home.html"), remote));
        assertTrue(PageLoader.resourceAllowed(URI.create("asset:/demo/pixel.png"), URI.create("asset:/demo/index.html")));
        assertFalse(PageLoader.resourceAllowed(URI.create("asset:/../secret"), URI.create("browser:home")));
        assertFalse(PageLoader.resourceAllowed(URI.create("javascript:alert(1)"), remote));
        assertFalse(PageLoader.resourceAllowed(URI.create("https://user:pass@example.com/"), remote));
    }
    @Test public void readsExactlyLimitAndRejectsOneExtraByte() throws Exception {
        PageLoader.Cancellation token = new PageLoader.Cancellation();
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
        assertArrayEquals(new byte[10], PageLoader.readBounded(new ByteArrayInputStream(new byte[10]), 10, token, deadline));
        try { PageLoader.readBounded(new ByteArrayInputStream(new byte[11]), 10, token, deadline); fail("Expected limit failure"); }
        catch (IOException expected) { assertTrue(expected.getMessage().contains("limit")); }
        token.cancel();
        try { PageLoader.readBounded(new ByteArrayInputStream(new byte[1]), 10, token, deadline); fail("Expected cancellation"); }
        catch (InterruptedIOException expected) { assertTrue(token.isCancelled()); }
    }
    @Test public void decodingHandlesBomMetaAndLegacyLabels() {
        assertEquals("é", PageLoader.decode(new byte[]{(byte)0xef,(byte)0xbb,(byte)0xbf,(byte)0xc3,(byte)0xa9}, "windows-1252", true));
        assertEquals("A", PageLoader.decode(new byte[]{(byte)0xff,(byte)0xfe,65,0}, null, true));
        assertEquals("€", PageLoader.decode(new byte[]{(byte)0x80}, "iso-8859-1", true));
        byte[] source = "<meta charset=windows-1252>€".getBytes(java.nio.charset.Charset.forName("windows-1252"));
        assertTrue(PageLoader.decode(source, null, true).endsWith("€"));
        assertEquals("“hi”", PageLoader.decode(new byte[]{(byte)0x93,104,105,(byte)0x94}, null, false));
    }
    @Test public void followsRedirectsAndKeepsStylesInDocumentOrder() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        AtomicBoolean cookieSeen = new AtomicBoolean();
        server.createContext("/start", exchange -> {
            exchange.getResponseHeaders().add("Location", "/page");
            exchange.getResponseHeaders().add("Set-Cookie", "session=yes; Path=/");
            exchange.sendResponseHeaders(302, -1); exchange.close();
        });
        server.createContext("/page", exchange -> {
            cookieSeen.set(exchange.getRequestHeaders().getFirst("Cookie") != null);
            byte[] body = ("<title>Loaded</title><link rel=stylesheet href=/slow.css><style>p{color:blue}</style>"
                    + "<link rel=stylesheet href=/last.css><body><p>Hello</p><img src=/pixel.png></body>").getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "text/html; charset=utf-8");
            exchange.sendResponseHeaders(200, body.length); exchange.getResponseBody().write(body); exchange.close();
        });
        server.createContext("/slow.css", exchange -> {
            byte[] body = "p{color:red}".getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, body.length); exchange.getResponseBody().write(body); exchange.close();
        });
        server.createContext("/last.css", exchange -> {
            byte[] body = "p{color:green}".getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, body.length); exchange.getResponseBody().write(body); exchange.close();
        });
        server.createContext("/pixel.png", exchange -> {
            byte[] body = {1,2,3}; exchange.sendResponseHeaders(200, body.length); exchange.getResponseBody().write(body); exchange.close();
        });
        server.start();
        try {
            String base = "http://127.0.0.1:" + server.getAddress().getPort();
            PageLoader.LoadedPage loaded = new PageLoader(null).load(URI.create(base + "/start#top"), new PageLoader.Cancellation());
            assertEquals(URI.create(base + "/page#top"), loaded.url);
            assertEquals("Loaded", loaded.document.title());
            assertTrue(cookieSeen.get());
            assertTrue(loaded.css.indexOf("red") < loaded.css.indexOf("blue"));
            assertTrue(loaded.css.indexOf("blue") < loaded.css.indexOf("green"));
            assertArrayEquals(new byte[]{1,2,3}, loaded.images.get(base + "/pixel.png"));
        } finally { server.stop(0); }
    }
    @Test public void rejectsRedirectsToLocalAndOversizedDocuments() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/redirect", exchange -> {
            exchange.getResponseHeaders().add("Location", "file:///sdcard/private.html");
            exchange.sendResponseHeaders(302, -1); exchange.close();
        });
        server.createContext("/large", exchange -> {
            exchange.getResponseHeaders().add("Content-Type", "text/html");
            exchange.sendResponseHeaders(200, PageLoader.MAXIMUM_PAGE_BYTES + 1L); exchange.close();
        });
        server.start();
        try {
            String base = "http://127.0.0.1:" + server.getAddress().getPort();
            for (String path : new String[]{"/redirect", "/large"}) {
                try { new PageLoader(null).load(URI.create(base + path), new PageLoader.Cancellation()); fail("Expected rejection"); }
                catch (IOException expected) { assertNotNull(expected.getMessage()); }
            }
        } finally { server.stop(0); }
    }
    @Test public void cancellationDisconnectsPendingHttpRequest() throws Exception {
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        CountDownLatch requestStarted = new CountDownLatch(1), release = new CountDownLatch(1);
        server.createContext("/slow", exchange -> {
            requestStarted.countDown();
            try { release.await(5, TimeUnit.SECONDS); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            exchange.close();
        });
        server.start();
        java.util.concurrent.ExecutorService pool = Executors.newSingleThreadExecutor();
        try {
            PageLoader.Cancellation token = new PageLoader.Cancellation();
            Future<Boolean> result = pool.submit(() -> {
                try { new PageLoader(null).load(URI.create("http://127.0.0.1:" + server.getAddress().getPort() + "/slow"), token); return false; }
                catch (IOException expected) { return true; }
            });
            assertTrue(requestStarted.await(3, TimeUnit.SECONDS));
            token.cancel(); release.countDown();
            assertTrue(result.get(3, TimeUnit.SECONDS));
        } finally { release.countDown(); pool.shutdownNow(); server.stop(0); }
    }
    /** Minimal loopback HTTP fixture; uses only Java APIs present in Android's boot classpath. */
    private static final class HttpServer {
        private final java.net.ServerSocket listener;
        private final java.util.Map<String, Handler> handlers = new java.util.concurrent.ConcurrentHashMap<>();
        private final java.util.Set<java.net.Socket> sockets = java.util.concurrent.ConcurrentHashMap.newKeySet();
        private final java.util.concurrent.ExecutorService workers = Executors.newCachedThreadPool(runnable -> {
            Thread thread = new Thread(runnable, "HTTP test server"); thread.setDaemon(true); return thread;
        });
        private volatile boolean stopped;
        private HttpServer(InetSocketAddress address) throws IOException {
            listener = new java.net.ServerSocket(); listener.bind(address);
        }
        static HttpServer create(InetSocketAddress address, int backlog) throws IOException { return new HttpServer(address); }
        void createContext(String path, Handler handler) { handlers.put(path, handler); }
        InetSocketAddress getAddress() { return (InetSocketAddress) listener.getLocalSocketAddress(); }
        void start() {
            workers.submit(() -> {
                while (!stopped) {
                    try {
                        java.net.Socket socket = listener.accept(); sockets.add(socket);
                        workers.submit(() -> {
                            try {
                                socket.setSoTimeout(5000);
                                java.io.BufferedReader input = new java.io.BufferedReader(new java.io.InputStreamReader(socket.getInputStream(), StandardCharsets.US_ASCII));
                                String request = input.readLine();
                                if (request == null) return;
                                String path = URI.create(request.split(" ")[1]).getPath();
                                Exchange exchange = new Exchange(socket);
                                for (String line; (line = input.readLine()) != null && !line.isEmpty();) {
                                    int colon = line.indexOf(':');
                                    if (colon > 0) exchange.requestHeaders.add(line.substring(0, colon), line.substring(colon + 1).trim());
                                }
                                Handler handler = handlers.get(path);
                                if (handler == null) { exchange.sendResponseHeaders(404, -1); exchange.close(); }
                                else handler.handle(exchange);
                            } catch (IOException ignored) {} finally { sockets.remove(socket); try { socket.close(); } catch (IOException ignored) {} }
                        });
                    } catch (IOException ignored) { if (!stopped) throw new RuntimeException(ignored); }
                }
            });
        }
        void stop(int delay) {
            stopped = true;
            try { listener.close(); } catch (IOException ignored) {}
            for (java.net.Socket socket : sockets) try { socket.close(); } catch (IOException ignored) {}
            workers.shutdownNow();
        }
    }
    private interface Handler { void handle(Exchange exchange) throws IOException; }
    private static final class Headers extends java.util.TreeMap<String, java.util.List<String>> {
        Headers() { super(String.CASE_INSENSITIVE_ORDER); }
        void add(String key, String value) { computeIfAbsent(key, ignored -> new java.util.ArrayList<>()).add(value); }
        String getFirst(String key) { java.util.List<String> values = get(key); return values == null || values.isEmpty() ? null : values.get(0); }
    }
    private static final class Exchange {
        private final java.net.Socket socket;
        private final Headers responseHeaders = new Headers(), requestHeaders = new Headers();
        Exchange(java.net.Socket socket) { this.socket = socket; }
        Headers getResponseHeaders() { return responseHeaders; }
        Headers getRequestHeaders() { return requestHeaders; }
        void sendResponseHeaders(int code, long length) throws IOException {
            StringBuilder headers = new StringBuilder("HTTP/1.1 " + code + " Status\r\nConnection: close\r\nContent-Length: " + Math.max(0, length) + "\r\n");
            for (java.util.Map.Entry<String, java.util.List<String>> entry : responseHeaders.entrySet()) {
                for (String value : entry.getValue()) headers.append(entry.getKey()).append(": ").append(value).append("\r\n");
            }
            headers.append("\r\n"); socket.getOutputStream().write(headers.toString().getBytes(StandardCharsets.US_ASCII));
            socket.getOutputStream().flush();
        }
        java.io.OutputStream getResponseBody() throws IOException { return socket.getOutputStream(); }
        void close() { try { socket.close(); } catch (IOException ignored) {} }
    }
}
