import Foundation

enum SummarySchema {
    static func make(partial: Bool) throws -> Data {
        func object(_ properties: [String: Any]) -> [String: Any] {
            [
                "type": "object",
                "properties": properties,
                "required": properties.keys.sorted(),
                "additionalProperties": false,
            ]
        }
        func array(_ items: [String: Any]) -> [String: Any] {
            [
                "type": "array",
                "items": items,
            ]
        }
        let string: [String: Any] = ["type": "string"]
        let nullableString: [String: Any] = ["type": ["string", "null"]]
        let strings = array(string)
        let type: [String: Any] = [
            "type": "string",
            "enum": MeetingType.allCases.map(\.rawValue),
        ]
        let detail = object([
            "kind": [
                "type": "string",
                "enum": MeetingDetail.Kind.allCases.map(\.rawValue),
            ],
            "text": string, "speaker": nullableString, "source_ids": strings,
        ])
        var properties: [String: Any] = [
            "topics": array(object([
                "title": string,
                "kind": type,
                "details": array(detail),
            ])),
            "decisions": array(object([
                "text": string, "conditions": strings, "rationale": nullableString,
                "source_ids": strings,
            ])),
            "actions": array(object([
                "text": string, "owner": nullableString, "due": nullableString,
                "dependencies": strings, "source_ids": strings,
            ])),
            "open_questions": array(object([
                "text": string, "needed": nullableString, "owner": nullableString,
                "source_ids": strings,
            ])),
        ]
        if !partial {
            properties["title"] = string
            properties["meeting_type"] = type
            properties["summary"] = array(object(["text": string, "source_ids": strings]))
        }
        return try JSONSerialization.data(
            withJSONObject: object(properties),
            options: [.sortedKeys]
        )
    }
}
