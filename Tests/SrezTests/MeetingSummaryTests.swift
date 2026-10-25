import XCTest
@testable import Srez

final class MeetingSummaryTests: XCTestCase {
    private let sources = [TranscriptSource(id: "p1s1", text: "Долго ищу отчёт. Миша проверит к пятнице.")]

    func testMixedMeetingKeepsSpecializedTopicsAndQuestionAnswerGroups() throws {
        let summary = MeetingSummary(title: "Исследование отчётов", meetingType: .userResearch, topics: [
            .init(title: "Поиск отчёта", kind: .userResearch, details: [
                .init(kind: .problem, text: "Сложно найти отчёт.", sourceIDs: ["p1s1"]),
                .init(kind: .quote, text: "Долго ищу отчёт.", sourceIDs: ["p1s1"])
            ]),
            .init(title: "Опыт работы", kind: .interview, details: [
                .init(kind: .question, text: "Как ищете отчёт?", sourceIDs: ["p1s1"]),
                .init(kind: .answer, text: "Ответ участника.", speaker: "Миша", sourceIDs: ["p1s1"]),
                .init(kind: .evidence, text: "Приведён пример.", sourceIDs: ["p1s1"]),
                .init(kind: .question, text: "Как часто?", sourceIDs: ["p1s1"]),
                .init(kind: .answer, text: "Каждый день.", sourceIDs: ["p1s1"])
            ])
        ], actions: [.init(text: "Проверить поиск.", owner: "Миша", due: "к пятнице", sourceIDs: ["p1s1"])])
        try summary.validate(sources: sources)
        let markdown = summary.markdown
        XCTAssertFalse(markdown.contains("Тип встречи:"))
        XCTAssertTrue(markdown.contains("**Цитата:** «Долго ищу отчёт.»"))
        XCTAssertTrue(markdown.contains("**Ответ (Миша):** Ответ участника."))
        XCTAssertTrue(markdown.contains("**Срок:** к пятнице"))
        let question = try XCTUnwrap(markdown.range(of: "**Вопрос:**"))
        let answer = try XCTUnwrap(markdown.range(of: "**Ответ (Миша):**"))
        let evidence = try XCTUnwrap(markdown.range(of: "**Факт / пример:**"))
        let nextQuestion = try XCTUnwrap(markdown.range(of: "**Вопрос:** Как часто?"))
        let nextAnswer = try XCTUnwrap(markdown.range(of: "**Ответ:** Каждый день."))
        XCTAssertLessThan(question.lowerBound, answer.lowerBound)
        XCTAssertLessThan(answer.lowerBound, evidence.lowerBound)
        XCTAssertLessThan(evidence.lowerBound, nextQuestion.lowerBound)
        XCTAssertLessThan(nextQuestion.lowerBound, nextAnswer.lowerBound)
        XCTAssertFalse(markdown.contains("## Решения"))
        XCTAssertFalse(markdown.contains("## Открытые вопросы"))
    }

    func testRendersDecisionConditionsTaskGapsAndOpenQuestion() throws {
        let summary = MeetingSummary(title: "Релиз", meetingType: .project,
            decisions: [.init(text: "Выпускаем релиз.", conditions: ["После проверки."],
                              rationale: "Устраняет блокер.", sourceIDs: ["p1s1"])],
            actions: [.init(text: "Провести проверку.", dependencies: ["Тестовый стенд."], sourceIDs: ["p1s1"])],
            openQuestions: [.init(text: "Когда готов стенд?", needed: "Уточнить доступность.",
                                  owner: "Миша", sourceIDs: ["p1s1"])])
        try summary.validate(sources: sources)
        let markdown = summary.markdown
        for expected in ["## Решения", "**Условия:** После проверки.", "**Обоснование:** Устраняет блокер.",
                         "## Задачи", "**Ответственный:** не определён", "**Срок:** не указан",
                         "**Зависимости:** Тестовый стенд.", "## Открытые вопросы",
                         "**Нужно выяснить:** Уточнить доступность.", "**Ответственный:** Миша"] {
            XCTAssertTrue(markdown.contains(expected), expected)
        }
        XCTAssertFalse(markdown.contains("## Краткое резюме"))
        XCTAssertFalse(markdown.contains("## Обсуждавшиеся вопросы"))
    }

    func testEveryMeetingTypeHasAnAutomaticProfileAndCanRender() throws {
        for type in MeetingType.allCases {
            let summary = MeetingSummary(title: "Тема", meetingType: type, topics: [
                .init(title: "Вопрос", kind: type, details: [
                    .init(kind: try XCTUnwrap(type.detailKinds.first), text: "Содержание.", sourceIDs: ["p1s1"])
                ])
            ])
            let decoded = try JSONDecoder().decode(MeetingSummary.self, from: JSONEncoder().encode(summary))
            try decoded.validate(sources: sources)
            XCTAssertEqual(decoded.meetingType, type)
            XCTAssertFalse(decoded.markdown.contains("Тип встречи:"))
            XCTAssertTrue(decoded.markdown.hasPrefix("# Тема\n\n## Обсуждавшиеся вопросы"))
            XCTAssertTrue(decoded.markdown.contains("Содержание."))
        }
    }

    func testRejectsMissingAndUnknownEvidenceAndEmptyContent() {
        for ids in [[], ["missing"], ["p1s1", "missing"]] as [[String]] {
            let invalid = MeetingSummary(title: "Тема", meetingType: .general,
                                         summary: [.init(text: "Содержание.", sourceIDs: ids)])
            XCTAssertThrowsError(try invalid.validate(sources: sources))
        }
        XCTAssertThrowsError(try MeetingSummary(title: "Тема", meetingType: .general).validate(sources: sources))
        XCTAssertThrowsError(try MeetingSummary(title: " ", meetingType: .general,
            actions: [.init(text: "Проверить.", sourceIDs: ["p1s1"])])
            .validate(sources: sources))
        let invalid = MeetingNotes(topics: [.init(title: "Тема", kind: .general, details: [])])
        XCTAssertThrowsError(try invalid.validate(sources: sources))
        XCTAssertNoThrow(try MeetingNotes().validate(sources: sources))
    }

    func testQuotesMustMatchCitedContiguousSourceText() {
        func notes(_ text: String, ids: [String]) -> MeetingNotes {
            MeetingNotes(topics: [.init(title: "Тема", kind: .userResearch, details: [
                .init(kind: .quote, text: text, sourceIDs: ids)
            ])])
        }
        let fragments = [TranscriptSource(id: "1", text: "Долго "),
                         TranscriptSource(id: "2", text: "ищу "),
                         TranscriptSource(id: "3", text: "отчёт.")]
        XCTAssertNoThrow(try notes("Долго ищу отчёт.", ids: ["1", "2", "3"]).validate(sources: fragments))
        XCTAssertThrowsError(try notes("Долго отчёт.", ids: ["1", "3"]).validate(sources: fragments))
        XCTAssertThrowsError(try notes("Долго ищу отчёт.", ids: ["1"]).validate(sources: fragments))
        XCTAssertThrowsError(try notes("Быстро нахожу отчёт.", ids: ["1", "2", "3"]).validate(sources: fragments))
    }

    func testModelTextCannotCreateAdditionalMarkdownSections() throws {
        let summary = MeetingSummary(title: "Тема\n## Решения", meetingType: .general,
            summary: [.init(text: "Факт\n\n## Задачи\n<script> *жирный* [ссылка](url)", sourceIDs: ["p1s1"])])
        try summary.validate(sources: sources)
        let markdown = summary.markdown
        XCTAssertFalse(markdown.contains("\n## Решения"))
        XCTAssertFalse(markdown.contains("\n## Задачи"))
        XCTAssertFalse(markdown.contains("<script>"))
        XCTAssertFalse(markdown.contains("*жирный*"))
        XCTAssertFalse(markdown.contains("[ссылка](url)"))
    }
}
