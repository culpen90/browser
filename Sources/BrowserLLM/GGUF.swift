import Foundation

enum GGUFValue: Sendable {
    case unsigned(UInt64)
    case signed(Int64)
    case floating(Double)
    case flag(Bool)
    case text(String)
    case list([GGUFValue])

    var integer: Int? {
        switch self {
        case .unsigned(let value): return Int(exactly: value)
        case .signed(let value): return Int(exactly: value)
        default: return nil
        }
    }

    var number: Double? {
        switch self {
        case .unsigned(let value): return Double(value)
        case .signed(let value): return Double(value)
        case .floating(let value): return value
        default: return nil
        }
    }

    var string: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }

    var array: [GGUFValue]? {
        guard case .list(let value) = self else { return nil }
        return value
    }

    var bool: Bool? {
        guard case .flag(let value) = self else { return nil }
        return value
    }
}

struct GGUFTensor: Sendable {
    let name: String
    let dimensions: [Int]
    let offset: Int
    let type: UInt32
    let elementCount: Int
}

struct GGUFModel: Sendable {
    let data: Data
    let metadata: [String: GGUFValue]
    let tensors: [String: GGUFTensor]

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let (metadata, tensors) = try data.withUnsafeBytes { bytes in
            var reader = GGUFReader(bytes: bytes)
            return try reader.readModel()
        }
        self.data = data
        self.metadata = metadata
        self.tensors = tensors
    }
}

private struct GGUFFormatError: LocalizedError {
    let reason: String

    init(_ reason: String) { self.reason = reason }

    var errorDescription: String? { "Invalid GGUF model. \(reason)" }
}

private enum GGUFType: UInt32 {
    case uint8, int8, uint16, int16, uint32, int32, float32, bool, string, array, uint64, int64, float64

    var minimumByteCount: Int {
        switch self {
        case .uint8, .int8, .bool: return 1
        case .uint16, .int16: return 2
        case .uint32, .int32, .float32: return 4
        case .uint64, .int64, .float64, .string: return 8
        case .array: return 12
        }
    }
}

private struct GGUFReader {
    let bytes: UnsafeRawBufferPointer
    private(set) var position = 0

    mutating func readModel() throws -> ([String: GGUFValue], [String: GGUFTensor]) {
        guard try read(UInt32.self) == 0x4655_4747 else { throw GGUFFormatError("Expected little-endian GGUF magic.") }
        guard try read(UInt32.self) == 3 else { throw GGUFFormatError("Only GGUF version 3 is supported.") }
        let tensorCount = try readCount(maximum: 65_536)
        let metadataCount = try readCount(maximum: 65_536)
        var metadata: [String: GGUFValue] = [:]
        for _ in 0..<metadataCount {
            let key = try readString()
            guard !key.isEmpty, metadata[key] == nil else { throw GGUFFormatError("Duplicate or empty metadata key.") }
            let type = try readType()
            metadata[key] = try readValue(type)
        }
        var alignment = 32
        if let specified = metadata["general.alignment"] {
            guard let value = specified.integer, (8...65_536).contains(value), value.isMultiple(of: 8) else {
                throw GGUFFormatError("Invalid tensor alignment.")
            }
            alignment = value
        }

        var descriptors: [GGUFTensor] = []
        descriptors.reserveCapacity(tensorCount)
        for _ in 0..<tensorCount {
            descriptors.append(try readTensor(alignment: alignment))
        }
        let padding = (alignment - position % alignment) % alignment
        guard padding <= bytes.count - position else { throw GGUFFormatError("Truncated tensor alignment padding.") }
        let dataStart = position + padding
        var tensors: [String: GGUFTensor] = [:]
        var priorEnd = dataStart
        for descriptor in descriptors.sorted(by: { $0.offset < $1.offset }) {
            guard tensors[descriptor.name] == nil else { throw GGUFFormatError("Duplicate tensor \(descriptor.name).") }
            guard descriptor.offset < bytes.count - dataStart else {
                throw GGUFFormatError("Tensor \(descriptor.name) starts outside the file.")
            }
            let offset = dataStart + descriptor.offset
            let length = try tensorByteCount(descriptor)
            guard offset >= priorEnd, length <= bytes.count - offset else {
                throw GGUFFormatError("Tensor \(descriptor.name) overlaps another tensor or extends past the file.")
            }
            priorEnd = offset + length
            tensors[descriptor.name] = GGUFTensor(name: descriptor.name, dimensions: descriptor.dimensions,
                                                offset: offset, type: descriptor.type, elementCount: descriptor.elementCount)
        }
        return (metadata, tensors)
    }

    private mutating func readTensor(alignment: Int) throws -> GGUFTensor {
        let name = try readString()
        let dimensionCount = Int(try read(UInt32.self))
        guard !name.isEmpty, (1...4).contains(dimensionCount) else { throw GGUFFormatError("Invalid tensor descriptor.") }
        var dimensions: [Int] = []
        var elements = 1
        for _ in 0..<dimensionCount {
            let dimension = try readCount()
            let (product, overflow) = elements.multipliedReportingOverflow(by: dimension)
            guard dimension > 0, !overflow else { throw GGUFFormatError("Invalid dimensions for tensor \(name).") }
            dimensions.append(dimension)
            elements = product
        }
        let type = try read(UInt32.self)
        let offset = try readCount()
        guard offset.isMultiple(of: alignment) else { throw GGUFFormatError("Misaligned tensor \(name).") }
        return GGUFTensor(name: name, dimensions: dimensions, offset: offset, type: type, elementCount: elements)
    }

    private func tensorByteCount(_ tensor: GGUFTensor) throws -> Int {
        let block: (elements: Int, bytes: Int)
        switch tensor.type {
        case 0: block = (1, 4) // F32
        case 1: block = (1, 2) // F16
        case 2: block = (32, 18) // Q4_0
        case 8: block = (32, 34) // Q8_0
        case 14: block = (256, 210) // Q6_K
        default: throw GGUFFormatError("Tensor \(tensor.name) uses unsupported GGML type \(tensor.type).")
        }
        guard let rowWidth = tensor.dimensions.first, rowWidth.isMultiple(of: block.elements) else {
            throw GGUFFormatError("Invalid quantization block width for tensor \(tensor.name).")
        }
        let (count, overflow) = (tensor.elementCount / block.elements).multipliedReportingOverflow(by: block.bytes)
        guard !overflow else { throw GGUFFormatError("Invalid size for tensor \(tensor.name).") }
        return count
    }

    private mutating func readType() throws -> GGUFType {
        let code = try read(UInt32.self)
        guard let type = GGUFType(rawValue: code) else { throw GGUFFormatError("Unknown metadata type \(code).") }
        return type
    }

    private mutating func readValue(_ type: GGUFType, depth: Int = 0) throws -> GGUFValue {
        switch type {
        case .uint8: return .unsigned(UInt64(try read(UInt8.self)))
        case .int8: return .signed(Int64(try read(Int8.self)))
        case .uint16: return .unsigned(UInt64(try read(UInt16.self)))
        case .int16: return .signed(Int64(try read(Int16.self)))
        case .uint32: return .unsigned(UInt64(try read(UInt32.self)))
        case .int32: return .signed(Int64(try read(Int32.self)))
        case .uint64: return .unsigned(try read(UInt64.self))
        case .int64: return .signed(try read(Int64.self))
        case .float32: return .floating(Double(Float(bitPattern: try read(UInt32.self))))
        case .float64: return .floating(Double(bitPattern: try read(UInt64.self)))
        case .bool:
            let value = try read(UInt8.self)
            guard value < 2 else { throw GGUFFormatError("Invalid Boolean value.") }
            return .flag(value == 1)
        case .string: return .text(try readString())
        case .array:
            guard depth < 8 else { throw GGUFFormatError("Metadata arrays are nested too deeply.") }
            let elementType = try readType()
            let count = try readCount(maximum: 1_000_000)
            guard count <= (bytes.count - position) / elementType.minimumByteCount else {
                throw GGUFFormatError("Truncated metadata array.")
            }
            var values: [GGUFValue] = []
            values.reserveCapacity(count)
            for _ in 0..<count {
                values.append(try readValue(elementType, depth: depth + 1))
            }
            return .list(values)
        }
    }

    private mutating func readString() throws -> String {
        let count = try readCount(maximum: 16 * 1024 * 1024)
        guard count <= bytes.count - position else { throw GGUFFormatError("Truncated string.") }
        defer { position += count }
        guard let result = String(bytes: bytes[position..<(position + count)], encoding: .utf8) else {
            throw GGUFFormatError("Metadata contains invalid UTF-8.")
        }
        return result
    }

    private mutating func readCount(maximum: Int = Int.max) throws -> Int {
        guard let count = Int(exactly: try read(UInt64.self)), count <= maximum else {
            throw GGUFFormatError("Count or offset exceeds the supported range.")
        }
        return count
    }

    private mutating func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard size <= bytes.count - position else { throw GGUFFormatError("Truncated model header.") }
        defer { position += size }
        return T(littleEndian: bytes.loadUnaligned(fromByteOffset: position, as: type))
    }
}
