import Foundation

struct CodexProvider: SummaryProvider {
    let configuration: CodexConfiguration

    static let models = [
        "gpt-6.1-sol",
        "gpt-6.1-terra",
        "gpt-6-astra",
        "gpt-6-sol",
        "gpt-6-luna",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "gpt-5.5",
    ]
    static let reasoningLevels = ["low", "medium", "high"]

    static func isAvailable(at path: String) -> Bool {
        let path = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
            .expandingTildeInPath
        guard !path.isEmpty else { return false }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && fm.isExecutableFile(atPath: path)
    }

    func generate(_ request: SummaryRequest) async throws -> Data {
        try Task.checkCancellation()
        let fm = FileManager.default
        guard Self.isAvailable(at: configuration.executable.path) else {
            throw MeetingError(
                message: "Не найден Codex CLI. Укажите путь к codex в настройках."
            )
        }
        let work = fm.temporaryDirectory.appendingPathComponent("Srez-Codex-\(UUID())")
        try fm.createDirectory(
            at: work,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fm.removeItem(at: work) }
        let schema = work.appendingPathComponent("schema.json")
        let prompt = work.appendingPathComponent("prompt.txt")
        let result = work.appendingPathComponent("summary.json")
        try request.outputSchema.write(to: schema)
        try Data(request.prompt.utf8).write(to: prompt)
        var arguments = [
            "exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config",
            "--disable", "shell_tool", "--disable", "unified_exec", "--disable", "apps",
            "--disable", "plugins", "-c", "web_search=\"disabled\"",
            "--sandbox", "read-only", "--color", "never",
            "--output-schema", schema.path, "--output-last-message", result.path,
        ]
        if !configuration.model.isEmpty {
            arguments += ["--model", configuration.model]
        }
        arguments += ["--config", "model_reasoning_effort=\"\(configuration.reasoning)\""]
        arguments.append("-")
        try await ProcessRunner.run(
            configuration.executable,
            arguments: arguments,
            directory: work,
            stdin: prompt
        )
        try Task.checkCancellation()
        do { return try Data(contentsOf: result) }
        catch {
            throw MeetingError(
                message: "Codex не вернул результат. Расшифровка доступна для повторной попытки."
            )
        }
    }
}
