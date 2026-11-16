import Foundation

enum SummaryValidator {
    static func validate(_ notes: MeetingNotes, sources: [TranscriptSource]) throws {
        let validIDs = Set(sources.map(\.id))
        func check(_ text: String, _ ids: [String]) throws {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !ids.isEmpty, Set(ids).isSubset(of: validIDs)
            else {
                throw MeetingError(
                    message: "Провайдер вернул сведения без корректного источника. Повторите суммаризацию."
                )
            }
        }
        func checkFields(_ values: [String]) throws {
            guard values
                .allSatisfy({
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
            else {
                throw MeetingError(
                    message: "Провайдер вернул пустое поле протокола. Повторите суммаризацию."
                )
            }
        }
        for topic in notes.topics {
            try checkFields([topic.title])
            guard !topic.details.isEmpty else {
                throw MeetingError(
                    message: "Провайдер вернул пустую тему. Повторите суммаризацию."
                )
            }
            for detail in topic.details {
                try check(detail.text, detail.sourceIDs)
                try checkFields([detail.speaker].compactMap(\.self))
                if detail.kind == .quote {
                    let ids = Set(detail.sourceIDs)
                    let runs = sources.split { !ids.contains($0.id) }
                    guard runs
                        .contains(where: { $0.map(\.text).joined().contains(detail.text)
                        })
                    else {
                        throw MeetingError(
                            message: "Цитата Провайдер не совпала с расшифровкой. Повторите суммаризацию."
                        )
                    }
                }
            }
        }
        for decision in notes.decisions {
            try check(decision.text, decision.sourceIDs)
            try checkFields(decision.conditions + [decision.rationale].compactMap(\.self))
        }
        for action in notes.actions {
            try check(action.text, action.sourceIDs)
            try checkFields(action.dependencies + [action.owner, action.due]
                .compactMap(\.self))
        }
        for question in notes.openQuestions {
            try check(question.text, question.sourceIDs)
            try checkFields([question.needed, question.owner].compactMap(\.self))
        }
    }

    static func validate(_ value: MeetingSummary, sources: [TranscriptSource]) throws {
        guard !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.summary.isEmpty || !value.notes.sourceIDs.isEmpty
        else {
            throw MeetingError(
                message: "Провайдер вернул пустое резюме. Повторите суммаризацию."
            )
        }
        try validate(value.notes, sources: sources)
        if !value.summary.isEmpty {
            try validate(
                MeetingNotes(topics: [.init(
                    title: value.title,
                    kind: .general,
                    details: value.summary.map {
                        .init(kind: .fact, text: $0.text, sourceIDs: $0.sourceIDs)
                    }
                )]),
                sources: sources
            )
        }
    }
}
