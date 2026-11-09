package com.culpen.browser.engine;

import java.net.URI;
import java.net.URISyntaxException;
import java.util.Locale;
import java.util.regex.Pattern;

/** Separates address-only navigation from searches initiated in the address field. */
public final class Address {
    private static final Pattern EXPLICIT_SCHEME = Pattern.compile(
            "^(?:[a-z][a-z0-9+.-]*://|(?:https?|file|browser|browseragent|javascript|data|mailto|tel|ftp|about):)",
            Pattern.CASE_INSENSITIVE);
    private Address() {}

    /** The address field treats a plain word or phrase as a search, while preserving explicit navigation. */
    public static URI resolveOmnibox(String input) {
        if (input == null) return null;
        String value = input.trim();
        if (value.isEmpty()) return null;
        if (value.startsWith("browser:search?")) {
            try {
                String query = SearchPage.query(URI.create(value));
                return query == null ? null : SearchPage.address(query);
            } catch (IllegalArgumentException error) {
                return null;
            }
        }
        URI address = resolve(value);
        String addressForm = value.endsWith("?") || value.endsWith("#") ? value.substring(0, value.length() - 1) : value;
        if (address != null && (!addressForm.equalsIgnoreCase(address.getHost()) || addressForm.contains(".")
                || addressForm.startsWith("[") || addressForm.equalsIgnoreCase("localhost"))) return address;
        if (EXPLICIT_SCHEME.matcher(value).find() || value.startsWith("/") || value.startsWith("~")) return null;
        String authority = value.split("[/\\?#]", 2)[0];
        if (address == null && authority.codePoints().noneMatch(Character::isWhitespace)
                && (value.contains("/") || authority.contains("@") || authority.contains(":") || authority.contains("."))) return null;
        return SearchPage.address(value);
    }

    public static URI resolve(String input) {
        if (input == null) return null;
        String value = input.trim();
        if (value.isEmpty()) return null;
        String lower = value.toLowerCase(Locale.ROOT);
        if (lower.equals("browser:home") || lower.equals("browser:demo")) return URI.create(lower);
        if (value.startsWith("/") || value.startsWith("~")) return null;
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) {
            if (EXPLICIT_SCHEME.matcher(value).find()) return null;
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
