import Foundation

struct MeetingSettings: Sendable {
    static let codexModels = ["gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"]
    static let reasoningLevels = ["low", "medium", "high"]

    let outputDirectory: URL
    let ffmpeg: URL
    let codex: URL
    let codexModel: String
    let codexReasoning: String

    static func isCodexAvailable(at path: String) -> Bool {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines).expandingTilde
        guard !path.isEmpty else { return false }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && fm.isExecutableFile(atPath: path)
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "outputDirectory": FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/Встречи").path,
            "ffmpegPath": executablePath("ffmpeg"),
            "codexPath": executablePath("codex"),
            "codexModel": "gpt-6-luna",
            "codexReasoning": "medium"
        ])
        if !codexModels.contains(UserDefaults.standard.string(forKey: "codexModel") ?? "") {
            UserDefaults.standard.set("gpt-6-luna", forKey: "codexModel")
        }
        if !reasoningLevels.contains(UserDefaults.standard.string(forKey: "codexReasoning") ?? "") {
            UserDefaults.standard.set("medium", forKey: "codexReasoning")
        }
    }

    static func current(summarizing: Bool = false, bundle: Bundle = .main) throws -> Self {
        let defaults = UserDefaults.standard
        for key in (summarizing ? ["outputDirectory", "codexPath"] : ["outputDirectory"]) {
            guard let path = defaults.string(forKey: key),
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingError(message: key == "outputDirectory"
                                   ? "Укажите папку результатов в настройках."
                                   : "Укажите путь к Codex CLI в настройках.")
            }
        }
        func url(_ key: String) -> URL {
            URL(fileURLWithPath: (defaults.string(forKey: key) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).expandingTilde)
        }
        return Self(
            outputDirectory: url("outputDirectory"),
            ffmpeg: bundle.bundleURL.pathExtension == "app"
                ? bundle.bundleURL.appendingPathComponent("Contents/MacOS/ffmpeg")
                : url("ffmpegPath"),
            codex: url("codexPath"),
            codexModel: (defaults.string(forKey: "codexModel") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            codexReasoning: defaults.string(forKey: "codexReasoning") ?? "medium"
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
