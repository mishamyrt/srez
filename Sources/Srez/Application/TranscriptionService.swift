import Foundation
import GigaAM

struct TranscriptionService: Sendable {
    let modelStore: ModelStore

    init(modelStore: ModelStore = ModelStore()) {
        self.modelStore = modelStore
    }

    func run(
        input: URL, settings: MeetingSettings, transcript: String? = nil,
        update: @escaping @Sendable (MeetingEvent) async -> Void
    ) async throws -> MeetingOutput {
        let fm = FileManager.default
        try MeetingFileStore.prepareOutputDirectory(settings.outputDirectory)
        let work = fm.temporaryDirectory
            .appendingPathComponent("GigaAM-\(UUID().uuidString)")
        try fm.createDirectory(
            at: work,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fm.removeItem(at: work) }

        let text: String
        if let transcript {
            text = transcript
        } else {
            guard fm.isExecutableFile(atPath: settings.ffmpeg.path) else {
                throw MeetingError(
                    message: "Не найден встроенный ffmpeg. Пересоберите или переустановите Srez."
                )
            }
            await update(.stage("Преобразование в WAV…"))
            let wav = work.appendingPathComponent("audio.wav")
            try await ProcessRunner.run(settings.ffmpeg, arguments: [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", input.path,
                "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
                wav.path,
            ], directory: work)
            let recognizer = try await modelStore.load(update: update)
            await update(.stage("Распознавание речи…"))
            text = try await recognizer.transcribe(url: wav) { value in
                await update(.progress(value))
            }.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingError(
                    message: "Речь не распознана. Проверьте, что в файле есть русская речь."
                )
            }
            await update(.transcript(text))
        }

        try Task.checkCancellation()
        await update(.stage("Сохранение расшифровки…"))
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
