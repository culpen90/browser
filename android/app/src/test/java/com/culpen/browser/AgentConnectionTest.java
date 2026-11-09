package com.culpen.browser;

import org.junit.Test;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import static org.junit.Assert.*;

public final class AgentConnectionTest {
    private static final String KEY = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    private static final String ID = "ca153e73-d573-41cf-87e1-cb64b4567961";

    @Test public void acceptsPrivatePCAndEmulatorPairingAddresses() {
        for (String host : new String[]{"10.0.2.2", "10.3.4.5", "172.16.0.1", "172.31.255.254", "192.168.1.2"}) {
            AgentConnection connection = AgentConnection.parse("browseragent://pair?host=" + host + "&port=8766&key=" + KEY);
            assertEquals(host + ":8766", connection.label());
        }
    }
    @Test public void acceptsInternetDomainsAndIPv6WithNamedStableIdentity() throws Exception {
        for (String host : new String[]{"203.0.113.42", "model.example.com", "2001:db8::1234", "::1", "fe80::1%wlan0"}) {
            AgentConnection connection = AgentConnection.parse("browseragent://pair?host="
                    + URLEncoder.encode(host, StandardCharsets.UTF_8.name()) + "&port=38765&key=" + KEY + "&id=" + ID + "&name=Home%20Mac");
            assertEquals(host, connection.host);
            assertEquals("Home Mac", connection.label());
            assertEquals(ID, connection.identity());
            assertEquals("http", connection.endpoint().getScheme());
            assertEquals(38765, connection.endpoint().getPort());
            assertEquals("/v1/generate", connection.endpoint().getPath());
            assertTrue(connection.endpoint().toString().contains(host.contains(":") ? "[" + host + "]" : host));
        }
    }

    @Test public void discoveryChangesAddressWithoutReplacingIdentityOrPairing() {
        AgentConnection saved = AgentConnection.parse("browseragent://pair?host=model.example.com&port=38765&key=" + KEY + "&id=" + ID + "&name=Home");
        AgentConnection local = saved.atDiscoveredAddress("192.168.2.10", 38765);
        assertEquals(saved.identity(), local.identity());
        assertEquals(saved.label(), local.label());
        assertEquals(saved.pairingLink(), local.pairingLink());
        assertEquals("model.example.com", saved.host);
        assertEquals("192.168.2.10", local.host);
    }

    @Test public void rejectsAmbiguousAndMalformedPairingDestinations() {
        for (String host : new String[]{"010.0.2.2", "10.256.2.2", "2001:::1", "10.0.2.2%2fmalicious",
                "model.example.com%2fpath", "user%40model.example.com", "bad%20host", "-bad.example.com", ""}) {
            reject("browseragent://pair?host=" + host + "&port=8766&key=" + KEY);
        }
        reject("https://pair?host=10.0.2.2&port=8766&key=" + KEY);
        reject("browseragent://pair/other?host=10.0.2.2&port=8766&key=" + KEY);
        reject("browseragent://pair?host=10.0.2.2&host=10.0.2.3&port=8766&key=" + KEY);
        reject("browseragent://pair?host=10.0.2.2&port=65536&key=" + KEY);
        reject("browseragent://pair?host=10.0.2.2&port=8766&key=short");
        reject("browseragent://pair?host=10.0.2.2&port=8766&key=" + KEY + "&relay=somewhere");
        reject("browseragent://pair?host=10.0.2.2&port=8766&key=" + KEY + "&id=not-a-uuid");
        reject("browseragent://pair?host=10.0.2.2&port=8766&key=" + KEY + "&name=bad%0Aname");
        reject("browseragent://pair?host=10.0.2.2&port=8766&key=" + KEY + "&id=" + ID + "&id=" + ID);
    }
    private void reject(String link) {
        try { AgentConnection.parse(link); fail("Invalid pairing was accepted"); }
        catch (IllegalArgumentException expected) { assertFalse(expected.getMessage().contains(KEY)); }
    }
}
