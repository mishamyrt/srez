import Foundation

enum AudioConverter {
    static func withWAV<Result: Sendable>(
        input: URL, executable: URL,
        body: @Sendable (URL) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: executable.path) else {
            throw MeetingError(
                message: "Не найден встроенный ffmpeg. Пересоберите или переустановите Srez."
            )
        }
        let work = fm.temporaryDirectory.appendingPathComponent("Srez-Audio-\(UUID())")
        try fm.createDirectory(
            at: work,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fm.removeItem(at: work) }
        let wav = work.appendingPathComponent("audio.wav")
        try await ProcessRunner.run(executable, arguments: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", input.path,
            "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le",
            wav.path,
        ], directory: work)
        try Task.checkCancellation()
        return try await body(wav)
    }
}
