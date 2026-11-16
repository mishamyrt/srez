import Foundation
import GigaAM

enum MeetingPipeline {
    static let summaryPromptLimit = 96 * 1024
    private static let summarySizeError = MeetingError(
        message: "Не удалось уместить факты в лимит запроса. Разбейте запись или выберите меньше встреч."
    )

    static func run(
        input: URL, settings: MeetingSettings, transcript: String? = nil,
        modelStore: ModelStore = ModelStore(),
        update: @escaping @Sendable (MeetingEvent) async -> Void
    ) async throws -> MeetingOutput {
        let fm = FileManager.default
        try MeetingFileStore.prepareOutputDirectory(settings.outputDirectory)
        let work = fm.temporaryDirectory
            .appendingPathComponent("GigaAM-\(UUID().uuidString)")
        try fm.createDirectory(
            at: work,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fm.removeItem(at: work) }

        let text: String
        if let transcript {
            text = transcript
        } else {
            guard fm.isExecutableFile(atPath: settings.ffmpeg.path) else {
                throw MeetingError(
                    message: "Не найден встроенный ffmpeg. Пересоберите или переустановите Srez."
                )
            }
            await update(.stage("Преобразование в WAV…"))
            let wav = work.appendingPathComponent("audio.wav")
            try await ProcessRunner.run(settings.ffmpeg, arguments: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", input.path,
                "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
                wav.path,
            ], directory: work)
            let recognizer = try await modelStore.load(update: update)
            await update(.stage("Распознавание речи…"))
            text = try await recognizer.transcribe(url: wav) { value in
                await update(.progress(value))
            }.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingError(
                    message: "Речь не распознана. Проверьте, что в файле есть русская речь."
                )
            }
            await update(.transcript(text))
        }

        try Task.checkCancellation()
        await update(.stage("Сохранение расшифровки…"))
        let file = try MeetingFileStore.saveFile(
            text,
            title: input.deletingPathExtension().lastPathComponent,
            extension: "raw.txt",
            directory: settings.outputDirectory
        )
        return MeetingOutput(transcript: file)
    }

    static func summarize(
        _ output: MeetingOutput, settings: MeetingSettings,
        provider: (any SummaryProvider)? = nil,
        update: @escaping @Sendable (MeetingEvent) async -> Void
    ) async throws -> MeetingOutput {
        let provider = provider ?? SummaryProviderFactory.make(.codex(.init(
            executable: settings.codex, model: settings.codexModel,
            reasoning: settings.codexReasoning
        )))
        try MeetingFileStore.prepareOutputDirectory(settings.outputDirectory)
        try Task.checkCancellation()
        let text = try String(contentsOf: output.transcript, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingError(message: "Расшифровка пуста. Нет текста для суммаризации.")
        }
        let parts = splitTranscript(text)
        let sourceGroups = parts.enumerated().map { part, text in
            splitTranscript(text, limit: 1200).enumerated().map { index, fragment in
                TranscriptSource(id: "p\(part + 1)s\(index + 1)", text: fragment)
            }
        }
        let sources = sourceGroups.flatMap(\.self)
        let extractionGroups = try sourceGroups.enumerated().flatMap { index, group in
            let context = index > 0 ? Array(sourceGroups[index - 1].suffix(1)) : []
            return try summaryInputGroups(context + group, partial: true)
        }
        var needsExtraction = extractionGroups.count > 1
        if !needsExtraction {
            needsExtraction = try summaryPrompt(sources, partial: false).utf8
                .count > summaryPromptLimit
        }
        var notes: [MeetingNotes] = []
        if needsExtraction {
            for (index, input) in extractionGroups.enumerated() {
                try Task.checkCancellation()
                await update(
                    .stage(
                        "Извлечение фактов: часть \(index + 1) из \(extractionGroups.count)…"
                    )
                )
                let extracted: MeetingNotes = try await requestSummary(
                    input, provider: provider, partial: true
                )
                try extracted.validate(sources: input)
                notes.append(extracted)
            }
        }
        while !notes.isEmpty {
            let before = try summaryPrompt(notes, partial: false, merging: true).utf8
                .count
            if before <= summaryPromptLimit {
                break
            }
            let groups = try summaryInputGroups(notes, partial: true, merging: true)
            var reduced: [MeetingNotes] = []
            for (index, group) in groups.enumerated() {
                try Task.checkCancellation()
                await update(
                    .stage("Сжатие фактов: часть \(index + 1) из \(groups.count)…")
                )
                let merged: MeetingNotes = try await requestSummary(
                    group, provider: provider, partial: true,
                    merging: true
                )
                try merged.validate(sources: sources)
                let allowed = group
                    .reduce(into: Set<String>()) { $0.formUnion($1.sourceIDs) }
                guard merged.sourceIDs.isSubset(of: allowed) else {
                    throw MeetingError(
                        message: "Codex сослался на источник вне объединяемых фактов. Повторите суммаризацию."
                    )
                }
                reduced.append(merged)
            }
            let after = try summaryPrompt(reduced, partial: false, merging: true).utf8
                .count
            // Stop repeated CLI calls when the model cannot make enough room.
            guard after <= summaryPromptLimit || after <= before * 3 / 4
            else { throw summarySizeError }
            notes = reduced
        }
        await update(.stage("Определение типа и сборка протокола…"))
        let summary: MeetingSummary
        if notes.isEmpty {
            summary = try await requestSummary(
                sources,
                provider: provider
            )
        } else {
            summary = try await requestSummary(
                notes,
                provider: provider,
                merging: true
            )
        }
        try summary.validate(sources: sources)
        if !notes.isEmpty,
           !summary.sourceIDs
               .isSubset(of: notes
                   .reduce(into: Set<String>()) { $0.formUnion($1.sourceIDs) })
        {
            throw MeetingError(
                message: "Codex сослался на источник вне извлечённых фактов. Повторите суммаризацию."
            )
        }
        try Task.checkCancellation()
        await update(.stage("Сохранение…"))
        return try MeetingFileStore.save(
            summary,
            transcript: output.transcript,
            directory: settings.outputDirectory
        )
    }

    /// Bound each Codex input for two-hour recordings; split at paragraph/word
    /// boundaries.
    static func splitTranscript(_ text: String, limit: Int = 24000) -> [String] {
        precondition(limit > 0)
        var remaining = text[...]
        var parts: [String] = []
        while let boundary = remaining.index(
                  remaining.startIndex,
                  offsetBy: limit,
                  limitedBy: remaining.endIndex
              ),
              boundary < remaining.endIndex
        {
            let midpoint = remaining.index(
                remaining.startIndex,
                offsetBy: max(1, limit / 2)
            )
            let split = remaining[midpoint ..< boundary]
                .lastIndex(where: \.isWhitespace) ?? boundary
            parts.append(String(remaining[..<split]))
            remaining = remaining[split...]
        }
        if !remaining.isEmpty {
            parts.append(String(remaining))
        }
        return parts
    }

    static func summaryPrompt(
        _ values: [some Encodable], partial: Bool, merging: Bool = false
    ) throws -> String {
        try summaryRequest(values, partial: partial, merging: merging).prompt
    }

    private static func summaryRequest(
        _ values: [some Encodable], partial: Bool, merging: Bool
    ) throws -> SummaryRequest {
        try SummaryRequest(
            instructions: SummaryPromptBuilder.instructions(
                partial: partial,
                merging: merging
            ),
            input: JSONEncoder().encode(values),
            outputSchema: SummarySchema.make(partial: partial)
        )
    }

    static func summaryInputGroups<Value: Encodable>(
        _ values: [Value], partial: Bool, merging: Bool = false
    ) throws -> [[Value]] {
        let overhead = try summaryPrompt([Value](), partial: partial, merging: merging)
            .utf8.count
        var groups: [[Value]] = []
        var group: [Value] = []
        var size = overhead
        let encoder = JSONEncoder()
        for value in values {
            try Task.checkCancellation()
            let bytes = try encoder.encode(value).count
            guard overhead + bytes <= summaryPromptLimit else { throw summarySizeError }
            let separator = group.isEmpty ? 0 : 1
            if size + bytes + separator > summaryPromptLimit {
                groups.append(group)
                group = []
                size = overhead
            }
            size += bytes + (group.isEmpty ? 0 : 1)
            group.append(value)
        }
        if !group.isEmpty {
            groups.append(group)
        }
        return groups
    }

    private static func requestSummary<Result: Decodable>(
        _ input: [some Encodable], provider: any SummaryProvider,
        partial: Bool = false, merging: Bool = false
    ) async throws -> Result {
        let request = try summaryRequest(input, partial: partial, merging: merging)
        guard try request.prompt.utf8.count <= summaryPromptLimit
        else { throw summarySizeError }
        let data = try await provider.generate(request)
        do {
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw MeetingError(
                message: "Провайдер вернул некорректное резюме. Расшифровка доступна для повторной попытки."
            )
        }
    }
}
