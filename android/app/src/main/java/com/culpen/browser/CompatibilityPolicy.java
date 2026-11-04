package com.culpen.browser;

import com.culpen.browser.engine.Address;
import java.net.URI;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Locale;
import java.util.Set;

/** Explicit site selection; links in a full-site session remain in that session. */
public final class CompatibilityPolicy {
    private CompatibilityPolicy() {}
    private static final Set<String> REDDIT_HOSTS = new HashSet<>(Arrays.asList(
            "reddit.com", "www.reddit.com", "old.reddit.com", "new.reddit.com", "np.reddit.com",
            "m.reddit.com", "sh.reddit.com", "accounts.reddit.com", "oauth.reddit.com", "mod.reddit.com",
            "redd.it", "www.redd.it", "i.redd.it", "v.redd.it"));

    public static boolean usesCompatibility(URI uri) {
        return canLoad(uri) && REDDIT_HOSTS.contains(uri.getHost().toLowerCase(Locale.ROOT))
                && (uri.getPort() == -1 || uri.getPort() == 80 || uri.getPort() == 443);
    }

    /** Web content cannot launch apps, read local files, or navigate browser-internal pages. */
    public static boolean canLoad(URI uri) { return Address.validNetworkAddress(uri); }
}
