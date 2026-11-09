package com.culpen.browser;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

/** The device list is serialized here and encrypted as a whole by AgentPairingStore. */
final class AgentDeviceList {
    private final List<AgentConnection> devices = new ArrayList<>();
    private String selected;

    List<AgentConnection> devices() { return new ArrayList<>(devices); }
    AgentConnection selected() {
        for (AgentConnection device : devices) if (device.identity().equals(selected)) return device;
        return null;
    }
    void add(AgentConnection device) {
        for (int i = 0; i < devices.size(); i++) if (devices.get(i).identity().equals(device.identity())) {
            devices.set(i, device); selected = device.identity(); return;
        }
        if (devices.size() >= 32) throw new IllegalArgumentException("Forget a saved device before adding another.");
        devices.add(device); selected = device.identity();
    }
    void select(String identity) {
        if (identity != null && devices.stream().noneMatch(device -> device.identity().equals(identity))) {
            throw new IllegalArgumentException("The device is no longer saved.");
        }
        selected = identity;
    }
    void remove(String identity) {
        devices.removeIf(device -> device.identity().equals(identity));
        if (identity.equals(selected)) selected = null;
    }
    byte[] encode() throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (DataOutputStream output = new DataOutputStream(bytes)) {
            output.writeInt(1); output.writeUTF(selected == null ? "" : selected); output.writeInt(devices.size());
            for (AgentConnection device : devices) output.writeUTF(device.pairingLink());
        }
        return bytes.toByteArray();
    }
    static AgentDeviceList decode(byte[] bytes) throws IOException {
        if (bytes.length > 270_000) throw new IOException("Invalid saved devices.");
        AgentDeviceList result = new AgentDeviceList();
        try (DataInputStream input = new DataInputStream(new ByteArrayInputStream(bytes))) {
            if (input.readInt() != 1) throw new IOException("Unsupported saved devices.");
            String selected = input.readUTF();
            int count = input.readInt();
            if (count < 0 || count > 32) throw new IOException("Invalid saved device count.");
            for (int i = 0; i < count; i++) {
                AgentConnection device = AgentConnection.parse(input.readUTF());
                if (result.devices.stream().anyMatch(existing -> existing.identity().equals(device.identity()))) {
                    throw new IOException("Duplicate saved device.");
                }
                result.devices.add(device);
            }
            result.select(selected.isEmpty() ? null : selected);
            if (input.read() != -1) throw new IOException("Invalid saved devices.");
        } catch (IllegalArgumentException error) { throw new IOException("Invalid saved device."); }
        return result;
    }
}
