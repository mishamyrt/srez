import Foundation

struct MeetingSettings: Sendable {
    static let codexModels = ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]
    static let reasoningLevels = ["low", "medium", "high"]

    let outputDirectory: URL
    let modelDirectory: URL
    let ffmpeg: URL
    let codex: URL
    let codexModel: String
    let codexReasoning: String
    let saveRaw: Bool

    static func registerDefaults() {
        let bundled = Bundle.main.url(forResource: "Defaults", withExtension: "plist")
            .flatMap { NSDictionary(contentsOf: $0) as? [String: String] }
        UserDefaults.standard.register(defaults: [
            "outputDirectory": FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Встречи").path,
            "modelDirectory": bundled?["modelDirectory"] ?? "",
            "ffmpegPath": executablePath("ffmpeg"),
            "codexPath": executablePath("codex"),
            "codexModel": "gpt-6-sol",
            "codexReasoning": "medium",
            "saveRaw": true
        ])
        if !codexModels.contains(UserDefaults.standard.string(forKey: "codexModel") ?? "") {
            UserDefaults.standard.set("gpt-6-sol", forKey: "codexModel")
        }
        if !reasoningLevels.contains(UserDefaults.standard.string(forKey: "codexReasoning") ?? "") {
            UserDefaults.standard.set("medium", forKey: "codexReasoning")
        }
    }

    static func current() throws -> Self {
        let defaults = UserDefaults.standard
        for key in ["outputDirectory", "modelDirectory", "ffmpegPath", "codexPath"] {
            guard let path = defaults.string(forKey: key),
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingError(message: "Заполните пути к папке результатов, модели, ffmpeg и Codex в настройках.")
            }
        }
        func url(_ key: String) -> URL {
            URL(fileURLWithPath: (defaults.string(forKey: key) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).expandingTilde)
        }
        return Self(
            outputDirectory: url("outputDirectory"), modelDirectory: url("modelDirectory"),
            ffmpeg: url("ffmpegPath"), codex: url("codexPath"),
            codexModel: (defaults.string(forKey: "codexModel") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            codexReasoning: defaults.string(forKey: "codexReasoning") ?? "medium",
            saveRaw: defaults.bool(forKey: "saveRaw")
        )
    }

    private static func executablePath(_ name: String) -> String {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "~/.npm-global/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        return paths.map { $0.expandingTilde + "/" + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/\(name)"
    }
}

private extension String {
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}
