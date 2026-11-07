import Accelerate
import Foundation

/// In-process inference for Qwen2-family GGUF instruction models.
public final class QwenModel: Sendable {
    private let weights: GGUFModel
    private let tokenizer: QwenTokenizer
    private let architecture: Architecture
    private let layers: [Layer]
    private let embeddings: QwenMatrix
    private let output: QwenMatrix
    private let finalNorm: [Float]

    public init(contentsOf url: URL) throws {
        let weights = try GGUFModel(url: url)
        let architecture = try Architecture(weights)
        let tokenizer = try QwenTokenizer(model: weights)
        guard let vocabulary = weights.tensors["token_embd.weight"]?.dimensions.last,
              (tokenizer.vocabularySize...200_000).contains(vocabulary) else {
            throw BrowserLLMError.unsupportedModel
        }
        let embeddings = try QwenMatrix("token_embd.weight", columns: architecture.width, rows: vocabulary, in: weights)
        self.embeddings = embeddings
        output = weights.tensors["output.weight"] == nil ? embeddings :
            try QwenMatrix("output.weight", columns: architecture.width, rows: vocabulary, in: weights)
        finalNorm = try weights.readQwenVector("output_norm.weight", count: architecture.width)
        layers = try (0..<architecture.layerCount).map { try Layer($0, architecture: architecture, weights: weights) }
        self.weights = weights
        self.architecture = architecture
        self.tokenizer = tokenizer
    }

    public func generate(system: String, user: String, maxNewTokens: Int = 128,
                         commandFormat: QwenCommandFormat? = nil) throws -> String {
        let prompt = try tokenizer.chatPrompt(system: system, user: user)
        let budget = min(max(maxNewTokens, 1), 256)
        guard prompt.count + budget <= architecture.context else { throw BrowserLLMError.contextTooLong }

        let rotary = RotaryEmbedding(width: architecture.headWidth, base: architecture.ropeBase,
                                     positions: prompt.count + budget)
        let cache = layers.map { _ in KVCache(capacity: prompt.count + budget, width: architecture.kvWidth) }
        var generated: [Int] = []
        var replyBytes: [UInt8] = []
        try weights.data.withUnsafeBytes { bytes in
            let pointer = bytes.bindMemory(to: UInt8.self).baseAddress!
            var logits = try forward(prompt, position: 0, rotary: rotary, cache: cache, weights: pointer)
            for index in 0..<budget {
                try Task.checkCancellation()
                let token: Int
                if let commandFormat {
                    guard let choice = commandFormat.select(logits: logits, after: replyBytes, tokenizer: tokenizer) else {
                        throw BrowserLLMError.emptyGeneration
                    }
                    token = choice
                } else {
                    for id in tokenizer.suppressedTokens { logits[id] = -.infinity }
                    var value = -Float.infinity
                    var best = 0
                    logits.withUnsafeBufferPointer { logits in
                        vDSP_maxvi(logits.baseAddress!, 1, &value, &best, vDSP_Length(tokenizer.vocabularySize))
                    }
                    guard value.isFinite else { throw BrowserLLMError.emptyGeneration }
                    token = best
                }
                if tokenizer.isEndToken(token) { break }
                generated.append(token)
                if let commandFormat {
                    replyBytes += tokenizer.bytes(for: token)
                    if commandFormat.isComplete(replyBytes) { break }
                }
                if index + 1 < budget {
                    logits = try forward([token], position: prompt.count + index, rotary: rotary,
                                         cache: cache, weights: pointer)
                }
            }
        }
        let text = if commandFormat != nil {
            String(decoding: replyBytes.prefix { $0 != 10 && $0 != 13 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            tokenizer.decode(generated).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { throw BrowserLLMError.emptyGeneration }
        return text
    }

    private func forward(_ tokens: [Int], position: Int, rotary: RotaryEmbedding, cache: [KVCache],
                         weights: UnsafePointer<UInt8>) throws -> [Float] {
        let shape = architecture
        let count = tokens.count
        var hidden = [Float](repeating: 0, count: count * shape.width)
        hidden.withUnsafeMutableBufferPointer { buffer in
            for (row, token) in tokens.enumerated() {
                embeddings.readRow(token, weights: weights, into: buffer.baseAddress! + row * shape.width)
            }
        }

        for (index, layer) in layers.enumerated() {
            try Task.checkCancellation()
            let normalized = rmsNormalize(hidden, using: layer.attentionNorm)
            var query = layer.query.apply(normalized, weights: weights)
            var key = layer.key.apply(normalized, weights: weights)
            var value = layer.value.apply(normalized, weights: weights)
            addBias(layer.queryBias, to: &query)
            addBias(layer.keyBias, to: &key)
            addBias(layer.valueBias, to: &value)
            rotary.apply(to: &query, heads: shape.heads, rows: count, position: position)
            rotary.apply(to: &key, heads: shape.kvHeads, rows: count, position: position)
            cache[index].store(key: key, value: value, position: position)
            let attention = attend(query: query, cache: cache[index], rows: count, position: position)
            add(layer.attentionOutput.apply(attention, weights: weights), to: &hidden)

            let ffnInput = rmsNormalize(hidden, using: layer.ffnNorm)
            var gate = layer.gate.apply(ffnInput, weights: weights)
            let up = layer.up.apply(ffnInput, weights: weights)
            for i in gate.indices {
                let x = gate[i]
                gate[i] = (x / (1 + exp(-x))) * up[i]
            }
            add(layer.down.apply(gate, weights: weights), to: &hidden)
        }

        try Task.checkCancellation()
        let normalized = rmsNormalize(Array(hidden.suffix(shape.width)), using: finalNorm)
        return output.apply(normalized, weights: weights)
    }

    private func rmsNormalize(_ input: [Float], using weight: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        let width = weight.count
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                for offset in stride(from: 0, to: input.count, by: width) {
                    let row = source.baseAddress! + offset
                    let result = destination.baseAddress! + offset
                    var meanSquare: Float = 0
                    vDSP_measqv(row, 1, &meanSquare, vDSP_Length(width))
                    var scale: Float = 1 / sqrt(meanSquare + architecture.epsilon)
                    vDSP_vsmul(row, 1, &scale, result, 1, vDSP_Length(width))
                    vDSP_vmul(result, 1, weight, 1, result, 1, vDSP_Length(width))
                }
            }
        }
        return output
    }

    private func addBias(_ bias: [Float], to values: inout [Float]) {
        let count = values.count
        values.withUnsafeMutableBufferPointer { buffer in
            for offset in stride(from: 0, to: count, by: bias.count) {
                vDSP_vadd(buffer.baseAddress! + offset, 1, bias, 1, buffer.baseAddress! + offset, 1,
                          vDSP_Length(bias.count))
            }
        }
    }

    private func add(_ source: [Float], to destination: inout [Float]) {
        destination.withUnsafeMutableBufferPointer { buffer in
            vDSP_vadd(buffer.baseAddress!, 1, source, 1, buffer.baseAddress!, 1, vDSP_Length(source.count))
        }
    }

    private func attend(query: [Float], cache: KVCache, rows: Int, position: Int) -> [Float] {
        let shape = architecture
        let length = position + rows
        let width = shape.headWidth
        let group = shape.heads / shape.kvHeads
        let scale = 1 / sqrt(Float(width))
        var scores = [Float](repeating: 0, count: rows * length)
        var result = [Float](repeating: 0, count: rows * shape.width)
        query.withUnsafeBufferPointer { query in
            result.withUnsafeMutableBufferPointer { result in
                for head in 0..<shape.heads {
                    let qOffset = head * width
                    let kvOffset = head / group * width
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                Int32(rows), Int32(length), Int32(width), scale,
                                query.baseAddress! + qOffset, Int32(shape.width),
                                cache.key + kvOffset, Int32(shape.kvWidth), 0, &scores, Int32(length))
                    causalSoftmax(&scores, rows: rows, position: position, length: length)
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                                Int32(rows), Int32(width), Int32(length), 1, scores, Int32(length),
                                cache.value + kvOffset, Int32(shape.kvWidth), 0,
                                result.baseAddress! + qOffset, Int32(shape.width))
                }
            }
        }
        return result
    }

    private func causalSoftmax(_ scores: inout [Float], rows: Int, position: Int, length: Int) {
        scores.withUnsafeMutableBufferPointer { buffer in
            for row in 0..<rows {
                let start = buffer.baseAddress! + row * length
                let used = position + row + 1
                let size = vDSP_Length(used)
                var maximum: Float = 0
                vDSP_maxv(start, 1, &maximum, size)
                var negativeMaximum = -maximum
                vDSP_vsadd(start, 1, &negativeMaximum, start, 1, size)
                var expCount = Int32(used)
                vvexpf(start, start, &expCount)
                var sum: Float = 0
                vDSP_sve(start, 1, &sum, size)
                var inverse: Float = 1 / sum
                vDSP_vsmul(start, 1, &inverse, start, 1, size)
                (start + used).update(repeating: 0, count: length - used)
            }
        }
    }
}

private struct Architecture {
    let width: Int
    let heads: Int
    let kvHeads: Int
    let layerCount: Int
    let intermediate: Int
    let context: Int
    let epsilon: Float
    let ropeBase: Float
    var headWidth: Int { width / heads }
    var kvWidth: Int { headWidth * kvHeads }

    init(_ model: GGUFModel) throws {
        let fields = model.metadata
        guard fields["general.architecture"]?.string == "qwen2",
              let width = fields["qwen2.embedding_length"]?.integer, (1...4096).contains(width),
              let heads = fields["qwen2.attention.head_count"]?.integer, (1...64).contains(heads),
              let kvHeads = fields["qwen2.attention.head_count_kv"]?.integer, (1...heads).contains(kvHeads),
              heads.isMultiple(of: kvHeads), width.isMultiple(of: 2 * heads),
              let layers = fields["qwen2.block_count"]?.integer, (1...48).contains(layers),
              let intermediate = fields["qwen2.feed_forward_length"]?.integer, (1...16_384).contains(intermediate),
              let context = fields["qwen2.context_length"]?.integer, context >= 256,
              let epsilon = fields["qwen2.attention.layer_norm_rms_epsilon"]?.number,
              epsilon.isFinite, epsilon > 0, epsilon < 1,
              let ropeBase = fields["qwen2.rope.freq_base"]?.number,
              ropeBase.isFinite, ropeBase >= 1, ropeBase <= 1e9 else {
            throw BrowserLLMError.unsupportedModel
        }
        self.width = width
        self.heads = heads
        self.kvHeads = kvHeads
        layerCount = layers
        self.intermediate = intermediate
        self.context = min(context, 2_048)
        self.epsilon = Float(epsilon)
        self.ropeBase = Float(ropeBase)
    }
}

private struct Layer {
    let attentionNorm: [Float]
    let query: QwenMatrix
    let key: QwenMatrix
    let value: QwenMatrix
    let queryBias: [Float]
    let keyBias: [Float]
    let valueBias: [Float]
    let attentionOutput: QwenMatrix
    let ffnNorm: [Float]
    let gate: QwenMatrix
    let up: QwenMatrix
    let down: QwenMatrix

    init(_ index: Int, architecture: Architecture, weights: GGUFModel) throws {
        let prefix = "blk.\(index)."
        let width = architecture.width
        let kv = architecture.kvWidth
        let ffn = architecture.intermediate
        attentionNorm = try weights.readQwenVector(prefix + "attn_norm.weight", count: width)
        query = try QwenMatrix(prefix + "attn_q.weight", columns: width, rows: width, in: weights)
        key = try QwenMatrix(prefix + "attn_k.weight", columns: width, rows: kv, in: weights)
        value = try QwenMatrix(prefix + "attn_v.weight", columns: width, rows: kv, in: weights)
        queryBias = try weights.readQwenVector(prefix + "attn_q.bias", count: width)
        keyBias = try weights.readQwenVector(prefix + "attn_k.bias", count: kv)
        valueBias = try weights.readQwenVector(prefix + "attn_v.bias", count: kv)
        attentionOutput = try QwenMatrix(prefix + "attn_output.weight", columns: width, rows: width, in: weights)
        ffnNorm = try weights.readQwenVector(prefix + "ffn_norm.weight", count: width)
        gate = try QwenMatrix(prefix + "ffn_gate.weight", columns: width, rows: ffn, in: weights)
        up = try QwenMatrix(prefix + "ffn_up.weight", columns: width, rows: ffn, in: weights)
        down = try QwenMatrix(prefix + "ffn_down.weight", columns: ffn, rows: width, in: weights)
    }
}

private struct RotaryEmbedding {
    let half: Int
    let cosine: [Float]
    let sine: [Float]

    init(width: Int, base: Float, positions: Int) {
        let half = width / 2
        let frequencies = (0..<half).map { pow(base, -Float($0) / Float(half)) }
        var cosine: [Float] = []
        var sine: [Float] = []
        cosine.reserveCapacity(half * positions)
        sine.reserveCapacity(half * positions)
        for position in 0..<positions {
            for frequency in frequencies {
                let angle = Float(position) * frequency
                cosine.append(cos(angle))
                sine.append(sin(angle))
            }
        }
        self.half = half
        self.cosine = cosine
        self.sine = sine
    }

    func apply(to values: inout [Float], heads: Int, rows: Int, position: Int) {
        for row in 0..<rows {
            let rotation = (position + row) * half
            for head in 0..<heads {
                let offset = (row * heads + head) * half * 2
                for index in 0..<half {
                    let x = values[offset + index]
                    let y = values[offset + index + half]
                    let c = cosine[rotation + index]
                    let s = sine[rotation + index]
                    values[offset + index] = x * c - y * s
                    values[offset + index + half] = x * s + y * c
                }
            }
        }
    }
}

private final class KVCache {
    let key: UnsafeMutablePointer<Float>
    let value: UnsafeMutablePointer<Float>
    private let width: Int

    init(capacity: Int, width: Int) {
        self.width = width
        key = .allocate(capacity: capacity * width)
        value = .allocate(capacity: capacity * width)
    }

    deinit {
        key.deallocate()
        value.deallocate()
    }

    func store(key: [Float], value: [Float], position: Int) {
        (self.key + position * width).initialize(from: key, count: key.count)
        (self.value + position * width).initialize(from: value, count: value.count)
    }
}
