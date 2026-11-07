package com.culpen.browser;

import org.junit.Test;
import static org.junit.Assert.*;

public final class AgentConnectionTest {
    private static final String KEY = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

    @Test public void acceptsPrivatePCAndEmulatorPairingAddresses() {
        for (String host : new String[]{"10.0.2.2", "10.3.4.5", "172.16.0.1", "172.31.255.254", "192.168.40.2"}) {
            AgentConnection connection = AgentConnection.parse("browseragent://pair?host=" + host + "&port=8766&key=" + KEY);
            assertEquals(host + ":8766", connection.label());
        }
    }
    @Test public void rejectsAmbiguousAndNonlocalPairingDestinations() {
        for (String host : new String[]{"127.0.0.1", "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1",
                "localhost", "10.0.2.2.example.com", "010.0.2.2", "10.256.2.2", "[::1]", "10.0.2.2%2fmalicious"}) {
            reject("browseragent://pair?host=" + host + "&port=8766&key=" + KEY);
        }
        reject("https://pair?host=10.0.2.2&port=8766&key=" + KEY);
        reject("browseragent://pair/other?host=10.0.2.2&port=8766&key=" + KEY);
        reject("browseragent://pair?host=10.0.2.2&host=10.0.2.3&port=8766&key=" + KEY);
        reject("browseragent://pair?host=10.0.2.2&port=65536&key=" + KEY);
        reject("browseragent://pair?host=10.0.2.2&port=8766&key=short");
    }
    private void reject(String link) {
        try { AgentConnection.parse(link); fail("Invalid pairing was accepted"); }
        catch (IllegalArgumentException expected) { assertFalse(expected.getMessage().contains(KEY)); }
    }
}
