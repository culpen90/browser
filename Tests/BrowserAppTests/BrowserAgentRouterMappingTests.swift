import Darwin
import Foundation
import XCTest
@testable import BrowserApp

final class BrowserAgentRouterMappingTests: XCTestCase {
    func testDefaultGatewayParsingUsesOnlyActivePrivateIPv4DefaultRoutes() throws {
        let table = route(interface: 5, destination: "0.0.0.0", gateway: "192.168.1.1") +
            route(interface: 7, destination: "0.0.0.0", gateway: "10.20.30.1") +
            route(interface: 8, destination: "192.168.70.0", gateway: "192.168.70.1") +
            route(interface: 9, destination: "0.0.0.0", gateway: "127.0.0.1") +
            route(interface: 10, destination: "0.0.0.0", gateway: "198.51.100.1") +
            route(interface: 11, destination: "0.0.0.0", gateway: "192.168.80.1", active: false)
        XCTAssertEqual(BrowserAgentRouterMapping.defaultGateways(in: table), [5: "192.168.1.1", 7: "10.20.30.1"])
        XCTAssertTrue(BrowserAgentRouterMapping.defaultGateways(in: Data()).isEmpty)
        let valid = route(interface: 5, destination: "0.0.0.0", gateway: "192.168.1.1")
        for length in [1, MemoryLayout<rt_msghdr2>.size - 1, valid.count - 1] {
            XCTAssertTrue(BrowserAgentRouterMapping.defaultGateways(in: Data(valid.prefix(length))).isEmpty)
        }
    }

    private func route(interface: UInt16, destination: String, gateway: String, active: Bool = true) -> Data {
        var header = rt_msghdr2()
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr2>.size + 2 * MemoryLayout<sockaddr_in>.size + 4)
        header.rtm_version = UInt8(RTM_VERSION)
        header.rtm_index = interface
        header.rtm_flags = RTF_GATEWAY | (active ? RTF_UP : 0)
        header.rtm_addrs = (1 << RTAX_DST) | (1 << RTAX_GATEWAY) | (1 << RTAX_NETMASK)
        var data = withUnsafeBytes(of: &header) { Data($0) }
        for host in [destination, gateway] {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            inet_pton(AF_INET, host, &address.sin_addr)
            withUnsafeBytes(of: &address) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: [0, 0, 0, 0]) // Darwin's wildcard/default netmask sockaddr.
        return data
    }

    func testRouterURLsStayOnTheRespondingPrivateHost() throws {
        let location = try XCTUnwrap(URL(string: "http://192.168.1.1:49000/igd/root.xml"))
        XCTAssertEqual(BrowserAgentRouterMapping.localURL("../control/wan", relativeTo: location)?.absoluteString,
                       "http://192.168.1.1:49000/control/wan")
        XCTAssertNil(BrowserAgentRouterMapping.localURL("http://10.0.0.1/control", relativeTo: location))
        for value in ["http://example.com/", "http://127.0.0.1/", "http://169.254.169.254/",
                      "http://100.64.0.1/", "https://192.168.1.1/", "http://192.168.1.1:0/",
                      "http://user:password@192.168.1.1/", "file:///etc/passwd",
                      "http://192.168.1.1/control#fragment"] {
            XCTAssertNil(BrowserAgentRouterMapping.localURL(value), value)
        }
    }

    func testPrivateAndCarrierGradeAddressesAreNotAdvertisedAsInternetEndpoints() {
        for value in ["0.1.2.3", "10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.1",
                      "100.64.0.1", "100.127.255.254", "127.0.0.1", "169.254.1.1", "192.0.0.1",
                      "192.0.2.1", "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1",
                      "255.255.255.255", "1.2.3.999", "1.2.3", "01.2.3.4", "::1", "router.local"] {
            XCTAssertFalse(BrowserAgentRouterMapping.isPublicIPv4(value), value)
        }
        XCTAssertTrue(BrowserAgentRouterMapping.isPublicIPv4("1.2.3.4"))
        XCTAssertTrue(BrowserAgentRouterMapping.isPublicIPv4("100.63.255.254"))
        XCTAssertTrue(BrowserAgentRouterMapping.isPublicIPv4("100.128.0.1"))
    }

    @MainActor
    func testDescriptorSelectsOnlyWANServicesAndRejectsRemoteControlURLs() throws {
        let location = try XCTUnwrap(URL(string: "http://192.168.1.1:5000/root.xml"))
        let xml = Data("""
        <root><URLBase>http://192.168.1.1:5001/igd/</URLBase><device><serviceList>
        <service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:2</serviceType><controlURL>wan</controlURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>http://example.com/control</controlURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:WANPPPConnection:1</serviceType><controlURL>/ppp</controlURL></service>
        <service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType><controlURL>/other</controlURL></service>
        </serviceList></device></root>
        """.utf8)
        let services = try BrowserAgentRouterMapping.services(in: xml, location: location)
        XCTAssertEqual(services.count, 2)
        XCTAssertEqual(services[0].controlURL.absoluteString, "http://192.168.1.1:5001/igd/wan")
        XCTAssertEqual(services[1].controlURL.absoluteString, "http://192.168.1.1:5001/ppp")
    }

    @MainActor
    func testSOAPAddressParsingAndHostileXML() throws {
        let xml = Data("""
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
        <u:GetExternalIPAddressResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">
        <NewExternalIPAddress>1.2.3.4</NewExternalIPAddress>
        </u:GetExternalIPAddressResponse></s:Body></s:Envelope>
        """.utf8)
        XCTAssertEqual(try BrowserAgentRouterMapping.externalAddress(in: xml), "1.2.3.4")
        XCTAssertThrowsError(try BrowserAgentRouterMapping.externalAddress(in: Data("<broken>".utf8)))
        let entity = Data("""
        <!DOCTYPE root [<!ENTITY secret SYSTEM "file:///etc/passwd">]>
        <root><NewExternalIPAddress>&secret;</NewExternalIPAddress></root>
        """.utf8)
        XCTAssertThrowsError(try BrowserAgentRouterMapping.externalAddress(in: entity))
        let utf16Entity = try XCTUnwrap(String(data: entity, encoding: .utf8)?.data(using: .utf16))
        XCTAssertThrowsError(try BrowserAgentRouterMapping.externalAddress(in: utf16Entity))
        let internalEntity = Data("""
        <!DOCTYPE root [<!ENTITY value "1.2.3.4">]>
        <root><NewExternalIPAddress>&value;</NewExternalIPAddress></root>
        """.utf8)
        XCTAssertThrowsError(try BrowserAgentRouterMapping.externalAddress(in: internalEntity))
        XCTAssertThrowsError(try BrowserAgentRouterMapping.externalAddress(in: Data(repeating: 0, count: 65_537)))
    }
}
