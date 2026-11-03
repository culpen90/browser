package com.culpen.browser.engine;

import android.content.Context;
import android.net.Uri;

import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.net.CookieManager;
import java.net.CookiePolicy;
import java.net.HttpURLConnection;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.Charset;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Bounded transport and resource orchestration for the independent rendering engine. */
public final class PageLoader {
    public static final int MAXIMUM_PAGE_BYTES = 5_000_000;
    public static final int MAXIMUM_STYLE_BYTES = 1_000_000;
    public static final int MAXIMUM_IMAGE_BYTES = 8_000_000;
    public static final int MAXIMUM_TOTAL_IMAGE_BYTES = 32_000_000;
    private static final long LOAD_NANOS = TimeUnit.SECONDS.toNanos(40);
    private static final Pattern CHARSET = Pattern.compile("(?i)charset\\s*=\\s*[\"']?\\s*([a-z0-9._-]+)");
    private static final Pattern META_CHARSET = Pattern.compile("(?is)<meta\\b[^>]*charset\\s*=\\s*[\"']?\\s*([a-z0-9._-]+)");
    private final Context context;
    private final CookieManager cookies = new CookieManager(null, CookiePolicy.ACCEPT_ORIGINAL_SERVER);

    public PageLoader(Context context) { this.context = context == null ? null : context.getApplicationContext(); }

    public static final class LoadedPage {
        public final URI url;
        public final URI baseUri;
        public final Html.Document document;
        public final String css;
        /** Keys are absolute resolved image addresses, before any redirect. */
        public final Map<String, byte[]> images;
        public final Integer statusCode;
        public final boolean isPlainText;
        LoadedPage(URI url, URI baseUri, Html.Document document, String css,
                   Map<String, byte[]> images, Integer statusCode, boolean isPlainText) {
            this.url = url; this.baseUri = baseUri; this.document = document; this.css = css;
            this.images = Collections.unmodifiableMap(images); this.statusCode = statusCode;
            this.isPlainText = isPlainText;
        }
    }

    /** One cancellation token per navigation. Cancelling disconnects pending network reads. */
    public static final class Cancellation {
        private volatile boolean cancelled;
        private final Set<HttpURLConnection> connections = new HashSet<>();
        private final Set<Closeable> streams = new HashSet<>();
        public void cancel() {
            List<HttpURLConnection> network;
            List<Closeable> opened;
            synchronized (this) {
                cancelled = true;
                network = new ArrayList<>(connections); opened = new ArrayList<>(streams);
            }
            for (HttpURLConnection connection : network) connection.disconnect();
            for (Closeable stream : opened) { try { stream.close(); } catch (IOException ignored) {} }
        }
        public boolean isCancelled() { return cancelled; }
        public void check() throws InterruptedIOException {
            if (cancelled || Thread.currentThread().isInterrupted()) throw new InterruptedIOException("Loading stopped.");
        }
        synchronized void register(HttpURLConnection connection) throws InterruptedIOException {
            check(); connections.add(connection);
        }
        synchronized void unregister(HttpURLConnection connection) { connections.remove(connection); }
        synchronized void register(Closeable stream) throws IOException {
            if (cancelled) { stream.close(); check(); }
            streams.add(stream);
        }
        synchronized void unregister(Closeable stream) { streams.remove(stream); }
    }

    public LoadedPage load(URI uri, Cancellation cancellation) throws IOException {
        if (cancellation == null) throw new IllegalArgumentException("A cancellation token is required.");
        cancellation.check();
        long deadline = System.nanoTime() + LOAD_NANOS;
        URI transportUri = uri;
        String builtin = uri.toString().split("#", 2)[0];
        String fragment = uri.getRawFragment() == null ? "" : "#" + uri.getRawFragment();
        if ("browser:home".equals(builtin)) transportUri = URI.create("asset:/home.html" + fragment);
        else if ("browser:demo".equals(builtin)) transportUri = URI.create("asset:/demo/index.html" + fragment);
        Response response = fetch(transportUri, MAXIMUM_PAGE_BYTES, cancellation, deadline);
        String mime = response.mime;
        if (!mime.equals("text/html") && !mime.equals("application/xhtml+xml") && !mime.equals("text/plain")) {
            throw new IOException("This page has an unsupported content type (" + mime + ").");
        }
        boolean plain = mime.equals("text/plain");
        String source = decode(response.bytes, response.encoding, !plain);
        if (plain) source = "<html><head><title>Text document</title></head><body><pre>"
                + escape(source) + "</pre></body></html>";
        Html.Document document = Html.parse(source);
        URI shownUrl = "browser".equals(uri.getScheme()) ? uri : response.url;
        URI resourcePage = response.url;
        URI base = document.baseUrl(resourcePage);
        if (!resourceAllowed(base, resourcePage)) base = resourcePage;
        final URI baseUri = base;
        List<Html.Node> styleNodes = new ArrayList<>();
        collectStyles(document.root, styleNodes);
        List<Callable<String>> styleTasks = new ArrayList<>();
        for (Html.Node node : styleNodes) {
            if (styleTasks.size() == 16) break;
            if ("style".equals(node.tag)) styleTasks.add(node::textContent);
            else {
                URI resolved = resolve(base, node.attributes.get("href"));
                if (resolved != null && resourceAllowed(resolved, resourcePage)) {
                    styleTasks.add(() -> {
                        Response style = fetch(resolved, MAXIMUM_STYLE_BYTES, cancellation, deadline);
                        requireResourceSuccess(style);
                        return decode(style.bytes, "utf-8", false);
                    });
                }
            }
        }
        List<String> parts = batches(styleTasks, cancellation, deadline);
        StringBuilder css = new StringBuilder();
        for (String part : parts) if (part != null) css.append(part).append('\n');
        LinkedHashMap<String, URI> imageUris = new LinkedHashMap<>();
        for (Html.Node node : document.root.descendants("img")) {
            URI resolved = resolve(baseUri, node.attributes.get("src"));
            if (resolved != null && resourceAllowed(resolved, resourcePage)) imageUris.put(resolved.toString(), resolved);
            if (imageUris.size() == 24) break;
        }
        List<Callable<byte[]>> imageTasks = new ArrayList<>();
        AtomicInteger remainingImageBytes = new AtomicInteger(MAXIMUM_TOTAL_IMAGE_BYTES);
        for (URI imageUri : imageUris.values()) imageTasks.add(() -> {
            Response image = fetch(imageUri, MAXIMUM_IMAGE_BYTES, cancellation, deadline);
            requireResourceSuccess(image);
            int size = image.bytes.length;
            while (true) {
                int remaining = remainingImageBytes.get();
                if (size > remaining) return null;
                if (remainingImageBytes.compareAndSet(remaining, remaining - size)) return image.bytes;
            }
        });
        List<byte[]> imageResults = batches(imageTasks, cancellation, deadline);
        LinkedHashMap<String, byte[]> images = new LinkedHashMap<>();
        int index = 0, totalImageBytes = 0;
        for (String key : imageUris.keySet()) {
            byte[] bytes = imageResults.get(index++);
            if (bytes != null && bytes.length <= MAXIMUM_TOTAL_IMAGE_BYTES - totalImageBytes) {
                totalImageBytes += bytes.length; images.put(key, bytes);
            }
        }
        cancellation.check();
        return new LoadedPage(shownUrl, baseUri, document, css.toString(), images, response.status, plain);
    }

    private static void collectStyles(Html.Node node, List<Html.Node> found) {
        if (found.size() >= 16) return;
        if ("style".equals(node.tag) || "link".equals(node.tag)
                && (" " + node.attributes.getOrDefault("rel", "").toLowerCase(Locale.ROOT).replaceAll("\\s+", " ") + " ").contains(" stylesheet ")) {
            found.add(node);
        }
        for (Html.Node child : node.children) { collectStyles(child, found); if (found.size() >= 16) break; }
    }

    private static <T> List<T> batches(List<Callable<T>> tasks, Cancellation cancellation, long deadline) throws IOException {
        List<T> values = new ArrayList<>();
        if (tasks.isEmpty()) return values;
        ExecutorService pool = Executors.newFixedThreadPool(4, runnable -> {
            Thread thread = new Thread(runnable, "Browser resources"); thread.setDaemon(true); return thread;
        });
        try {
            for (int start = 0; start < tasks.size(); start += 4) {
                cancellation.check();
                List<Future<T>> pending = new ArrayList<>();
                for (int i = start; i < Math.min(tasks.size(), start + 4); i++) pending.add(pool.submit(tasks.get(i)));
                for (Future<T> future : pending) {
                    cancellation.check();
                    try {
                        long remaining = deadline - System.nanoTime();
                        if (remaining <= 0) { future.cancel(true); values.add(null); }
                        else values.add(future.get(remaining, TimeUnit.NANOSECONDS));
                    } catch (ExecutionException ignored) { values.add(null); }
                    catch (TimeoutException ignored) { future.cancel(true); values.add(null); }
                    catch (InterruptedException e) {
                        Thread.currentThread().interrupt(); throw new InterruptedIOException("Loading stopped.");
                    }
                }
            }
        } finally { pool.shutdownNow(); }
        return values;
    }

    private static void requireResourceSuccess(Response response) throws IOException {
        if (response.status != null && (response.status < 200 || response.status >= 300)) {
            throw new IOException("The resource returned HTTP " + response.status + ".");
        }
    }

    public static boolean resourceAllowed(URI resource, URI page) {
        if (Address.validNetworkAddress(resource)) return true;
        return resource != null && page != null && "asset".equals(resource.getScheme())
                && ("asset".equals(page.getScheme()) || "browser".equals(page.getScheme()))
                && safeAssetPath(resource) != null;
    }

    public static URI resolve(URI base, String reference) {
        if (base == null || reference == null) return null;
        try { return base.resolve(reference.trim()); }
        catch (IllegalArgumentException e) { return null; }
    }

    private Response fetch(URI uri, int maxBytes, Cancellation cancellation, long deadline) throws IOException {
        cancellation.check();
        checkDeadline(deadline);
        if ("asset".equals(uri.getScheme())) {
            String path = safeAssetPath(uri);
            if (context == null || path == null) throw new IOException("This bundled page is unavailable.");
            try (InputStream input = context.getAssets().open(path)) {
                cancellation.register(input);
                try { return new Response(uri, readBounded(input, maxBytes, cancellation, deadline), inferredMime(uri), null, null); }
                finally { cancellation.unregister(input); }
            }
        }
        if ("content".equals(uri.getScheme())) {
            if (context == null) throw new IOException("Choose a local document with Open file.");
            String type = context.getContentResolver().getType(Uri.parse(uri.toString()));
            if (type == null || type.equals("application/octet-stream")) type = inferredMime(uri);
            try (InputStream input = context.getContentResolver().openInputStream(Uri.parse(uri.toString()))) {
                if (input == null) throw new IOException("This document could not be opened.");
                cancellation.register(input);
                try { return new Response(uri, readBounded(input, maxBytes, cancellation, deadline), type, null, null); }
                finally { cancellation.unregister(input); }
            } catch (SecurityException e) { throw new IOException("Choose this document again with Open file.", e); }
        }
        URI current = uri;
        for (int redirects = 0; redirects <= 10; redirects++) {
            cancellation.check(); checkDeadline(deadline);
            if (!Address.validNetworkAddress(current)) throw new IOException("Open an HTTP, HTTPS, or chosen local document.");
            HttpURLConnection connection = (HttpURLConnection) current.toURL().openConnection();
            cancellation.register(connection);
            try {
                connection.setInstanceFollowRedirects(false);
                int timeout = (int) Math.max(1, Math.min(25_000L, TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())));
                connection.setConnectTimeout(timeout); connection.setReadTimeout(timeout);
                connection.setUseCaches(false);
                connection.setRequestProperty("User-Agent", "Browser/0.1 Android");
                connection.setRequestProperty("Accept", "text/html,application/xhtml+xml,text/plain;q=0.8,*/*;q=0.1");
                connection.setRequestProperty("Accept-Encoding", "identity");
                synchronized (cookies) {
                    for (Map.Entry<String, List<String>> entry : cookies.get(current, Collections.emptyMap()).entrySet()) {
                        connection.setRequestProperty(entry.getKey(), String.join("; ", entry.getValue()));
                    }
                }
                int status = connection.getResponseCode();
                synchronized (cookies) { cookies.put(current, connection.getHeaderFields()); }
                if (status == 301 || status == 302 || status == 303 || status == 307 || status == 308) {
                    String location = connection.getHeaderField("Location");
                    if (location == null) throw new IOException("The server returned a redirect without an address.");
                    if (redirects == 10) throw new IOException("This page redirected too many times.");
                    URI next = resolve(current, location);
                    if (!Address.validNetworkAddress(next)) throw new IOException("The server redirected to an unsupported address.");
                    if (next.getRawFragment() == null && current.getRawFragment() != null) next = URI.create(next + "#" + current.getRawFragment());
                    current = next; continue;
                }
                long length = connection.getContentLengthLong();
                if (length > maxBytes) throw tooLarge(maxBytes);
                String contentType = connection.getContentType();
                String mime = contentType == null ? inferredMime(current) : contentType.split(";", 2)[0].trim().toLowerCase(Locale.ROOT);
                String encoding = charsetIn(contentType);
                InputStream responseStream = status >= 400 ? connection.getErrorStream() : connection.getInputStream();
                if (responseStream == null) return new Response(current, new byte[0], mime, encoding, status);
                try (InputStream input = responseStream) {
                    cancellation.register(input);
                    try { return new Response(current, readBounded(input, maxBytes, cancellation, deadline), mime, encoding, status); }
                    finally { cancellation.unregister(input); }
                }
            } finally { cancellation.unregister(connection); connection.disconnect(); }
        }
        throw new IOException("This page redirected too many times.");
    }

    static byte[] readBounded(InputStream input, int maxBytes, Cancellation cancellation, long deadline) throws IOException {
        if (maxBytes < 1) throw tooLarge(maxBytes);
        ByteArrayOutputStream output = new ByteArrayOutputStream(Math.min(maxBytes, 65_536));
        byte[] buffer = new byte[16_384];
        while (true) {
            cancellation.check(); checkDeadline(deadline);
            int count = input.read(buffer, 0, Math.min(buffer.length, maxBytes - output.size() + 1));
            if (count < 0) break;
            if (count == 0) continue;
            if (count > maxBytes - output.size()) throw tooLarge(maxBytes);
            output.write(buffer, 0, count);
        }
        cancellation.check();
        return output.toByteArray();
    }

    private static IOException tooLarge(int maxBytes) { return new IOException("This resource exceeds the " + maxBytes / 1_000_000 + " MB loading limit."); }
    private static void checkDeadline(long deadline) throws InterruptedIOException {
        if (System.nanoTime() >= deadline) throw new InterruptedIOException("The page took too long to load.");
    }
    private static String safeAssetPath(URI uri) {
        if (uri.getAuthority() != null || uri.getPath() == null) return null;
        URI normalized = uri.normalize();
        String path = normalized.getPath();
        if (!path.startsWith("/") || path.contains("..") || path.contains("\\")) return null;
        return path.substring(1);
    }
    private static String inferredMime(URI uri) {
        String path = uri.getPath() == null ? "" : uri.getPath().toLowerCase(Locale.ROOT);
        if (path.matches(".*\\.(txt|text|md|log|css|java|swift)$")) return "text/plain";
        if (path.matches(".*\\.(html|htm|xhtml)$") || !path.substring(path.lastIndexOf('/') + 1).contains(".")) return "text/html";
        return "application/octet-stream";
    }
    private static String charsetIn(String contentType) {
        if (contentType == null) return null;
        Matcher matcher = CHARSET.matcher(contentType);
        return matcher.find() ? matcher.group(1) : null;
    }

    public static String decode(byte[] bytes, String declaredEncoding, boolean inspectHtml) {
        if (bytes.length >= 3 && (bytes[0] & 255) == 0xef && (bytes[1] & 255) == 0xbb && (bytes[2] & 255) == 0xbf) {
            return new String(bytes, 3, bytes.length - 3, StandardCharsets.UTF_8);
        }
        if (bytes.length >= 2 && (bytes[0] & 255) == 0xff && (bytes[1] & 255) == 0xfe) return new String(bytes, 2, bytes.length - 2, StandardCharsets.UTF_16LE);
        if (bytes.length >= 2 && (bytes[0] & 255) == 0xfe && (bytes[1] & 255) == 0xff) return new String(bytes, 2, bytes.length - 2, StandardCharsets.UTF_16BE);
        String charset = declaredEncoding;
        if (charset == null && inspectHtml) {
            Matcher matcher = META_CHARSET.matcher(new String(bytes, 0, Math.min(bytes.length, 8192), StandardCharsets.ISO_8859_1));
            if (matcher.find()) charset = matcher.group(1);
        }
        if (charset != null) {
            String lower = charset.trim().toLowerCase(Locale.ROOT);
            if (lower.equals("iso-8859-1") || lower.equals("latin1") || lower.equals("us-ascii")) charset = "windows-1252";
            try { return Charset.forName(charset).newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString(); }
            catch (IllegalArgumentException | CharacterCodingException ignored) {}
        }
        try { return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString(); }
        catch (CharacterCodingException ignored) { return new String(bytes, Charset.forName("windows-1252")); }
    }
    public static String escape(String value) {
        return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
    }
    private static final class Response {
        final URI url;
        final byte[] bytes;
        final String mime, encoding;
        final Integer status;
        Response(URI url, byte[] bytes, String mime, String encoding, Integer status) {
            this.url = url; this.bytes = bytes; this.mime = mime; this.encoding = encoding; this.status = status;
        }
    }
}
