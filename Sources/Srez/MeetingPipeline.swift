import Foundation
import GigaAMKit
import Darwin

struct MeetingOutput: Sendable {
    let transcript: URL
    var summary: URL?
    var file: URL { summary ?? transcript }
}

enum MeetingEvent: Sendable {
    case stage(String)
    case progress(Double)
    case transcript(String)
}

struct MeetingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum MeetingPipeline {
    static func run(
        input: URL, settings: MeetingSettings, transcript: String? = nil, modelStore: ModelStore = ModelStore(),
        update: @escaping @Sendable (MeetingEvent) async -> Void
    ) async throws -> MeetingOutput {
        let fm = FileManager.default
        try prepareOutputDirectory(settings.outputDirectory)
        let work = fm.temporaryDirectory.appendingPathComponent("GigaAM-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }

        let text: String
        if let transcript {
            text = transcript
        } else {
            guard fm.isExecutableFile(atPath: settings.ffmpeg.path) else {
                throw MeetingError(message: "Не найден встроенный ffmpeg. Пересоберите или переустановите Srez.")
            }
            await update(.stage("Преобразование в WAV…"))
            let wav = work.appendingPathComponent("audio.wav")
            try await runProcess(settings.ffmpeg, arguments: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", input.path,
                "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav.path
            ], directory: work)
            let recognizer = try await modelStore.load(update: update)
            await update(.stage("Распознавание речи…"))
            text = try await recognizer.transcribe(url: wav) { value in
                await update(.progress(value))
            }.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingError(message: "Речь не распознана. Проверьте, что в файле есть русская речь.")
            }
            await update(.transcript(text))
        }

        try Task.checkCancellation()
        await update(.stage("Сохранение расшифровки…"))
        let file = try saveFile(text, title: input.deletingPathExtension().lastPathComponent,
                                extension: "raw.txt", directory: settings.outputDirectory)
        return MeetingOutput(transcript: file)
    }

    static func combineTranscripts(_ outputs: [MeetingOutput], directory: URL) throws -> MeetingOutput {
        let texts = try outputs.map { output in
            try Task.checkCancellation()
            let text = try String(contentsOf: output.transcript, encoding: .utf8)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingError(message: "Расшифровка «\(output.transcript.lastPathComponent)» пуста. Нет текста для суммаризации.")
            }
            return text
        }
        try Task.checkCancellation()
        try prepareOutputDirectory(directory)
        let file = try saveFile(texts.joined(separator: "\n\n"),
                                title: "Общая расшифровка (\(outputs.count))",
                                extension: "raw.txt", directory: directory)
        return MeetingOutput(transcript: file)
    }

    static func summarize(
        _ output: MeetingOutput, settings: MeetingSettings,
        update: @escaping @Sendable (MeetingEvent) async -> Void
    ) async throws -> MeetingOutput {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: settings.codex.path) else {
            throw MeetingError(message: "Не найден Codex CLI. Укажите путь к codex в настройках.")
        }
        try prepareOutputDirectory(settings.outputDirectory)
        let work = fm.temporaryDirectory.appendingPathComponent("GigaAM-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        try Task.checkCancellation()
        let text = try String(contentsOf: output.transcript, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingError(message: "Расшифровка пуста. Нет текста для суммаризации.")
        }
        let parts = splitTranscript(text)
        let sourceGroups = parts.enumerated().map { part, text in
            splitTranscript(text, limit: 1_200).enumerated().map { index, fragment in
                TranscriptSource(id: "p\(part + 1)s\(index + 1)", text: fragment)
            }
        }
        let sources = sourceGroups.flatMap { $0 }
        let encoder = JSONEncoder()
        var notes: [MeetingNotes] = []
        if parts.count > 1 {
            for (index, group) in sourceGroups.enumerated() {
                try Task.checkCancellation()
                await update(.stage("Извлечение фактов: часть \(index + 1) из \(parts.count)…"))
                // Carry the preceding fragment so questions and commitments can cross a part boundary.
                let context = index > 0 ? Array(sourceGroups[index - 1].suffix(1)) : []
                let input = context + group
                let data = String(decoding: try encoder.encode(input), as: UTF8.self)
                let extracted: MeetingNotes = try await requestSummary(
                    data, settings: settings, directory: work, partial: true
                )
                try extracted.validate(sources: input)
                notes.append(extracted)
            }
        }
        await update(.stage("Определение типа и сборка протокола…"))
        let data = try notes.isEmpty ? encoder.encode(sources) : encoder.encode(notes)
        let summary: MeetingSummary = try await requestSummary(
            String(decoding: data, as: UTF8.self), settings: settings, directory: work, merging: !notes.isEmpty
        )
        try summary.validate(sources: sources)
        if !notes.isEmpty, !summary.sourceIDs.isSubset(of: notes.reduce(into: Set<String>()) { $0.formUnion($1.sourceIDs) }) {
            throw MeetingError(message: "Codex сослался на источник вне извлечённых фактов. Повторите суммаризацию.")
        }
        try Task.checkCancellation()
        await update(.stage("Сохранение…"))
        return try save(summary, transcript: output.transcript, directory: settings.outputDirectory)
    }

    // Bound each Codex input for two-hour recordings; split at paragraph/word boundaries.
    static func splitTranscript(_ text: String, limit: Int = 24_000) -> [String] {
        precondition(limit > 0)
        var remaining = text[...]
        var parts: [String] = []
        while let boundary = remaining.index(remaining.startIndex, offsetBy: limit, limitedBy: remaining.endIndex),
              boundary < remaining.endIndex {
            let midpoint = remaining.index(remaining.startIndex, offsetBy: max(1, limit / 2))
            let split = remaining[midpoint..<boundary].lastIndex(where: { $0.isWhitespace }) ?? boundary
            parts.append(String(remaining[..<split]))
            remaining = remaining[split...]
        }
        if !remaining.isEmpty { parts.append(String(remaining)) }
        return parts
    }

    private static func requestSummary<Result: Decodable>(
        _ data: String, settings: MeetingSettings, directory: URL, partial: Bool = false, merging: Bool = false
    ) async throws -> Result {
        let schema = directory.appendingPathComponent("schema.json")
        try MeetingSummaryFormat.schema(partial: partial).write(to: schema)
        let prompt = directory.appendingPathComponent("prompt.txt")
        let result = directory.appendingPathComponent("summary.json")
        try? FileManager.default.removeItem(at: result)
        let instruction = MeetingSummaryFormat.prompt(data: data, partial: partial, merging: merging)
        try Data(instruction.utf8).write(to: prompt)
        var arguments = [
            "exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config",
            "--disable", "shell_tool", "--disable", "unified_exec", "--disable", "apps",
            "--disable", "plugins", "-c", "web_search=\"disabled\"",
            "--sandbox", "read-only", "--color", "never",
            "--output-schema", schema.path, "--output-last-message", result.path
        ]
        if !settings.codexModel.isEmpty { arguments += ["--model", settings.codexModel] }
        arguments += ["--config", "model_reasoning_effort=\"\(settings.codexReasoning)\""]
        arguments.append("-")
        try await runProcess(settings.codex, arguments: arguments, directory: directory, stdin: prompt)
        do {
            return try JSONDecoder().decode(Result.self, from: Data(contentsOf: result))
        } catch {
            throw MeetingError(message: "Codex не вернул корректное резюме. Расшифровка доступна для повторной попытки.")
        }
    }

    static func fileStem(_ title: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var name = title.components(separatedBy: forbidden).joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.lowercased().hasSuffix(".md") { name.removeLast(3) }
        while name.utf8.count > 180 { name.removeLast() }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return name.isEmpty ? "Встреча" : name
    }

    static func save(
        _ summary: MeetingSummary, transcript: URL, directory: URL
    ) throws -> MeetingOutput {
        let file = try saveFile(summary.markdown + "\n", title: summary.title, extension: "md", directory: directory)
        return MeetingOutput(transcript: transcript, summary: file)
    }

    private static func prepareOutputDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard fm.isWritableFile(atPath: directory.path) else {
            throw MeetingError(message: "Нет доступа на запись в папку результатов.")
        }
    }

    private static func saveFile(_ text: String, title: String, extension suffix: String, directory: URL) throws -> URL {
        let fm = FileManager.default
        let stem = fileStem(title)
        var index = 1
        while true {
            let name = stem + (index == 1 ? "" : " (\(index))")
            let file = directory.appendingPathComponent(name + "." + suffix)
            if fm.fileExists(atPath: file.path) {
                index += 1
                continue
            }
            // Exclusive creation also prevents overwriting a file created after the check above.
            try Data(text.utf8).write(to: file, options: .withoutOverwriting)
            return file
        }
    }

    static func runProcess(
        _ executable: URL, arguments: [String], directory: URL, stdin: URL? = nil
    ) async throws {
        try Task.checkCancellation()
        let log = directory.appendingPathComponent("process-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil,
                                      attributes: [.posixPermissions: 0o600])
        let stderr = try FileHandle(forWritingTo: log)
        let input = try stdin.map { try FileHandle(forReadingFrom: $0) }
        defer {
            try? stderr.close()
            try? input?.close()
            try? FileManager.default.removeItem(at: log)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin",
                               "/usr/local/bin", "/usr/bin", "/bin", environment["PATH"] ?? ""]
            .joined(separator: ":")
        process.environment = environment
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        do {
            while process.isRunning { try await Task.sleep(for: .milliseconds(100)) }
            try Task.checkCancellation()
        } catch {
            if process.isRunning {
                process.terminate()
                // Reap before allowing the next queued job to start, even if SIGTERM is ignored.
                await Task.detached {
                    for _ in 0..<20 {
                        if !process.isRunning { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                }.value
            }
            throw error
        }
        guard process.terminationStatus == 0 else {
            let handle = try FileHandle(forReadingFrom: log)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            try handle.seek(toOffset: length > 6000 ? length - 6000 : 0)
            let details = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
            throw MeetingError(message: "\(executable.lastPathComponent) завершился с кодом \(process.terminationStatus).\n\(details)")
        }
    }
}
