package com.culpen.browser;

import org.junit.Test;
import static org.junit.Assert.*;

public final class AgentDeviceListTest {
    private static final String KEY = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    private static final String FIRST = "ca153e73-d573-41cf-87e1-cb64b4567961";
    private static final String SECOND = "ca153e73-d573-41cf-87e1-cb64b4567962";
    private AgentConnection device(String id, String host) {
        return AgentConnection.parse("browseragent://pair?host=" + host + "&port=38765&key=" + KEY + "&id=" + id + "&name=Computer");
    }

    @Test public void remembersMultipleDevicesAndSelectedComputerAfterRestart() throws Exception {
        AgentDeviceList list = new AgentDeviceList();
        list.add(device(FIRST, "first.example.com"));
        list.add(device(SECOND, "second.example.com"));
        list.select(FIRST);
        AgentDeviceList restored = AgentDeviceList.decode(list.encode());
        assertEquals(2, restored.devices().size());
        assertEquals("first.example.com", restored.selected().host);
        restored.select(SECOND);
        assertEquals("second.example.com", AgentDeviceList.decode(restored.encode()).selected().host);
    }

    @Test public void repairsAnEndpointByIdentityAndForgetNeverSwitchesToAnotherComputer() throws Exception {
        AgentDeviceList list = new AgentDeviceList();
        list.add(device(FIRST, "old.example.com"));
        list.add(device(SECOND, "second.example.com"));
        list.add(device(FIRST, "updated.example.com"));
        assertEquals(2, list.devices().size());
        assertEquals("updated.example.com", list.selected().host);
        list.remove(FIRST);
        assertNull(list.selected());
        assertEquals(1, list.devices().size());
        assertNull(AgentDeviceList.decode(list.encode()).selected());
    }

    @Test public void disconnectRetainsSavedComputersAndLegacyLinksSurviveSerialization() throws Exception {
        AgentDeviceList list = new AgentDeviceList();
        AgentConnection legacy = AgentConnection.parse("browseragent://pair?host=10.0.2.2&port=8766&key=" + KEY);
        list.add(legacy); list.select(null);
        AgentDeviceList restored = AgentDeviceList.decode(list.encode());
        assertNull(restored.selected());
        restored.select(legacy.identity());
        assertEquals(legacy.pairingLink(), restored.selected().pairingLink());
    }

    @Test public void rejectsBrokenPersistenceRatherThanSelectingAnUnexpectedDevice() throws Exception {
        AgentDeviceList list = new AgentDeviceList(); list.add(device(FIRST, "first.example.com"));
        try { list.select(SECOND); fail("Unknown device selected"); } catch (IllegalArgumentException expected) { }
        byte[] saved = list.encode();
        try { AgentDeviceList.decode(java.util.Arrays.copyOf(saved, saved.length - 1)); fail("Truncated list accepted"); }
        catch (java.io.IOException expected) { }
        try { AgentDeviceList.decode(java.util.Arrays.copyOf(saved, saved.length + 1)); fail("Trailing data accepted"); }
        catch (java.io.IOException expected) { }
    }
}
