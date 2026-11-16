import XCTest
@testable import Srez

final class SummaryProviderTests: XCTestCase {
    func testSummarizationAcceptsProviderWithoutCLIAndValidatesItsResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = MeetingSettings(outputDirectory: directory, ffmpeg: directory.appendingPathComponent("missing"),
                                       codex: directory.appendingPathComponent("missing"), codexModel: "", codexReasoning: "medium")
        let output = try await MeetingPipeline.run(input: directory.appendingPathComponent("meeting.wav"),
                                                   settings: settings, transcript: "Исходная речь.", update: { _ in })
        for id in ["p1s1", "unknown"] {
            let summary = MeetingSummary(title: "Тема", meetingType: .general,
                                         summary: [.init(text: "Итог встречи.", sourceIDs: [id])])
            let provider = StubProvider(response: try JSONEncoder().encode(summary))
            do {
                let result = try await MeetingPipeline.summarize(output, settings: settings, provider: provider, update: { _ in })
                XCTAssertEqual(id, "p1s1")
                XCTAssertNotNil(result.summary)
            } catch {
                XCTAssertEqual(id, "unknown")
                XCTAssertTrue(error is MeetingError)
            }
            let requests = await provider.requests
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.first)
            let sources = try JSONDecoder().decode([TranscriptSource].self, from: request.input)
            XCTAssertEqual(sources.map(\.text).joined(), "Исходная речь.")
            XCTAssertFalse(request.instructions.contains("Исходная речь."))
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: request.outputSchema) as? [String: Any])
        }
        XCTAssertEqual(try String(contentsOf: output.transcript), "Исходная речь.")
    }

    private actor StubProvider: SummaryProvider {
        let response: Data
        var requests: [SummaryRequest] = []
        init(response: Data) { self.response = response }
        func generate(_ request: SummaryRequest) async throws -> Data {
            try Task.checkCancellation()
            requests.append(request)
            return response
        }
    }
}
