import Foundation

struct MeetingSettings: Sendable {
    let outputDirectory: URL
    let ffmpeg: URL
    let provider: ProviderConfiguration
    var transcription: TranscriptionConfiguration {
        TranscriptionConfiguration(outputDirectory: outputDirectory, ffmpeg: ffmpeg)
    }
}

struct TranscriptionConfiguration: Sendable {
    let outputDirectory: URL
    let ffmpeg: URL
}
