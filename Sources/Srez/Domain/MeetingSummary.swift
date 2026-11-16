import Foundation

enum MeetingType: String, Codable, CaseIterable, Sendable {
    case project, oneOnOne = "one_on_one", sales, interview,
         userResearch = "user_research",
         retro, general

    var title: String {
        switch self {
        case .project: "Проектная встреча"
        case .oneOnOne: "1:1"
        case .sales: "Клиент / Sales"
        case .interview: "Интервью / Q&A"
        case .userResearch: "User Research"
        case .retro: "Ретро"
        case .general: "Общая встреча"
        }
    }

    var detailKinds: [MeetingDetail.Kind] {
        switch self {
        case .project: [.status, .change, .blocker, .dependency]
        case .oneOnOne: [.change, .concern, .feedback, .agreement, .nextMeeting]
        case .sales: [
                .need,
                .pain,
                .requirement,
                .objection,
                .budget,
                .timeline,
                .competitor,
                .promise,
            ]
        case .interview: [.question, .answer, .clarification, .evidence]
        case .userResearch: [
                .problem,
                .workflow,
                .motivation,
                .quote,
                .featureRequest,
                .workaround,
                .recurringTheme,
            ]
        case .retro: [.worked, .didNotWork, .cause, .start, .stop, .continue, .experiment]
        case .general: [.fact, .position, .argument, .disagreement]
        }
    }
}

struct TranscriptSource: Codable, Sendable {
    let id: String
    let text: String
}

struct MeetingStatement: Codable, Sendable {
    var text: String
    var sourceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case text, sourceIDs = "source_ids"
    }
}

struct MeetingDetail: Codable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case fact = "Факт", position = "Позиция", argument = "Аргумент", disagreement = "Разногласие"
        case status = "Статус", change = "Изменение", blocker = "Блокер", dependency = "Зависимость"
        case concern = "Проблема / опасение", feedback = "Обратная связь", agreement = "Договорённость"
        case nextMeeting = "Тема следующего 1:1"
        case need = "Потребность", pain = "Боль", requirement = "Требование",
             objection = "Возражение"
        case budget = "Бюджет", timeline = "Сроки клиента", competitor = "Конкурент",
             promise = "Обещание"
        case question = "Вопрос", answer = "Ответ", clarification = "Уточнение",
             evidence = "Факт / пример"
        case problem = "Проблема пользователя", workflow = "Текущий процесс",
             motivation = "Мотивация"
        case quote = "Цитата", featureRequest = "Пожелание", workaround = "Обходное решение"
        case recurringTheme = "Повторяющаяся тема"
        case worked = "Что сработало", didNotWork = "Что не сработало", cause = "Причина"
        case start = "Start", stop = "Stop", `continue` = "Continue", experiment = "Эксперимент"
    }

    var kind: Kind
    var text: String
    var speaker: String?
    var sourceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case kind, text, speaker, sourceIDs = "source_ids"
    }
}

struct MeetingTopic: Codable, Sendable {
    var title: String
    var kind: MeetingType
    var details: [MeetingDetail]
}

struct MeetingDecision: Codable, Sendable {
    var text: String
    var conditions: [String] = []
    var rationale: String?
    var sourceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case text, conditions, rationale, sourceIDs = "source_ids"
    }
}

struct MeetingAction: Codable, Sendable {
    var text: String
    var owner: String?
    var due: String?
    var dependencies: [String] = []
    var sourceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case text, owner, due, dependencies, sourceIDs = "source_ids"
    }
}

struct MeetingQuestion: Codable, Sendable {
    var text: String
    var needed: String?
    var owner: String?
    var sourceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case text, needed, owner, sourceIDs = "source_ids"
    }
}

/// Partial results keep facts of every meeting type, without choosing a template or
/// writing an overview.
struct MeetingNotes: Codable, Sendable {
    var topics: [MeetingTopic] = []
    var decisions: [MeetingDecision] = []
    var actions: [MeetingAction] = []
    var openQuestions: [MeetingQuestion] = []

    enum CodingKeys: String, CodingKey {
        case topics, decisions, actions, openQuestions = "open_questions"
    }

    var sourceIDs: Set<String> {
        Set(topics.flatMap { $0.details.flatMap(\.sourceIDs) }
            + decisions.flatMap(\.sourceIDs) + actions
            .flatMap(\.sourceIDs) + openQuestions.flatMap(\.sourceIDs))
    }

    func validate(sources: [TranscriptSource]) throws {
        let validIDs = Set(sources.map(\.id))
        func check(_ text: String, _ ids: [String]) throws {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !ids.isEmpty, Set(ids).isSubset(of: validIDs)
            else {
                throw MeetingError(
                    message: "Codex вернул сведения без корректного источника. Повторите суммаризацию."
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
                    message: "Codex вернул пустое поле протокола. Повторите суммаризацию."
                )
            }
        }
        for topic in topics {
            try checkFields([topic.title])
            guard !topic.details.isEmpty else {
                throw MeetingError(
                    message: "Codex вернул пустую тему. Повторите суммаризацию."
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
                            message: "Цитата Codex не совпала с расшифровкой. Повторите суммаризацию."
                        )
                    }
                }
            }
        }
        for decision in decisions {
            try check(decision.text, decision.sourceIDs)
            try checkFields(decision.conditions + [decision.rationale].compactMap(\.self))
        }
        for action in actions {
            try check(action.text, action.sourceIDs)
            try checkFields(action.dependencies + [action.owner, action.due]
                .compactMap(\.self))
        }
        for question in openQuestions {
            try check(question.text, question.sourceIDs)
            try checkFields([question.needed, question.owner].compactMap(\.self))
        }
    }
}

struct MeetingSummary: Codable, Sendable {
    var title: String
    var meetingType: MeetingType
    var summary: [MeetingStatement] = []
    var topics: [MeetingTopic] = []
    var decisions: [MeetingDecision] = []
    var actions: [MeetingAction] = []
    var openQuestions: [MeetingQuestion] = []

    enum CodingKeys: String, CodingKey {
        case title, meetingType = "meeting_type", summary, topics, decisions, actions
        case openQuestions = "open_questions"
    }

    var sourceIDs: Set<String> {
        Set(summary.flatMap(\.sourceIDs)).union(notes.sourceIDs)
    }

    private var notes: MeetingNotes {
        MeetingNotes(
            topics: topics,
            decisions: decisions,
            actions: actions,
            openQuestions: openQuestions
        )
    }

    func validate(sources: [TranscriptSource]) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !summary.isEmpty || !notes.sourceIDs.isEmpty
        else {
            throw MeetingError(
                message: "Codex вернул пустое резюме. Повторите суммаризацию."
            )
        }
        try notes.validate(sources: sources)
        // Use the same evidence checks for the overview as for discussion details.
        if !summary.isEmpty {
            try MeetingNotes(topics: [.init(
                title: title,
                kind: .general,
                details: summary.map {
                    .init(kind: .fact, text: $0.text, sourceIDs: $0.sourceIDs)
                }
            )]).validate(sources: sources)
        }
    }

    var markdown: String {
        func inline(_ text: String) -> String {
            var value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            for character in ["\\", "`", "*", "_", "[", "]", "<", ">", "#", "|"] {
                value = value.replacingOccurrences(of: character, with: "\\" + character)
            }
            return value
        }
        var sections = ["# \(inline(title))"]
        func append(_ title: String, _ items: [String]) {
            if !items
                .isEmpty
            {
                sections.append("## \(title)\n\n" + items.joined(separator: "\n\n"))
            }
        }
        append("Краткое резюме", summary.map { inline($0.text) })
        append("Обсуждавшиеся вопросы", topics.map { topic in
            let order = topic.kind.detailKinds
            // Keep Q&A groups together; sorting all questions before all answers loses
            // their relationship.
            let ordered = topic.kind == .interview ? topic.details : topic.details
                .enumerated().sorted {
                    let left = order.firstIndex(of: $0.element.kind) ?? order.count
                    let right = order.firstIndex(of: $1.element.kind) ?? order.count
                    return left == right ? $0.offset < $1.offset : left < right
                }.map(\.element)
            let details = ordered.map { detail in
                let speaker = detail.speaker.map { " (\(inline($0)))" } ?? ""
                let text = inline(detail.text)
                return "- **\(detail.kind.rawValue)\(speaker):** \(detail.kind == .quote ? "«\(text)»" : text)"
            }
            return "### \(inline(topic.title))\n\n" + details.joined(separator: "\n")
        })
        append("Решения", decisions.map { decision in
            var item = "- \(inline(decision.text))"
            if !decision.conditions.isEmpty {
                item += "\n  **Условия:** \(decision.conditions.map(inline).joined(separator: "; "))"
            }
            if let rationale = decision
                .rationale
            {
                item += "\n  **Обоснование:** \(inline(rationale))"
            }
            return item
        })
        append("Задачи", actions.map { action in
            var item = "- \(inline(action.text))\n  **Ответственный:** \(inline(action.owner ?? "не определён")); "
                + "**Срок:** \(inline(action.due ?? "не указан"))"
            if !action.dependencies.isEmpty {
                item += "\n  **Зависимости:** \(action.dependencies.map(inline).joined(separator: "; "))"
            }
            return item
        })
        append("Открытые вопросы", openQuestions.map { question in
            var item = "- \(inline(question.text))"
            if let needed = question
                .needed
            {
                item += "\n  **Нужно выяснить:** \(inline(needed))"
            }
            if let owner = question
                .owner
            {
                item += "\n  **Ответственный:** \(inline(owner))"
            }
            return item
        })
        return sections.joined(separator: "\n\n")
    }
}
