import Foundation

enum SummaryProviderFactory {
    static func make(_ configuration: ProviderConfiguration) -> any SummaryProvider {
        switch configuration {
        case let .codex(configuration): CodexProvider(configuration: configuration)
        }
    }

    static func isAvailable(_ configuration: ProviderConfiguration) -> Bool {
        switch configuration {
        case let .codex(configuration): CodexProvider
            .isAvailable(at: configuration.executable.path)
        }
    }

    static func validate(_ configuration: ProviderConfiguration) throws {
        guard isAvailable(configuration) else {
            throw MeetingError(
                message: "Не найден провайдер суммаризации. Проверьте настройки."
            )
        }
    }

    static func name(for configuration: ProviderConfiguration) -> String {
        switch configuration { case .codex: "Codex" }
    }

    static func models(for configuration: ProviderConfiguration) -> [String] {
        switch configuration { case .codex: CodexProvider.models }
    }

    static func reasoningLevels(for configuration: ProviderConfiguration) -> [String] {
        switch configuration { case .codex: CodexProvider.reasoningLevels }
    }
}
