import Foundation

struct MeetingError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}
