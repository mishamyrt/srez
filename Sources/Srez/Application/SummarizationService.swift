import Foundation

struct SummarizationService: Sendable {
    let provider: any SummaryProvider

    static let summaryPromptLimit = 96 * 1024
    private static let summarySizeError = MeetingError(
        message: "Не удалось уместить факты в лимит запроса. Разбейте запись или выберите меньше встреч."
    )

    func summarize(
        _ output: MeetingOutput, directory: URL,
        update: @escaping @Sendable (MeetingEvent) async -> Void
    ) async throws -> MeetingOutput {
        try MeetingFileStore.prepareOutputDirectory(directory)
        try Task.checkCancellation()
        let text = try String(contentsOf: output.transcript, encoding: .utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingError(message: "Расшифровка пуста. Нет текста для суммаризации.")
        }
        let parts = Self.splitTranscript(text)
        let sourceGroups = parts.enumerated().map { part, text in
            Self.splitTranscript(text, limit: 1200).enumerated().map { index, fragment in
                TranscriptSource(id: "p\(part + 1)s\(index + 1)", text: fragment)
            }
        }
        let sources = sourceGroups.flatMap(\.self)
        let extractionGroups = try sourceGroups.enumerated().flatMap { index, group in
            let context = index > 0 ? Array(sourceGroups[index - 1].suffix(1)) : []
            return try Self.summaryInputGroups(context + group, partial: true)
        }
        var needsExtraction = extractionGroups.count > 1
        if !needsExtraction {
            needsExtraction = try Self.summaryPrompt(sources, partial: false).utf8
                .count > Self.summaryPromptLimit
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
                    input, partial: true
                )
                try SummaryValidator.validate(extracted, sources: input)
                notes.append(extracted)
            }
        }
        while !notes.isEmpty {
            let before = try Self.summaryPrompt(notes, partial: false, merging: true).utf8
                .count
            if before <= Self.summaryPromptLimit {
                break
            }
            let groups = try Self.summaryInputGroups(notes, partial: true, merging: true)
            var reduced: [MeetingNotes] = []
            for (index, group) in groups.enumerated() {
                try Task.checkCancellation()
                await update(
                    .stage("Сжатие фактов: часть \(index + 1) из \(groups.count)…")
                )
                let merged: MeetingNotes = try await requestSummary(
                    group, partial: true,
                    merging: true
                )
                try SummaryValidator.validate(merged, sources: sources)
                let allowed = group
                    .reduce(into: Set<String>()) { $0.formUnion($1.sourceIDs) }
                guard merged.sourceIDs.isSubset(of: allowed) else {
                    throw MeetingError(
                        message: "Codex сослался на источник вне объединяемых фактов. Повторите суммаризацию."
                    )
                }
                reduced.append(merged)
            }
            let after = try Self.summaryPrompt(reduced, partial: false, merging: true)
                .utf8
                .count
            // Stop repeated CLI calls when the model cannot make enough room.
            guard after <= Self.summaryPromptLimit || after <= before * 3 / 4
            else { throw Self.summarySizeError }
            notes = reduced
        }
        await update(.stage("Определение типа и сборка протокола…"))
        let summary: MeetingSummary
        if notes.isEmpty {
            summary = try await requestSummary(
                sources
            )
        } else {
            summary = try await requestSummary(
                notes,
                merging: true
            )
        }
        try SummaryValidator.validate(summary, sources: sources)
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
            directory: directory
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
        let overhead = try Self.summaryPrompt(
            [Value](),
            partial: partial,
            merging: merging
        )
        .utf8.count
        var groups: [[Value]] = []
        var group: [Value] = []
        var size = overhead
        let encoder = JSONEncoder()
        for value in values {
            try Task.checkCancellation()
            let bytes = try encoder.encode(value).count
            guard overhead + bytes <= Self.summaryPromptLimit
            else { throw Self.summarySizeError }
            let separator = group.isEmpty ? 0 : 1
            if size + bytes + separator > Self.summaryPromptLimit {
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

    private func requestSummary<Result: Decodable>(
        _ input: [some Encodable],
        partial: Bool = false, merging: Bool = false
    ) async throws -> Result {
        let request = try Self.summaryRequest(input, partial: partial, merging: merging)
        guard try request.prompt.utf8.count <= Self.summaryPromptLimit
        else { throw Self.summarySizeError }
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
