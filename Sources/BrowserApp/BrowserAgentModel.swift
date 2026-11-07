import BrowserLLM
import CryptoKit
import Foundation

actor BrowserAgentModel {
    static let shared = BrowserAgentModel()
    static let defaultURL = URL.applicationSupportDirectory
        .appending(path: "Browser/Models/qwen2.5-0.5b-instruct-q4_0.gguf")
    private static let downloadURL = URL(string:
        "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/9217f5db79a29953eb74d5343926648285ec7e67/qwen2.5-0.5b-instruct-q4_0.gguf")!
    private static let expectedDigest = "7671c0c304e6ce5a7fc577bcb12aba01e2c155cc2efd29b2213c95b18edaf6ed"

    private var loaded: (url: URL, model: QwenModel)?

    func generate(at url: URL, system: String, user: String, maxTokens: Int,
                  commandFormat: QwenCommandFormat?) async throws -> String {
        try Task.checkCancellation()
        if let loaded, loaded.url == url {
            return try loaded.model.generate(system: system, user: user, maxNewTokens: maxTokens, commandFormat: commandFormat)
        }
        loaded = nil
        guard FileManager.default.fileExists(atPath: url.path) else { throw ModelError.missing }
        let model = try QwenModel(contentsOf: url)
        loaded = (url, model)
        return try model.generate(system: system, user: user, maxNewTokens: maxTokens, commandFormat: commandFormat)
    }

    static func downloadDefault() async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: downloadURL)
        let files = FileManager.default
        defer { try? files.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize == 428_730_208 else {
            throw ModelError.incompleteDownload
        }

        let file = try FileHandle(forReadingFrom: temporary)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedDigest else { throw ModelError.incompleteDownload }
        try Task.checkCancellation()

        try files.createDirectory(at: defaultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try files.moveItem(at: temporary, to: defaultURL)
        } catch CocoaError.fileWriteFileExists {
            _ = try files.replaceItemAt(defaultURL, withItemAt: temporary)
        }
        return defaultURL
    }

    enum ModelError: LocalizedError {
        case missing
        case incompleteDownload

        var errorDescription: String? {
            switch self {
            case .missing: return "The model file could not be found. Download the default model or choose a local GGUF file."
            case .incompleteDownload: return "The Hugging Face download did not match the expected model file. Try downloading it again."
            }
        }
    }
}
