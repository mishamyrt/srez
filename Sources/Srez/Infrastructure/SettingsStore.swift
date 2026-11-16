import Combine
import Foundation

@MainActor
final class SettingsStore {
    private let changesSubject = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> {
        changesSubject.eraseToAnyPublisher()
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(_ key: String) -> String {
        defaults.string(forKey: key) ?? ""
    }

    func set(_ value: String, for key: String) {
        guard defaults.string(forKey: key) != value else { return }
        defaults.set(value, forKey: key)
        changesSubject.send()
    }

    func refresh() {
        changesSubject.send()
    }

    var provider: ProviderConfiguration {
        .codex(.init(
            executable: url("codexPath"),
            model: string("codexModel").trimmingCharacters(in: .whitespacesAndNewlines),
            reasoning: string("codexReasoning")
                .isEmpty ? "medium" : string("codexReasoning")
        ))
    }

    func current(
        summarizing: Bool = false,
        bundle: Bundle = .main
    ) throws -> MeetingSettings {
        guard !string("outputDirectory").trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        else {
            throw MeetingError(message: "Укажите папку результатов в настройках.")
        }
        if summarizing {
            try SummaryProviderFactory.validate(provider)
        }
        return MeetingSettings(
            outputDirectory: url("outputDirectory"),
            ffmpeg: bundle.bundleURL.pathExtension == "app"
                ? bundle.bundleURL
                .appendingPathComponent("Contents/MacOS/ffmpeg") :
                url("ffmpegPath"),
            provider: provider
        )
    }

    private func url(_ key: String) -> URL {
        URL(fileURLWithPath: string(key).trimmingCharacters(in: .whitespacesAndNewlines)
            .expandingTilde)
    }

    func registerDefaults() {
        defaults.register(defaults: [
            "outputDirectory": FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Встречи").path,
            "ffmpegPath": executablePath("ffmpeg"),
            "codexPath": executablePath("codex"),
            "codexModel": "gpt-6-luna",
            "codexReasoning": "medium",
        ])
        if !CodexProvider.models
            .contains(defaults.string(forKey: "codexModel") ?? "")
        {
            defaults.set("gpt-6-luna", forKey: "codexModel")
        }
        if !CodexProvider.reasoningLevels
            .contains(defaults.string(forKey: "codexReasoning") ?? "")
        {
            defaults.set("medium", forKey: "codexReasoning")
        }
    }

    private func executablePath(_ name: String) -> String {
        let paths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "~/.local/bin",
            "~/.npm-global/bin",
        ]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .components(separatedBy: ":")
        return paths.map { $0.expandingTilde + "/" + name }
            .first { FileManager.default.isExecutableFile(
                atPath: $0
            ) } ?? "/opt/homebrew/bin/\(name)"
    }
}

extension String {
    fileprivate var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
