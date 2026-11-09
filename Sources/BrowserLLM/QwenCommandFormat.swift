/// Constrains a reply to one browser command and optional single-line text.
public struct QwenCommandFormat: Sendable {
    private let exact: [[UInt8]]
    private let withText: [[UInt8]]

    public var exactCommands: [String] { exact.map { String(decoding: $0, as: UTF8.self) } }
    public var withTextCommands: [String] {
        withText.map { String(decoding: $0.dropLast(), as: UTF8.self) }
    }

    public init(exact: [String], withText: [String]) {
        self.exact = exact.map { Array($0.utf8) }
        self.withText = withText.map { Array(($0 + " ").utf8) }
    }

    func select(logits: [Float], after reply: [UInt8], tokenizer: QwenTokenizer) -> Int? {
        let exactSuffixes = exact.compactMap { $0.starts(with: reply) ? $0.dropFirst(reply.count) : nil }
        let textSuffixes = withText.compactMap { $0.starts(with: reply) ? $0.dropFirst(reply.count) : nil }
        let complete = exactSuffixes.contains(where: \.isEmpty)
        let textMode = withText.contains { reply.count > $0.count && reply.starts(with: $0) }
        let canEnd = complete || textMode

        var best: Int?
        var bestValue = -Float.infinity
        for id in 0..<tokenizer.vocabularySize where logits[id] > bestValue {
            let bytes = tokenizer.bytes(for: id)
            if tokenizer.isEndToken(id) {
                guard canEnd else { continue }
            } else {
                guard !bytes.isEmpty else { continue }
                if !textMode {
                    let line = bytes.prefix { $0 != 10 && $0 != 13 }
                    let endsLine = line.count != bytes.count
                    let matchesExact = exactSuffixes.contains { suffix in
                        endsLine ? line.elementsEqual(suffix) : suffix.starts(with: line)
                    }
                    let matchesText = textSuffixes.contains { suffix in
                        if line.count <= suffix.count { return !endsLine && suffix.starts(with: line) }
                        return line.starts(with: suffix) && line.dropFirst(suffix.count).contains { $0 > 32 }
                    }
                    guard matchesExact || matchesText else { continue }
                }
            }
            best = id
            bestValue = logits[id]
        }
        return bestValue.isFinite ? best : nil
    }

    func isComplete(_ reply: [UInt8]) -> Bool {
        if reply.contains(10) || reply.contains(13) { return true }
        return exact.contains(reply) &&
            !exact.contains { $0.count > reply.count && $0.starts(with: reply) } &&
            !withText.contains { $0.starts(with: reply) }
    }
}
