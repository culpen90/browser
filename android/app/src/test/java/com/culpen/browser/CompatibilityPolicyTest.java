package com.culpen.browser;

import org.junit.Test;
import java.net.URI;
import static org.junit.Assert.*;

public class CompatibilityPolicyTest {
    @Test public void redditPagesAndMediaAutomaticallyUseFullSite() {
        for (String value : new String[]{"https://reddit.com/", "https://www.reddit.com/r/android/comments/abc/title/?x=1#comment",
                "https://OLD.REDDIT.COM/login", "https://accounts.reddit.com/", "https://redd.it/abc", "https://i.redd.it/picture.png"}) {
            assertTrue(value, CompatibilityPolicy.usesCompatibility(URI.create(value)));
        }
    }
    @Test public void unrelatedAndDeceptiveOriginsKeepIndependentEngine() {
        for (String value : new String[]{"https://reddit.com.evil.test/", "https://example.com/reddit.com", "https://arbitrary.reddit.com/",
                "https://www.reddit.com:8443/", "https://user:password@www.reddit.com/", "file:///www.reddit.com/index.html",
                "javascript:location='https://reddit.com'", "data:text/html,Reddit", "browser:home"}) {
            assertFalse(value, CompatibilityPolicy.usesCompatibility(URI.create(value)));
        }
        assertFalse(CompatibilityPolicy.usesCompatibility(null));
    }
    @Test public void compatibilityLinksCannotOpenLocalFilesOrExternalApps() {
        for (String value : new String[]{"file:///sdcard/private.txt", "content://private/document/1", "intent://open", "mailto:a@example.com",
                "javascript:alert(1)", "data:text/html,secret", "browser:home", "about:config", "https://a:b@example.com/"}) {
            assertFalse(value, CompatibilityPolicy.canLoad(URI.create(value)));
        }
        assertTrue(CompatibilityPolicy.canLoad(URI.create("https://accounts.example.com/oauth/callback?code=test")));
        assertTrue(CompatibilityPolicy.canLoad(URI.create("http://127.0.0.1:8080/fixture")));
    }
}
