package com.culpen.browser.engine;

import org.junit.Test;
import java.net.URI;
import java.util.Arrays;
import static org.junit.Assert.*;

public class NavigationTest {
    @Test public void resolvesNetworkAddressesWithoutSearch() {
        assertEquals(URI.create("https://example.com"), Address.resolve(" example.com "));
        assertEquals(URI.create("http://localhost:8765/index.html"), Address.resolve("localhost:8765/index.html"));
        assertEquals(URI.create("http://127.0.0.1:8765/"), Address.resolve("127.0.0.1:8765/"));
        assertEquals(URI.create("http://[::1]:8765/"), Address.resolve("[::1]:8765/"));
        assertEquals(URI.create("browser:home"), Address.resolve("BROWSER:HOME"));
        assertEquals(URI.create("browser:demo"), Address.resolve("browser:demo"));
    }
    @Test public void rejectsUnsupportedAmbiguousOrCredentialAddresses() {
        for (String value : new String[]{"", "word search", "javascript:alert(1)", "data:text/html,hello",
                "content://provider/document/1", "file:///sdcard/file.html", "ftp://example.com", "browser:other",
                "https://user:password@example.com", "example.com:0", "example.com:65536", "https://", "/sdcard/page.html"}) {
            assertNull(value, Address.resolve(value));
        }
    }
    @Test public void historyBranchesAndPreservesRedirectReplacement() {
        NavigationHistory history = new NavigationHistory();
        URI a = URI.create("https://example.com/a"), b = URI.create("https://example.com/b"), c = URI.create("https://example.com/c");
        assertNull(history.current()); assertNull(history.back());
        history.push(a); history.push(a); history.push(b);
        assertEquals(2, history.entries().size()); assertEquals(a, history.back());
        history.push(c); assertFalse(history.canGoForward());
        history.replaceCurrent(b); assertEquals(b, history.current());
        assertEquals(a, history.back()); assertEquals(b, history.forward());
        NavigationHistory restored = new NavigationHistory();
        restored.restore(history.entries(), history.index());
        assertEquals(b, restored.current()); assertEquals(a, restored.back());
    }
    @Test(expected = IllegalArgumentException.class) public void rejectsInvalidRestoredHistory() {
        new NavigationHistory().restore(Arrays.asList(URI.create("browser:home")), 3);
    }
}
