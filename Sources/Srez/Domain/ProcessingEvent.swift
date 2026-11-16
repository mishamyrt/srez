import Foundation

enum ProcessingStage: Sendable, Equatable {
    case queued, queuedForSummary, convertingAudio, checkingModel, loadingModel,
         recognizing
    case downloadingModel(file: Int, total: Int)
    case extractingFacts(part: Int, total: Int)
    case reducingFacts(part: Int, total: Int)
    case composingSummary, savingTranscript, savingSummary
    case cancelling, cancelled, unsupportedFormat, failed, transcriptReady, completed
}

enum MeetingEvent: Sendable {
    case stage(ProcessingStage)
    case progress(Double)
    case transcript(String)
}

struct MeetingSnapshot: Sendable {
    let jobs: [MeetingJob]
    let combining: Bool
    let hasPendingJobs: Bool
    var hasUnsavedTranscripts: Bool {
        jobs.contains { $0.transcript != nil }
    }
}
