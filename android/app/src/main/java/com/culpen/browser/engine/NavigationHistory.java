package com.culpen.browser.engine;

import java.net.URI;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** In-memory history. A new navigation discards the forward branch. */
public final class NavigationHistory {
    private final ArrayList<URI> entries = new ArrayList<>();
    private int index = -1;
    public URI current() { return index >= 0 ? entries.get(index) : null; }
    public boolean canGoBack() { return index > 0; }
    public boolean canGoForward() { return index >= 0 && index + 1 < entries.size(); }
    public int index() { return index; }
    public void restore(List<URI> values, int currentIndex) {
        if (values == null || values.contains(null) || currentIndex < -1 || currentIndex >= values.size()
                || !values.isEmpty() && currentIndex < 0) throw new IllegalArgumentException("Invalid history.");
        entries.clear(); entries.addAll(values); index = currentIndex;
    }
    public List<URI> entries() { return Collections.unmodifiableList(entries); }
    public void push(URI uri) {
        if (uri == null || uri.equals(current())) return;
        while (entries.size() > index + 1) entries.remove(entries.size() - 1);
        entries.add(uri);
        index = entries.size() - 1;
    }
    public URI back() { if (!canGoBack()) return null; --index; return current(); }
    public URI forward() { if (!canGoForward()) return null; ++index; return current(); }
    public void replaceCurrent(URI uri) { if (index < 0) push(uri); else entries.set(index, uri); }
}
