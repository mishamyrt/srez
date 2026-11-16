import Foundation
import GigaAM

struct TranscriptionService: Sendable {
    let modelStore: ModelStore

    init(modelStore: ModelStore = ModelStore()) {
        self.modelStore = modelStore
    }

    func run(
        input: URL, settings: TranscriptionConfiguration, transcript: String? = nil,
        update: @escaping @Sendable (MeetingEvent) async -> Void
    ) async throws -> MeetingOutput {
        try MeetingFileStore.prepareOutputDirectory(settings.outputDirectory)

        let text: String
        if let transcript {
            text = transcript
        } else {
            await update(.stage(.convertingAudio))
            text = try await AudioConverter.withWAV(
                input: input,
                executable: settings.ffmpeg
            ) { wav in
                let recognizer = try await modelStore.load(update: update)
                await update(.stage(.recognizing))
                return try await recognizer.transcribe(url: wav) { value in
                    await update(.progress(value))
                }.text
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingError(
                    message: "Речь не распознана. Проверьте, что в файле есть русская речь."
                )
            }
            await update(.transcript(text))
        }

        try Task.checkCancellation()
        await update(.stage(.savingTranscript))
        let file = try MeetingFileStore.saveFile(
            text,
            title: input.deletingPathExtension().lastPathComponent,
            extension: "raw.txt",
            directory: settings.outputDirectory
        )
        return MeetingOutput(transcript: file)
    }

    func unload() async {
        await modelStore.unload()
    }
}
