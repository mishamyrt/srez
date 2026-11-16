import Foundation

public enum GigaAMError: Error, LocalizedError, Sendable {
    case fileNotFound(String)
    case modelDirectoryNotFound(String)
    case manifestNotFound(String)
    case weightsNotFound(String)
    case tokenizerNotFound(String)
    case invalidManifest(String)
    case invalidArguments(String)
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case let .fileNotFound(path):
            return "File not found: \(path)"
        case let .modelDirectoryNotFound(path):
            return "Model directory not found: \(path)"
        case let .manifestNotFound(path):
            return "Model manifest not found: \(path)"
        case let .weightsNotFound(path):
            return "Model weights not found: \(path)"
        case let .tokenizerNotFound(path):
            return "Tokenizer not found: \(path)"
        case let .invalidManifest(message):
            return "Invalid manifest: \(message)"
        case let .invalidArguments(message):
            return "Invalid arguments: \(message)"
        case let .notImplemented(message):
            return "Not implemented yet: \(message)"
        }
    }
}
