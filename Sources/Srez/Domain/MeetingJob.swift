import Foundation

struct MeetingJob: Identifiable {
    enum State { case waiting, running, done, failed, cancelled }
    let id = UUID()
    let input: URL
    var state = State.waiting
    var stage = "В очереди"
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

    var retryTitle: String {
        output == nil ? "Повторить" : "Повторить суммаризацию"
    }
}
