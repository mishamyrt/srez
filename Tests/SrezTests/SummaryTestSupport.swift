import Foundation
@testable import Srez

func summarize(
    _ output: MeetingOutput, settings: MeetingSettings, provider: (any SummaryProvider)? = nil,
    update: @escaping @Sendable (MeetingEvent) async -> Void
) async throws -> MeetingOutput {
    let service = SummarizationService(provider: provider ?? SummaryProviderFactory.make(settings.provider))
    return try await service.summarize(output, directory: settings.outputDirectory, update: update)
}
