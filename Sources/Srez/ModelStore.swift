import CryptoKit
import Foundation
import GigaAM

actor ModelStore {
    private let prepareModel: @Sendable (@escaping @Sendable (MeetingEvent) async
        -> Void) async throws -> URL
    private var recognizer: GigaAMRecognizer?

    init(prepare: @escaping @Sendable (@escaping @Sendable (MeetingEvent) async
            -> Void) async throws -> URL = {
        try await ModelStore.prepare(update: $0)
    }) {
        prepareModel = prepare
    }

    /// One transcription worker owns this store; unload only after its queue drains.
    func load(update: @escaping @Sendable (MeetingEvent) async -> Void) async throws
        -> GigaAMRecognizer
    {
        try Task.checkCancellation()
        if let recognizer {
            return recognizer
        }
        let directory = try await prepareModel(update)
        try Task.checkCancellation()
        await update(.stage("Загрузка модели…"))
        let loaded = try GigaAMRecognizer(configuration: .init(modelDirectory: directory))
        try Task.checkCancellation()
        recognizer = loaded
        return loaded
    }

    func unload() {
        recognizer = nil
    }

    /// Pin the bundle and checksums together so upstream changes cannot mix model
    /// versions.
    private static let source =
        URL(
            string: "https://huggingface.co/kruatech/gigaam-v3-mlx/resolve/2478743c1c449a468ee163bc3030170d1a2e81fb/"
        )!
    private static let files = [
        (
            "manifest.json",
            "993c538b6dceffb7b018c633a7cc8e4034e7ca975b5c27ecc8ecd679fa574d16"
        ),
        (
            "tokenizer.model",
            "828c12c991019eef952a960661f25a92d6ad279591e2ea466b4aeddf1d20a18a"
        ),
        (
            "tokenizer_vocab.json",
            "84e15355333a8eb460b2f899947e9976b8c036f4dd086002e43b987ddf4cc606"
        ),
        (
            "hann_window.f32.bin",
            "834a6744851a775dbb1831e9e17f0f702599b4d52c1d97d7638b3f170824419f"
        ),
        (
            "mel_filterbank_mel_freq.f32.bin",
            "e9425a25940359fb85efeaf6651f81679971a1c46bec1af3aba943ec8a5fd793"
        ),
        (
            "weights.fp16.safetensors",
            "2ff6d955a61003e0d3cb2155be36c14aa3df69c879713f30880ddd07d71fde21"
        ),
    ]

    static func prepare(update: @escaping @Sendable (MeetingEvent) async
        -> Void) async throws -> URL
    {
        let fm = FileManager.default
        let directory = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Srez/Models/GigaAM-v3-MLX", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        await update(.stage("Проверка модели…"))
        for (index, file) in files.enumerated() {
            try await installFile(named: file.0, checksum: file.1, in: directory) { url in
                await update(
                    .stage("Скачивание модели: файл \(index + 1) из \(files.count)…")
                )
                return try await URLSession.shared.download(from: url)
            }
        }
        return directory
    }

    static func installFile(
        named name: String, checksum: String, in directory: URL,
        download: (URL) async throws -> (URL, URLResponse)
    ) async throws {
        try Task.checkCancellation()
        let fm = FileManager.default
        let destination = directory.appendingPathComponent(name)
        if try matchesChecksum(destination, checksum: checksum) {
            return
        }
        do {
            let (
                temporary,
                response
            ) = try await download(source.appendingPathComponent(name))
            defer { try? fm.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200
            else {
                throw MeetingError(
                    message: "Не удалось скачать модель. Проверьте подключение к интернету и повторите попытку."
                )
            }
            guard try matchesChecksum(temporary, checksum: checksum) else {
                throw MeetingError(
                    message: "Файл модели повреждён. Повторите скачивание."
                )
            }
            try Task.checkCancellation()
            if fm
                .fileExists(atPath: destination.path)
            {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: temporary, to: destination)
        } catch {
            // URLSession reports cancellation as URLError; the queue expects
            // CancellationError.
            try Task.checkCancellation()
            throw error
        }
    }

    private static func matchesChecksum(_ url: URL, checksum: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1_048_576),
                  !chunk.isEmpty else { break }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == checksum
    }
}
