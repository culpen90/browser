package com.culpen.browser.engine;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.TimeUnit;

/** Loads search data over HTTPS and renders it as an internal Browser document. */
public final class SearchPage {
    private static final String INTERNAL_PREFIX = "search?q=";
    private static final String ENDPOINT = "https://api.mwmbl.org/api/v2/search/?q=";
    private static final int MAX_RESPONSE_BYTES = 1_000_000;
    private static final int TIMEOUT_MS = 8_000;
    private static final int MAX_RESULTS = 15;

    private SearchPage() {}

    public static URI address(String query) {
        String value = query.trim();
        if (!validQuery(value)) return null;
        try {
            String encoded = URLEncoder.encode(value, StandardCharsets.UTF_8.name()).replace("+", "%20");
            return URI.create("browser:" + INTERNAL_PREFIX + encoded);
        } catch (java.io.UnsupportedEncodingException error) {
            throw new AssertionError(error);
        }
    }

    public static String query(URI address) {
        if (address == null || !"browser".equals(address.getScheme()) || address.getRawFragment() != null) return null;
        String raw = address.getRawSchemeSpecificPart();
        if (!raw.startsWith(INTERNAL_PREFIX)) return null;
        String encoded = raw.substring(INTERNAL_PREFIX.length());
        if (encoded.contains("&")) return null;
        try {
            String value = URLDecoder.decode(encoded, StandardCharsets.UTF_8.name());
            return validQuery(value) ? value : null;
        } catch (java.io.UnsupportedEncodingException error) {
            throw new AssertionError(error);
        } catch (IllegalArgumentException error) {
            return null;
        }
    }

    private static boolean validQuery(String query) {
        return !query.isEmpty() && query.equals(query.trim()) && query.getBytes(StandardCharsets.UTF_8).length <= 400
                && query.codePoints().noneMatch(Character::isISOControl);
    }

    public enum State { SEARCHING, STOPPED, HISTORY, UNAVAILABLE }

    public static Html.Document statusPage(URI address, State state) {
        String body = switch (state) {
            case SEARCHING -> message("Searching the web…", "");
            case STOPPED -> message("Search stopped", "Tap Reload to try again.");
            case HISTORY -> message("Results aren’t available", "Tap Reload to run this search again.");
            case UNAVAILABLE -> message("Search is unavailable", "Check your connection and tap Reload to try again.");
        };
        return document(query(address), body);
    }

    static PageLoader.LoadedPage load(URI address, String query, PageLoader.Cancellation cancellation) throws IOException {
        cancellation.check();
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(TIMEOUT_MS);
        try {
            // Re-encode the decoded query so the request always has one query parameter.
            String encoded = address(query).getRawSchemeSpecificPart().substring(INTERNAL_PREFIX.length());
            HttpURLConnection connection = (HttpURLConnection) URI.create(ENDPOINT + encoded).toURL().openConnection();
            cancellation.register(connection);
            try {
                connection.setInstanceFollowRedirects(false);
                connection.setConnectTimeout(TIMEOUT_MS);
                connection.setReadTimeout(TIMEOUT_MS);
                connection.setUseCaches(false);
                connection.setRequestProperty("Accept", "application/json");
                int status = connection.getResponseCode();
                if (status == 429) {
                    return loaded(address, document(query, message("Too many searches",
                            "The search service limit was reached. Try again later.")), status);
                }
                if (status != 200 || connection.getContentLengthLong() > MAX_RESPONSE_BYTES) {
                    throw new IOException("Search response unavailable.");
                }
                try (InputStream input = connection.getInputStream()) {
                    cancellation.register(input);
                    try {
                        byte[] data = PageLoader.readBounded(input, MAX_RESPONSE_BYTES, cancellation, deadline);
                        return loaded(address, results(query, new String(data, StandardCharsets.UTF_8)), status);
                    } finally {
                        cancellation.unregister(input);
                    }
                }
            } finally {
                cancellation.unregister(connection);
                connection.disconnect();
            }
        } catch (IOException | JSONException error) {
            cancellation.check();
            return loaded(address, statusPage(address, State.UNAVAILABLE), 503);
        }
    }

    static Html.Document results(String query, String json) throws JSONException {
        JSONArray entries = new JSONObject(json).getJSONArray("results");
        StringBuilder rows = new StringBuilder();
        Set<URI> seen = new HashSet<>();
        for (int index = 0; index < entries.length() && seen.size() < MAX_RESULTS; index++) {
            JSONObject entry = entries.optJSONObject(index);
            if (entry == null) continue;
            URI url = resultAddress(string(entry, "url"));
            if (url == null || !seen.add(url)) continue;
            String host = url.getHost();
            String title = string(entry, "title");
            String description = string(entry, "content");
            rows.append("<article><p class=\"site\">").append(PageLoader.escape(host)).append("</p>")
                    .append("<h3><a href=\"").append(PageLoader.escape(url.toASCIIString())).append("\">")
                    .append(PageLoader.escape(title.isEmpty() ? host : preview(title, 180))).append("</a></h3>");
            if (!description.isEmpty()) {
                rows.append("<p class=\"snippet\">").append(PageLoader.escape(preview(description, 280))).append("</p>");
            }
            rows.append("</article>");
        }
        return document(query, seen.isEmpty() ? message("No results found", "Try a different search.") : rows.toString());
    }

    private static URI resultAddress(String value) {
        if (value.length() > 4096) return null;
        try {
            URI url = URI.create(value);
            return Address.validNetworkAddress(url) ? url : null;
        } catch (IllegalArgumentException error) {
            return null;
        }
    }

    private static String string(JSONObject entry, String key) {
        Object value = entry.opt(key);
        return value instanceof String ? ((String) value).trim() : "";
    }

    private static String preview(String text, int length) {
        if (text.codePointCount(0, text.length()) <= length) return text;
        return text.substring(0, text.offsetByCodePoints(0, length)).trim() + "…";
    }

    private static PageLoader.LoadedPage loaded(URI address, Html.Document document, int status) {
        return new PageLoader.LoadedPage(address, address, document, document.embeddedStyles(), Collections.emptyMap(), status, false);
    }

    private static String message(String heading, String detail) {
        return "<section class=\"message\"><h3>" + heading + "</h3><p>" + detail + "</p></section>";
    }

    private static Html.Document document(String query, String body) {
        return Html.parse("<!doctype html><html><head><title>Browser Search</title><style>"
                + "body{padding:20px;color:#26354a;background:#ffffff}"
                + "h1{font-size:30px;margin-top:12px;margin-bottom:10px;color:#18243a}"
                + ".accent{color:#2563eb}"
                + "h2{font-size:16px;font-weight:normal;margin-top:0;margin-bottom:16px;color:#49586d}"
                + ".section-label{font-size:13px;font-weight:bold;color:#245ac7;margin:0}"
                + "article{margin-bottom:20px}"
                + ".site{font-size:13px;color:#49586d;margin:0}"
                + "h3{font-size:19px;font-weight:bold;margin-top:3px;margin-bottom:4px}"
                + "a{color:#245ac7;text-decoration:none}"
                + ".snippet{font-size:15px;color:#35435a;margin:0}"
                + ".message{background:#f2f5fb;padding:16px;margin-bottom:16px}"
                + ".message p{font-size:15px;margin:0}"
                + "footer{font-size:13px;color:#49586d;margin-top:8px;margin-bottom:10px}"
                + "</style></head><body><header><h1>Browser <span class=\"accent\">Search</span></h1><h2>"
                + PageLoader.escape(query) + "</h2><p class=\"section-label\">Web</p><hr></header><main>"
                + body + "</main><footer>Results by Mwmbl · <a href=\"https://creativecommons.org/licenses/by-nc-sa/4.0/\">"
                + "CC BY-NC-SA 4.0</a> · Snippets may be shortened</footer></body></html>");
    }
}
