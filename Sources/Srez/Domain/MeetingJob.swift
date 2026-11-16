import Foundation

struct MeetingJob: Identifiable, Sendable {
    enum Kind: Sendable { case transcription, summarization }
    enum State: Sendable { case waiting, running, done, failed, cancelled }
    let id = UUID()
    let input: URL
    var kind: Kind = .transcription
    var state = State.waiting
    var stage = ProcessingStage.queued
    var progress: Double?
    var transcript: String?
    var output: MeetingOutput?
    var error: String?
    var canSelectForSummary: Bool {
        state == .done && output != nil
    }

    var canSummarize: Bool {
        canSelectForSummary && output?.summary == nil
    }
}
