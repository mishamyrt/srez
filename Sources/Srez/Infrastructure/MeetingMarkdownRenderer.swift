import Foundation

enum MeetingMarkdownRenderer {
    static func render(_ value: MeetingSummary) -> String {
        let title = value.title
        let summary = value.summary
        let topics = value.topics
        let decisions = value.decisions
        let actions = value.actions
        let openQuestions = value.openQuestions
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
