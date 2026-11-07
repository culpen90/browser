import Foundation

/// Qwen2's NFC-normalized byte-level BPE, using the vocabulary and merge ranks in GGUF.
struct QwenTokenizer: Sendable {
    private struct Pair: Hashable, Sendable {
        let left: Int
        let right: Int

        init(_ left: Int, _ right: Int) {
            self.left = left
            self.right = right
        }
    }

    private struct Merge: Sendable {
        let rank: Int
        let token: Int
    }

    private let byteTokens: [Int]
    private let tokenBytes: [[UInt8]]
    private let merges: [Pair: Merge]
    private let chatStart: Int
    private let chatEnd: Int
    private let endOfText: Int
    let eosTokenID: Int
    let suppressedTokens: [Int]
    var vocabularySize: Int { tokenBytes.count }

    // Qwen2.5 uses individual digits and keeps punctuation, line breaks and leading
    // spaces in their own pieces. BPE never merges across these pre-token boundaries.
    private static let pieces = try! NSRegularExpression(
        pattern: #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
    )

    private static let byteAlphabet: [UnicodeScalar] = {
        let visible = Set(Array(33...126) + Array(161...172) + Array(174...255))
        var next = 256
        return (0..<256).map { byte in
            if visible.contains(byte) { return UnicodeScalar(byte)! }
            defer { next += 1 }
            return UnicodeScalar(next)!
        }
    }()

    init(model: GGUFModel) throws {
        let metadata = model.metadata
        guard metadata["tokenizer.ggml.model"]?.string == "gpt2",
              metadata["tokenizer.ggml.pre"]?.string == "qwen2",
              let vocabulary = metadata["tokenizer.ggml.tokens"]?.array,
              let types = metadata["tokenizer.ggml.token_type"]?.array,
              let mergeList = metadata["tokenizer.ggml.merges"]?.array,
              let eos = metadata["tokenizer.ggml.eos_token_id"]?.integer,
              types.count == vocabulary.count, vocabulary.indices.contains(eos) else {
            throw QwenTokenizerError("Missing or unsupported tokenizer metadata.")
        }

        let scalarToByte = Dictionary(uniqueKeysWithValues: Self.byteAlphabet.enumerated().map { ($1, UInt8($0)) })
        var ids: [String: Int] = [:]
        var decoded: [[UInt8]] = []
        ids.reserveCapacity(vocabulary.count)
        decoded.reserveCapacity(vocabulary.count)
        for (id, entry) in vocabulary.enumerated() {
            guard let spelling = entry.string, let type = types[id].integer,
                  ids.updateValue(id, forKey: spelling) == nil else {
                throw QwenTokenizerError("Invalid or duplicate vocabulary entry.")
            }
            switch type {
            case 1:
                var bytes: [UInt8] = []
                for scalar in spelling.unicodeScalars {
                    guard let byte = scalarToByte[scalar] else {
                        throw QwenTokenizerError("A vocabulary entry is outside the byte alphabet.")
                    }
                    bytes.append(byte)
                }
                decoded.append(bytes)
            case 4: decoded.append(Array(spelling.utf8)) // User-defined tokens, such as tool delimiters.
            default: decoded.append([]) // Control tokens and padding do not form visible text.
            }
        }
        guard let chatStart = ids["<|im_start|>"], let chatEnd = ids["<|im_end|>"],
              let endOfText = ids["<|endoftext|>"],
              [chatStart, chatEnd, endOfText, eos].allSatisfy({ types[$0].integer == 3 }) else {
            throw QwenTokenizerError("Missing Qwen chat control tokens.")
        }

        byteTokens = try Self.byteAlphabet.map { scalar in
            guard let token = ids[String(scalar)], types[token].integer == 1 else {
                throw QwenTokenizerError("A base byte token is missing.")
            }
            return token
        }

        var ranks: [Pair: Merge] = [:]
        ranks.reserveCapacity(mergeList.count)
        for (rank, value) in mergeList.enumerated() {
            guard let spelling = value.string, let separator = spelling.firstIndex(of: " ") else {
                throw QwenTokenizerError("Malformed BPE merge.")
            }
            let left = String(spelling[..<separator])
            let right = String(spelling[spelling.index(after: separator)...])
            guard let leftID = ids[left], let rightID = ids[right], let token = ids[left + right],
                  [leftID, rightID, token].allSatisfy({ types[$0].integer == 1 }),
                  ranks.updateValue(Merge(rank: rank, token: token), forKey: Pair(leftID, rightID)) == nil else {
                throw QwenTokenizerError("Invalid or duplicate BPE merge.")
            }
        }

        self.chatStart = chatStart
        self.chatEnd = chatEnd
        self.endOfText = endOfText
        eosTokenID = eos
        tokenBytes = decoded
        suppressedTokens = decoded.indices.filter {
            decoded[$0].isEmpty && $0 != eos && $0 != chatEnd && $0 != endOfText
        }
        merges = ranks
    }

    func chatPrompt(system: String, user: String) throws -> [Int] {
        // Inject only these trusted role delimiters. A delimiter spelled by the page
        // or the user stays ordinary text rather than becoming a chat control token.
        var result = [chatStart]
        result += try encode("system\n" + system)
        result += [chatEnd]
        result += try encode("\n")
        result += [chatStart]
        result += try encode("user\n" + user)
        result += [chatEnd]
        result += try encode("\n")
        result += [chatStart]
        result += try encode("assistant\n")
        return result
    }

    func encode(_ text: String) throws -> [Int] {
        let normalized = text.precomposedStringWithCanonicalMapping
        let utf16 = normalized as NSString
        let matches = Self.pieces.matches(in: normalized, range: NSRange(location: 0, length: utf16.length))
        var tokens: [Int] = []
        var position = 0
        for match in matches {
            try Task.checkCancellation()
            let range = match.range
            guard range.location == position else { throw QwenTokenizerError("Could not split text for encoding.") }
            position = NSMaxRange(range)
            // NSString ranges also allow splitting between scalars in one grapheme.
            let bytes = utf16.substring(with: range).utf8
            tokens += try encodePiece(bytes.map { byteTokens[Int($0)] })
        }
        guard position == utf16.length else { throw QwenTokenizerError("Could not finish encoding text.") }
        return tokens
    }

    func decode(_ tokens: [Int]) -> String {
        var bytes: [UInt8] = []
        for token in tokens where tokenBytes.indices.contains(token) {
            bytes += tokenBytes[token]
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func bytes(for token: Int) -> [UInt8] { tokenBytes[token] }

    func isEndToken(_ token: Int) -> Bool {
        token == eosTokenID || token == chatEnd || token == endOfText
    }

    private func encodePiece(_ initial: [Int]) throws -> [Int] {
        var tokens = initial
        while tokens.count > 1 {
            try Task.checkCancellation()
            var best: Merge?
            var pair: Pair?
            for index in 1..<tokens.count {
                let candidate = Pair(tokens[index - 1], tokens[index])
                if let merge = merges[candidate], merge.rank < (best?.rank ?? Int.max) {
                    best = merge
                    pair = candidate
                }
            }
            guard let pair, let best else { break }
            var joined: [Int] = []
            joined.reserveCapacity(tokens.count - 1)
            var index = 0
            while index < tokens.count {
                if index + 1 < tokens.count, tokens[index] == pair.left, tokens[index + 1] == pair.right {
                    joined.append(best.token)
                    index += 2
                } else {
                    joined.append(tokens[index])
                    index += 1
                }
            }
            tokens = joined
        }
        return tokens
    }
}

private struct QwenTokenizerError: LocalizedError {
    let reason: String

    init(_ reason: String) { self.reason = reason }

    var errorDescription: String? { "Invalid Qwen tokenizer. \(reason)" }
}
