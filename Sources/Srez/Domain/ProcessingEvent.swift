import Foundation

enum MeetingEvent: Sendable {
    case stage(String)
    case progress(Double)
    case transcript(String)
}
