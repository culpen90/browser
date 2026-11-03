package com.culpen.browser.engine;

import java.net.URI;
import java.net.URISyntaxException;
import java.util.Locale;

/** Resolves addresses locally; address entry never sends input to a search service. */
public final class Address {
    private Address() {}

    public static URI resolve(String input) {
        if (input == null) return null;
        String value = input.trim();
        if (value.isEmpty()) return null;
        String lower = value.toLowerCase(Locale.ROOT);
        if (lower.equals("browser:home") || lower.equals("browser:demo")) return URI.create(lower);
        if (value.startsWith("/") || value.startsWith("~")) return null;
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) {
            String authority = value.split("[/\\?#]", 2)[0];
            int colon = authority.lastIndexOf(':');
            if (colon >= 0 && !authority.startsWith("[")) {
                String port = authority.substring(colon + 1);
                if (port.isEmpty() || !port.matches("[0-9]+")) return null;
            }
            boolean loopback = lower.matches("(?:localhost|127\\.0\\.0\\.1)(?:[:/?#].*)?")
                    || lower.startsWith("[::1]");
            value = (loopback ? "http://" : "https://") + value;
        }
        try {
            URI uri = new URI(value);
            return validNetworkAddress(uri) ? uri : null;
        } catch (URISyntaxException e) {
            return null;
        }
    }

    public static boolean validNetworkAddress(URI uri) {
        if (uri == null) return false;
        String scheme = uri.getScheme();
        return ("http".equalsIgnoreCase(scheme) || "https".equalsIgnoreCase(scheme))
                && uri.getHost() != null && !uri.getHost().isEmpty()
                && uri.getRawUserInfo() == null
                && (uri.getPort() == -1 || uri.getPort() >= 1 && uri.getPort() <= 65535);
    }
}
