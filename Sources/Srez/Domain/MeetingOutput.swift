import Foundation

struct MeetingOutput: Sendable {
    let transcript: URL
    var summary: URL?
    var file: URL {
        summary ?? transcript
    }
}
