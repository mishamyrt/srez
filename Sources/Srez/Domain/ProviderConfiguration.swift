import Foundation

struct CodexConfiguration: Sendable {
    let executable: URL
    let model: String
    let reasoning: String
}

enum ProviderConfiguration: Sendable {
    case codex(CodexConfiguration)
}
