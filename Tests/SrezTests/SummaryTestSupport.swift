import Foundation
@testable import Srez

func summarize(
    _ output: MeetingOutput, settings: MeetingSettings, provider: (any SummaryProvider)? = nil,
    update: @escaping @Sendable (MeetingEvent) async -> Void
) async throws -> MeetingOutput {
    let service = SummarizationService(provider: provider ?? SummaryProviderFactory.make(settings.provider))
    return try await service.summarize(output, directory: settings.outputDirectory, update: update)
}

actor RecordingSummaryProvider: SummaryProvider {
    let response: Data
    let pauseFirst: Bool
    var requests: [SummaryRequest] = []
    private var gate: CheckedContinuation<Void, Never>?
    init(response: Data, pauseFirst: Bool = false) { self.response = response; self.pauseFirst = pauseFirst }
    func generate(_ request: SummaryRequest) async throws -> Data {
        requests.append(request)
        if pauseFirst && requests.count == 1 { await withCheckedContinuation { gate = $0 } }
        try Task.checkCancellation()
        return response
    }
    func releaseFirst() { gate?.resume(); gate = nil }
}
