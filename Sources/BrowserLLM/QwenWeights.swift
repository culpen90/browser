import Accelerate
import BrowserLLMKernels
import Foundation

public enum BrowserLLMError: LocalizedError {
    case unsupportedModel
    case missingTensor(String)
    case unsupportedTensor(String)
    case contextTooLong
    case emptyGeneration

    public var errorDescription: String? {
        switch self {
        case .unsupportedModel: return "Choose a compatible Qwen2 or Qwen2.5 Instruct GGUF model."
        case .missingTensor(let name): return "The model is missing the expected tensor: \(name)."
        case .unsupportedTensor(let name): return "The model has an unsupported shape or weight format in \(name). Use Q4_0, Q8_0, Q6_K, or FP16."
        case .contextTooLong: return "The task and page exceed the local model’s context. Try a shorter task."
        case .emptyGeneration: return "The model did not return a usable response. Try rephrasing the task."
        }
    }
}

struct QwenMatrix {
    private let tensor: GGUFTensor
    let columns: Int
    let rows: Int
    private let rowBytes: Int

    init(_ name: String, columns: Int, rows: Int, in model: GGUFModel) throws {
        guard let tensor = model.tensors[name] else { throw BrowserLLMError.missingTensor(name) }
        guard tensor.dimensions == [columns, rows] else { throw BrowserLLMError.unsupportedTensor(name) }
        self.tensor = tensor
        self.columns = columns
        self.rows = rows
        switch tensor.type {
        case 0: rowBytes = columns * 4
        case 1: rowBytes = columns * 2
        case 2 where columns.isMultiple(of: 32): rowBytes = columns / 32 * 18
        case 8 where columns.isMultiple(of: 32): rowBytes = columns / 32 * 34
        case 14 where columns.isMultiple(of: 256): rowBytes = columns / 256 * 210
        default: throw BrowserLLMError.unsupportedTensor(name)
        }
        guard tensor.offset <= model.data.count - rows * rowBytes else {
            throw BrowserLLMError.unsupportedTensor(name)
        }
    }

    func readRow(_ row: Int, weights: UnsafePointer<UInt8>, into destination: UnsafeMutablePointer<Float>) {
        browser_unpack_weights(weights + tensor.offset + row * rowBytes, tensor.type, columns, destination)
    }

    func apply(_ input: [Float], weights: UnsafePointer<UInt8>) -> [Float] {
        let count = input.count / columns
        var output = [Float](repeating: 0, count: count * rows)
        if count == 1, tensor.type == 2 || tensor.type == 8 || tensor.type == 14 {
            var quantized = [Int8](repeating: 0, count: columns)
            var scales = [Float](repeating: 0, count: columns / 32)
            browser_quantize_input(input, columns, &quantized, &scales)
            quantized.withUnsafeBufferPointer { values in
                scales.withUnsafeBufferPointer { scales in
                    output.withUnsafeMutableBufferPointer { destination in
                        forRowGroups { start, length in
                            browser_quantized_matvec(weights + tensor.offset + start * rowBytes, tensor.type, columns,
                                                     length, values.baseAddress!, scales.baseAddress!,
                                                     destination.baseAddress! + start)
                        }
                    }
                }
            }
            return output
        }

        if count == 1, tensor.type == 1 {
            input.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { output in
                    forRowGroups { start, length in
                        let batchSize = min(length, 128)
                        let matrix = UnsafeMutablePointer<Float>.allocate(capacity: batchSize * columns)
                        defer { matrix.deallocate() }
                        for row in stride(from: start, to: start + length, by: batchSize) {
                            let batch = min(batchSize, start + length - row)
                            browser_unpack_weights(weights + tensor.offset + row * rowBytes, tensor.type,
                                                   batch * columns, matrix)
                            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(batch), Int32(columns), 1,
                                        matrix, Int32(columns), input.baseAddress!, 1, 0, output.baseAddress! + row, 1)
                        }
                    }
                }
            }
        } else if tensor.type == 0 {
            multiply(input, count: count, matrix: UnsafeRawPointer(weights + tensor.offset).assumingMemoryBound(to: Float.self),
                     output: &output)
        } else {
            let matrix = UnsafeMutablePointer<Float>.allocate(capacity: rows * columns)
            defer { matrix.deallocate() }
            forRowGroups { start, length in
                browser_unpack_weights(weights + tensor.offset + start * rowBytes, tensor.type,
                                       length * columns, matrix + start * columns)
            }
            multiply(input, count: count, matrix: matrix, output: &output)
        }
        return output
    }

    private func multiply(_ input: [Float], count: Int, matrix: UnsafePointer<Float>, output: inout [Float]) {
        if count == 1 {
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(rows), Int32(columns), 1,
                        matrix, Int32(columns), input, 1, 0, &output, 1)
        } else {
            cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(count), Int32(rows), Int32(columns), 1,
                        input, Int32(columns), matrix, Int32(columns), 0, &output, Int32(rows))
        }
    }

    private func forRowGroups(_ work: (Int, Int) -> Void) {
        let groups = min(8, (rows + 127) / 128)
        let stride = (rows + groups - 1) / groups
        DispatchQueue.concurrentPerform(iterations: groups) { group in
            let start = group * stride
            work(start, min(stride, rows - start))
        }
    }
}

extension GGUFModel {
    func readQwenVector(_ name: String, count: Int) throws -> [Float] {
        guard let tensor = tensors[name] else { throw BrowserLLMError.missingTensor(name) }
        guard tensor.dimensions == [count], tensor.type == 0 || tensor.type == 1,
              tensor.offset <= data.count - count * (tensor.type == 0 ? 4 : 2) else {
            throw BrowserLLMError.unsupportedTensor(name)
        }
        var vector = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { bytes in
            browser_unpack_weights(bytes.bindMemory(to: UInt8.self).baseAddress! + tensor.offset,
                                   tensor.type, count, &vector)
        }
        return vector
    }
}
