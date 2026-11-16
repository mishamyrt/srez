import Foundation

struct CodexConfiguration: Sendable {
    let executable: URL
    let model: String
    let reasoning: String
}

enum ProviderConfiguration: Sendable {
    case codex(CodexConfiguration)
}

enum SummaryProviderFactory {
    static func make(_ configuration: ProviderConfiguration) -> any SummaryProvider {
        switch configuration {
        case let .codex(configuration): CodexProvider(configuration: configuration)
        }
    }
}
