import Foundation

public final class GigaAMRecognizer: @unchecked Sendable {
    public let configuration: GigaAMConfiguration
    public let bundle: ModelBundle
    private let model: GigaAMProModel

    public init(configuration: GigaAMConfiguration = .pro) throws {
        self.configuration = configuration
        self.bundle = try ModelBundle.load(configuration: configuration)
        self.model = try GigaAMProModel(bundle: bundle)
    }

    public func info() -> String {
        var weightsInfo = "not attached yet"

        if let weightsURL = bundle.weightsURL {
            do {
                let index = try SafetensorsIndex.loadHeader(url: weightsURL)
                let params = index.totalParameterCount
                weightsInfo = """
                \(weightsURL.path)
                tensors: \(index.tensorCount)
                params: \(params)
                """
            } catch {
                weightsInfo = "\(weightsURL.path)\nfailed to read safetensors header: \(error.localizedDescription)"
            }
        }

        return """
        \(bundle.manifest.name)
        source: \(bundle.manifest.sourceModel) @ \(bundle.manifest.sourceRevision)
        architecture: \(bundle.manifest.architecture)
        precision: \(bundle.manifest.precision)
        runtime: \(bundle.manifest.runtime)
        sample_rate: \(bundle.manifest.sampleRate)
        mlx: \(MLXEnvironment.description)
        weights: \(weightsInfo)
        tokenizer: \(bundle.tokenizerURL?.path ?? "not attached yet")
        """
    }

    public func transcribe(
        url: URL,
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> GigaAMResult {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GigaAMError.fileNotFound(url.path)
        }

        let audio = try AudioLoader.loadMonoFloat32(
            url: url,
            targetSampleRate: bundle.manifest.sampleRate
        )

        return try await transcribe(samples: audio.samples, sampleRate: audio.sampleRate, progress: progress)
    }



    public func transcribeTimed(
        features: [Float],
        shape: [Int],
        length: Int
    ) throws -> GigaAMProTimedTranscription {
        try model.transcribeTimed(
            features: features,
            shape: shape,
            length: length
        )
    }

    public func transcribe(
        features: [Float],
        shape: [Int],
        length: Int
    ) throws -> GigaAMProTranscription {
        try model.transcribe(
            features: features,
            shape: shape,
            length: length
        )
    }

    public func transcribe(
        samples: [Float],
        sampleRate: Int,
        progress: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> GigaAMResult {
        try Task.checkCancellation()
        await progress?(0)
        let chunkSize = try Self.chunkSize(
            duration: configuration.chunkDuration,
            sampleRate: sampleRate
        )
        let duration = TimeInterval(samples.count) / TimeInterval(sampleRate)

        if samples.count <= chunkSize {
            let transcription = try model.transcribe(samples: samples, sampleRate: sampleRate)
            try Task.checkCancellation()
            await progress?(1)
            return GigaAMResult(
                text: transcription.text,
                segments: [],
                words: transcription.words,
                duration: duration
            )
        }

        var text: [String] = []
        var words: [GigaAMProWord] = []
        for range in Self.chunkRanges(sampleCount: samples.count, chunkSize: chunkSize) {
            try Task.checkCancellation()
            let transcription = try model.transcribe(
                samples: Array(samples[range]),
                sampleRate: sampleRate
            )
            if !transcription.text.isEmpty { text.append(transcription.text) }

            let offset = TimeInterval(range.lowerBound) / TimeInterval(sampleRate)
            words += transcription.words.map {
                GigaAMProWord(text: $0.text, start: $0.start + offset, end: $0.end + offset)
            }
            try Task.checkCancellation()
            await progress?(Double(range.upperBound) / Double(samples.count))
        }

        return GigaAMResult(
            text: text.joined(separator: " "),
            segments: [],
            words: words,
            duration: duration
        )
    }

    static func chunkSize(duration: TimeInterval, sampleRate: Int) throws -> Int {
        let count = duration * Double(sampleRate)
        guard sampleRate > 0, count.isFinite, count >= 320, count < Double(Int.max) else {
            throw GigaAMError.invalidArguments("chunkDuration must be at least 320 samples")
        }
        return Int(count)
    }

    static func chunkRanges(sampleCount: Int, chunkSize: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        while start < sampleCount {
            var end = start + min(chunkSize, sampleCount - start)
            if sampleCount - end < 320 { end = sampleCount }
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }
}
