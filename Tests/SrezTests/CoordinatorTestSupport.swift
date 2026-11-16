import Foundation
@testable import Srez

@MainActor
func makeCoordinator(
    jobs: [MeetingJob] = [],
    combine: @escaping @Sendable ([MeetingOutput], URL) throws -> MeetingOutput = {
        try MeetingFileStore.combineTranscripts($0, directory: $1)
    }
) -> MeetingCoordinator {
    let store = SettingsStore()
    return MeetingCoordinator(jobs: jobs,
                              settings: { try await store.current(summarizing: $0 == .summarization) },
                              makeProvider: { SummaryProviderFactory.make($0) }, combine: combine)
}

extension MeetingSettings {
    init(outputDirectory: URL, ffmpeg: URL, codex: URL, codexModel: String, codexReasoning: String) {
        self.init(outputDirectory: outputDirectory, ffmpeg: ffmpeg,
                  provider: .codex(.init(executable: codex, model: codexModel, reasoning: codexReasoning)))
    }
}
