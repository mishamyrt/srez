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

    var notes: MeetingNotes {
        MeetingNotes(
            topics: topics,
            decisions: decisions,
            actions: actions,
            openQuestions: openQuestions
        )
    }
}
