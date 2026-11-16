import Foundation

struct SummaryRequest: Sendable {
    let instructions: String
    let input: Data
    let outputSchema: Data

    var prompt: String {
        get throws {
            guard let text = String(bytes: input, encoding: .utf8) else {
                throw MeetingError(message: "Не удалось подготовить запрос суммаризации.")
            }
            return """
            \(instructions)

            <meeting_data>
            \(text)
            </meeting_data>
            """
        }
    }
}

protocol SummaryProvider: Sendable {
    /// Returns the result JSON without a transport-specific envelope.
    func generate(_ request: SummaryRequest) async throws -> Data
}

typealias SummaryProviderBuilder = @Sendable (ProviderConfiguration)
    -> any SummaryProvider
