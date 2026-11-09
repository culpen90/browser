import Darwin
import Foundation

/// Optional direct internet access through a router on the local network.
/// SSDP and SOAP are implemented here; no internet discovery service is used.
@MainActor
final class BrowserAgentRouterMapping {
    struct Mapping: Equatable {
        let host: String
        let port: UInt16
    }

    var onExpiration: (() -> Void)?

    private struct Lease {
        let service: Service
        let localAddress: String
        let mapping: Mapping
    }
    struct Service: Equatable {
        let type: String
        let controlURL: URL
    }
    private struct Discovery: Sendable {
        let location: URL
        let localAddress: String
    }

    private var lease: Lease?
    private var renewal: Task<Void, Never>?
    private var generation = UUID()
    private var mutationTail: Task<Void, Never>?
    private let session: URLSession
    private let redirectBlocker = RedirectBlocker()
    private static let leaseSeconds = 3_600

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 4
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration, delegate: redirectBlocker, delegateQueue: nil)
    }

    func open(port: UInt16, localAddresses: [String]) async throws -> Mapping {
        await close()
        guard port > 0 else { throw MappingError.unavailable }
        let identity = generation
        let discoveryTask = Task.detached(priority: .utility) {
            try Self.discover(localAddresses: localAddresses)
        }
        let discovered = try await withTaskCancellationHandler {
            try await discoveryTask.value
        } onCancel: { discoveryTask.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        var lastError: Error = MappingError.unavailable
        for router in discovered.prefix(4) {
            try Task.checkCancellation()
            guard generation == identity else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { break }
            do {
                let xml = try await fetch(router.location)
                for service in try Self.services(in: xml, location: router.location) {
                    try Task.checkCancellation()
                    guard generation == identity else { throw CancellationError() }
                    guard ContinuousClock.now < deadline else { throw MappingError.unavailable }
                    let addressXML = try await soap(service, action: "GetExternalIPAddress", arguments: [])
                    guard let host = try Self.externalAddress(in: addressXML), Self.isPublicIPv4(host) else {
                        throw MappingError.noPublicAddress
                    }
                    let candidate = Lease(service: service, localAddress: router.localAddress,
                                          mapping: Mapping(host: host, port: port))
                    try await mutate { [self] in
                        guard generation == identity else { throw CancellationError() }
                        try await add(candidate)
                        if Task.isCancelled || generation != identity {
                            // Finish cleanup before a later Open can install the same port.
                            await Task { try? await self.delete(candidate) }.value
                            throw CancellationError()
                        }
                        lease = candidate
                    }
                    scheduleRenewal(identity: identity)
                    return candidate.mapping
                }
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        if let error = lastError as? MappingError { throw error }
        throw MappingError.unavailable
    }

    func close() async {
        generation = UUID()
        renewal?.cancel()
        renewal = nil
        let previous = lease
        lease = nil
        if let previous {
            try? await mutate { [self] in try await delete(previous) }
        }
    }

    private func scheduleRenewal(identity: UUID) {
        renewal = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1_200)) }
                catch { return }
                guard let self, self.generation == identity, let lease = self.lease else { return }
                do {
                    try await self.mutate { [self] in
                        guard self.generation == identity else { throw CancellationError() }
                        try await self.add(lease)
                    }
                }
                catch {
                    guard self.generation == identity, !Task.isCancelled else { return }
                    self.lease = nil
                    try? await self.mutate { [self] in try await self.delete(lease) }
                    guard self.generation == identity else { return }
                    self.onExpiration?()
                    return
                }
            }
        }
    }

    /// Port changes stay ordered even when Stop interrupts a pending Open.
    private func mutate(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        let previous = mutationTail
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            try await operation()
        }
        mutationTail = Task { _ = try? await task.value }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func add(_ lease: Lease) async throws {
        let port = String(lease.mapping.port)
        _ = try await soap(lease.service, action: "AddPortMapping", arguments: [
            ("NewRemoteHost", ""), ("NewExternalPort", port), ("NewProtocol", "TCP"),
            ("NewInternalPort", port), ("NewInternalClient", lease.localAddress),
            ("NewEnabled", "1"), ("NewPortMappingDescription", "Browser model sharing"),
            ("NewLeaseDuration", String(Self.leaseSeconds))
        ])
    }

    private func delete(_ lease: Lease) async throws {
        _ = try await soap(lease.service, action: "DeletePortMapping", arguments: [
            ("NewRemoteHost", ""), ("NewExternalPort", String(lease.mapping.port)), ("NewProtocol", "TCP")
        ])
    }

    private func soap(_ service: Service, action: String, arguments: [(String, String)]) async throws -> Data {
        var request = URLRequest(url: service.controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.type)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        let body = arguments.map { "<\($0.0)>\(Self.escapeXML($0.1))</\($0.0)>" }.joined()
        request.httpBody = Data("""
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(service.type)">\(body)</u:\(action)></s:Body></s:Envelope>
        """.utf8)
        let response = try await fetch(request, limit: 65_536)
        let parser = RouterXML()
        try parser.parse(response)
        guard !parser.names.contains("Fault"), parser.names.contains(action + "Response") else {
            throw MappingError.unavailable
        }
        return response
    }

    private func fetch(_ url: URL) async throws -> Data { try await fetch(URLRequest(url: url), limit: 262_144) }

    private func fetch(_ request: URLRequest, limit: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= limit else { throw MappingError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw MappingError.unavailable }
            data.append(byte)
        }
        return data
    }

    private static func escapeXML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    // Only numeric RFC1918 hosts supplied by the responding local router are accepted.
    // Descriptor/control requests cannot redirect or resolve an internet hostname.
    nonisolated static func localURL(_ value: String, relativeTo base: URL? = nil) -> URL? {
        guard value.utf8.count <= 2_048, let url = URL(string: value, relativeTo: base)?.absoluteURL,
              url.scheme?.lowercased() == "http", url.user == nil, url.password == nil,
              url.fragment == nil, let host = url.host, isPrivateIPv4(host),
              (url.port == nil || (1...65_535).contains(url.port!)) else { return nil }
        if let base, host != base.host { return nil }
        return url
    }

    static func services(in data: Data, location: URL) throws -> [Service] {
        guard data.count <= 262_144, localURL(location.absoluteString) != nil else { throw MappingError.unavailable }
        let parser = RouterXML()
        try parser.parse(data)
        let base = parser.urlBase.flatMap { localURL($0, relativeTo: location) } ?? location
        return parser.services.compactMap { fields in
            guard let type = fields["serviceType"], [
                "urn:schemas-upnp-org:service:WANIPConnection:1",
                "urn:schemas-upnp-org:service:WANIPConnection:2",
                "urn:schemas-upnp-org:service:WANPPPConnection:1"
            ].contains(type), let control = fields["controlURL"], let url = localURL(control, relativeTo: base) else { return nil }
            return Service(type: type, controlURL: url)
        }.prefix(3).map { $0 }
    }

    static func externalAddress(in data: Data) throws -> String? {
        guard data.count <= 65_536 else { throw MappingError.unavailable }
        let parser = RouterXML()
        try parser.parse(data)
        return parser.externalAddress
    }

    private nonisolated static func octets(_ address: String) -> [UInt8]? {
        let fields = address.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for field in fields {
            guard !field.isEmpty, field.count <= 3, field.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  field == "0" || !field.hasPrefix("0"), let byte = UInt8(field) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }

    nonisolated static func isPrivateIPv4(_ address: String) -> Bool {
        guard let bytes = octets(address) else { return false }
        return bytes[0] == 10 || bytes[0] == 172 && (16...31).contains(bytes[1]) ||
            bytes[0] == 192 && bytes[1] == 168
    }

    nonisolated static func isPublicIPv4(_ address: String) -> Bool {
        guard let b = octets(address), !isPrivateIPv4(address) else { return false }
        if b[0] == 0 || b[0] == 127 || b[0] >= 224 { return false }
        if b[0] == 100 && (64...127).contains(b[1]) { return false } // Carrier-grade NAT.
        if b[0] == 169 && b[1] == 254 { return false }
        if b[0] == 192 && b[1] == 0 && (b[2] == 0 || b[2] == 2) { return false }
        if b[0] == 192 && b[1] == 88 && b[2] == 99 { return false }
        if b[0] == 198 && (b[1] == 18 || b[1] == 19 || b[1] == 51 && b[2] == 100) { return false }
        if b[0] == 203 && b[1] == 0 && b[2] == 113 { return false }
        return true
    }

    /// Read the system routing table instead of assuming a router address. Some
    /// Wi-Fi networks suppress multicast SSDP but allow the same request by unicast.
    private nonisolated static func systemDefaultGateways() -> [UInt32: String] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP2, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > 0, size <= 4_194_304 else { return [:] }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0, size <= data.count else { return [:] }
        data.count = size
        return defaultGateways(in: data)
    }

    nonisolated static func defaultGateways(in table: Data) -> [UInt32: String] {
        table.withUnsafeBytes { bytes in
            var result: [UInt32: String] = [:]
            var offset = 0
            let headerSize = MemoryLayout<rt_msghdr2>.size
            while offset + headerSize <= bytes.count {
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: rt_msghdr2.self)
                let end = offset + Int(header.rtm_msglen)
                guard Int(header.rtm_msglen) >= headerSize, end <= bytes.count else { break }
                defer { offset = end }
                guard header.rtm_version == RTM_VERSION,
                      header.rtm_flags & RTF_UP != 0, header.rtm_flags & RTF_GATEWAY != 0 else { continue }
                var current = offset + headerSize
                var destination: UInt32?
                var gateway: String?
                var valid = true
                for index in 0..<Int(RTAX_MAX) where header.rtm_addrs & (1 << index) != 0 {
                    guard current + 2 <= end else { valid = false; break }
                    let length = Int(bytes[current])
                    // A default route uses a zero-length sockaddr for its zero
                    // netmask; Darwin still reserves four bytes for that entry.
                    let roundedLength = max(4, (length + 3) & ~3)
                    guard current + roundedLength <= end else { valid = false; break }
                    if bytes[current + 1] == UInt8(AF_INET), length >= MemoryLayout<sockaddr_in>.size {
                        var address = bytes.loadUnaligned(fromByteOffset: current, as: sockaddr_in.self)
                        if index == Int(RTAX_DST) { destination = address.sin_addr.s_addr }
                        if index == Int(RTAX_GATEWAY) {
                            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                            gateway = withUnsafePointer(to: &address.sin_addr) {
                                inet_ntop(AF_INET, $0, &buffer, socklen_t(buffer.count))
                            }.map { String(cString: $0) }
                        }
                    }
                    // Darwin routing sockaddr records are aligned to four bytes.
                    current += roundedLength
                }
                if valid, destination == 0, let gateway, isPrivateIPv4(gateway) {
                    result[UInt32(header.rtm_index)] = gateway
                }
            }
            return result
        }
    }

    private nonisolated static func localInterfaceIndexes() -> [String: UInt32] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [:] }
        defer { freeifaddrs(interfaces) }
        var result: [String: UInt32] = [:]
        var current = interfaces
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result[String(cString: buffer)] = if_nametoindex(entry.pointee.ifa_name)
        }
        return result
    }

    private nonisolated static func discover(localAddresses: [String]) throws -> [Discovery] {
        let locals = localAddresses.filter { isPrivateIPv4($0) }.prefix(4)
        guard !locals.isEmpty else { throw MappingError.unavailable }
        let gateways = systemDefaultGateways()
        let indexes = localInterfaceIndexes()
        var sockets: [(descriptor: Int32, local: String, destinations: [String])] = []
        defer { for socket in sockets { Darwin.close(socket.descriptor) } }
        let searches = ["urn:schemas-upnp-org:service:WANIPConnection:2",
                        "urn:schemas-upnp-org:service:WANIPConnection:1",
                        "urn:schemas-upnp-org:service:WANPPPConnection:1",
                        "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
                        "urn:schemas-upnp-org:device:InternetGatewayDevice:1"]
        for local in locals {
            let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard descriptor >= 0 else { continue }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            inet_pton(AF_INET, local, &address.sin_addr)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { Darwin.close(descriptor); continue }
            var interface = address.sin_addr
            _ = withUnsafePointer(to: &interface) {
                setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_IF, $0, socklen_t(MemoryLayout<in_addr>.size))
            }
            var ttl: UInt8 = 2
            _ = withUnsafePointer(to: &ttl) { setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_TTL, $0, 1) }
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            var destinations = ["239.255.255.250"]
            if let index = indexes[local], let gateway = gateways[index] { destinations.append(gateway) }
            sockets.append((descriptor, local, destinations))
        }
        guard !sockets.isEmpty else { throw MappingError.unavailable }
        let start = ContinuousClock.now
        var deadline = start.advanced(by: .seconds(4))
        var nextSearch = start
        var rounds = 0
        var results: [Discovery] = []
        var seen = Set<String>()
        var packetCount = 0
        while ContinuousClock.now < deadline, results.count < 8, packetCount < 128 {
            try Task.checkCancellation()
            if rounds < 3, ContinuousClock.now >= nextSearch {
                for socket in sockets {
                    for host in socket.destinations {
                        var destination = sockaddr_in()
                        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                        destination.sin_family = sa_family_t(AF_INET)
                        destination.sin_port = UInt16(1_900).bigEndian
                        inet_pton(AF_INET, host, &destination.sin_addr)
                        for target in searches {
                            let message = Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: \(target)\r\n\r\n".utf8)
                            _ = message.withUnsafeBytes { bytes in
                                withUnsafePointer(to: &destination) {
                                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                        sendto(socket.descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                                    }
                                }
                            }
                        }
                    }
                }
                rounds += 1
                nextSearch = start.advanced(by: .seconds(rounds))
            }
            var descriptors = sockets.map { pollfd(fd: $0.descriptor, events: Int16(POLLIN), revents: 0) }
            let ready = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 100) }
            guard ready > 0 else { continue }
            for (index, descriptor) in descriptors.enumerated() where descriptor.revents & Int16(POLLIN) != 0 {
                var buffer = [UInt8](repeating: 0, count: 8_192)
                var sender = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &sender) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                        buffer.withUnsafeMutableBytes { recvfrom(descriptor.fd, $0.baseAddress, $0.count, 0, pointer, &length) }
                    }
                }
                guard count > 0 else { continue }
                packetCount += 1
                guard let packet = String(bytes: buffer.prefix(count), encoding: .utf8),
                      packet.hasPrefix("HTTP/1.1 200") || packet.hasPrefix("HTTP/1.0 200") else { continue }
                var senderBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let senderHost = withUnsafePointer(to: &sender.sin_addr) {
                    inet_ntop(AF_INET, $0, &senderBuffer, socklen_t(senderBuffer.count))
                }.map { String(cString: $0) }
                var location: URL?
                for line in packet.components(separatedBy: "\r\n").dropFirst() {
                    let field = line.split(separator: ":", maxSplits: 1)
                    if field.count == 2, field[0].lowercased() == "location" {
                        location = localURL(field[1].trimmingCharacters(in: .whitespaces))
                        break
                    }
                }
                guard let location, location.host == senderHost,
                      seen.insert(location.absoluteString).inserted else { continue }
                results.append(Discovery(location: location, localAddress: sockets[index].local))
                if results.count == 1 { deadline = min(deadline, ContinuousClock.now.advanced(by: .milliseconds(250))) }
            }
        }
        return results
    }

    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    private final class RouterXML: NSObject, XMLParserDelegate {
        var services: [[String: String]] = []
        var urlBase: String?
        var externalAddress: String?
        var names = Set<String>()
        private var fields: [String: String]?
        private var elements: [String] = []
        private var text = ""
        private var characters = 0

        func parse(_ data: Data) throws {
            // Router responses need no DTD. XMLParser's declaration callbacks vary
            // between platform versions, so reject the declaration before parsing.
            // Removing zero bytes also recognizes ASCII markup in UTF-16/UTF-32.
            let markup = String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
            guard markup.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else {
                throw MappingError.unavailable
            }
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = self
            guard parser.parse() else { throw MappingError.unavailable }
        }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard elements.count < 64 else { parser.abortParsing(); return }
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            elements.append(name)
            names.insert(name)
            text = ""
            if name == "service" { fields = [:] }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            characters += string.utf8.count
            guard characters <= 262_144, text.utf8.count + string.utf8.count <= 8_192 else { parser.abortParsing(); return }
            text += string
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let name = elements.popLast() else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "service" {
                if let fields, services.count < 64 { services.append(fields) }
                fields = nil
            } else if name == "serviceType" || name == "controlURL" { fields?[name] = value }
            else if name == "URLBase" { urlBase = value }
            else if name == "NewExternalIPAddress" { externalAddress = value }
            text = ""
        }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { parser.abortParsing() }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
    }

    private enum MappingError: LocalizedError {
        case unavailable, noPublicAddress
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The router couldn’t open a direct internet connection. Use a public IPv6 address or set up TCP port forwarding on your router."
            case .noPublicAddress: return "The router has no public IPv4 address. Use a reachable IPv6 address or a network with public internet access."
            }
        }
    }
}
