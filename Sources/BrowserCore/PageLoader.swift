import Foundation
import CoreFoundation
import Darwin

public struct LoadedPage {
    public let url: URL
    public let html: String
    public let statusCode: Int?
    public let isPlainText: Bool
}

public enum PageLoadError: LocalizedError {
    case unsupportedScheme
    case unsupportedContent(String)
    case tooLarge(Int)
    case resourceStatus(Int)
    case notAFile

    public var errorDescription: String? {
        switch self {
        case .unsupportedScheme: return "Open an HTTP, HTTPS, or local file address."
        case .unsupportedContent(let type): return "This page has an unsupported content type (\(type))."
        case .tooLarge(let bytes): return "This resource exceeds the \(bytes / 1_000_000) MB loading limit."
        case .resourceStatus(let status): return "The server returned HTTP \(status) for this resource."
        case .notAFile: return "Choose an HTML or text file, rather than a folder."
        }
    }
}

public final class PageLoader {
    public static let maximumPageBytes = 5_000_000
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 40
        configuration.httpAdditionalHeaders = ["User-Agent": "Browser/0.1", "Accept": "text/html,application/xhtml+xml,text/plain;q=0.8,*/*;q=0.1"]
        session = URLSession(configuration: configuration)
    }

    init(session: URLSession) { self.session = session }

    deinit { session.invalidateAndCancel() }

    public func load(_ url: URL) async throws -> LoadedPage {
        let (data, response) = try await fetch(url, maxBytes: Self.maximumPageBytes)
        let mime = response?.mimeType?.lowercased() ?? inferredMIME(url)
        guard ["text/html", "application/xhtml+xml", "text/plain"].contains(mime) else {
            throw PageLoadError.unsupportedContent(mime)
        }
        let plain = mime == "text/plain"
        let source = Self.decode(data, declaredEncoding: response?.textEncodingName, inspectHTML: !plain)
        return LoadedPage(url: response?.url ?? url, html: source,
                          statusCode: (response as? HTTPURLResponse)?.statusCode, isPlainText: plain)
    }

    public func resource(_ url: URL, maxBytes: Int = 8_000_000) async throws -> Data {
        let (data, response) = try await fetch(url, maxBytes: maxBytes)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PageLoadError.resourceStatus(http.statusCode)
        }
        return data
    }

    private func fetch(_ url: URL, maxBytes: Int) async throws -> (Data, URLResponse?) {
        guard maxBytes > 0 else { throw PageLoadError.tooLarge(maxBytes) }
        try Task.checkCancellation()
        if url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            // Read metadata from the opened descriptor, avoiding a separate file-provider query.
            var information = stat()
            guard fstat(handle.fileDescriptor, &information) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard information.st_mode & S_IFMT == S_IFREG else { throw PageLoadError.notAFile }
            if information.st_size > maxBytes { throw PageLoadError.tooLarge(maxBytes) }
            var data = Data()
            while let chunk = try handle.read(upToCount: data.count < maxBytes ? min(65_536, maxBytes - data.count) : 1), !chunk.isEmpty {
                try Task.checkCancellation()
                data.append(chunk)
                guard data.count <= maxBytes else { throw PageLoadError.tooLarge(maxBytes) }
            }
            return (data, nil)
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw PageLoadError.unsupportedScheme
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        if response.expectedContentLength > Int64(maxBytes) { throw PageLoadError.tooLarge(maxBytes) }
        var data = Data()
        data.reserveCapacity(min(maxBytes, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            if data.count % 16_384 == 0 { try Task.checkCancellation() }
            guard data.count < maxBytes else { throw PageLoadError.tooLarge(maxBytes) }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, response)
    }

    private func inferredMIME(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "txt", "text", "md", "log", "css", "swift": return "text/plain"
        case "", "html", "htm", "xhtml": return "text/html"
        default: return "application/octet-stream"
        }
    }

    static func decode(_ data: Data, declaredEncoding: String?, inspectHTML: Bool = true) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        let declared = declaredEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
        let charset = declared ?? (inspectHTML ? metaCharset(data) : nil)
        if let charset, let encoding = encoding(named: charset), let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    private static func metaCharset(_ data: Data) -> String? {
        let prefix = String(decoding: data.prefix(8192), as: UTF8.self)
        guard let expression = try? NSRegularExpression(pattern: "(?is)<meta\\b[^>]*charset\\s*=\\s*[\\\"']?\\s*([a-z0-9._-]+)"),
              let match = expression.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)),
              let range = Range(match.range(at: 1), in: prefix) else { return nil }
        return String(prefix[range])
    }

    private static func encoding(named name: String) -> String.Encoding? {
        let normalized = name.lowercased()
        // HTML treats these legacy labels as Windows-1252.
        if ["iso-8859-1", "latin1", "us-ascii"].contains(normalized) { return .windowsCP1252 }
        let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }
}
