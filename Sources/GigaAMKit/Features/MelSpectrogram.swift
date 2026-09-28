import Foundation

public struct MelSpectrogramConfig: Sendable, Codable, Hashable {
    public let sampleRate: Int
    public let nMels: Int
    public let nFFT: Int
    public let hopLength: Int
    public let winLength: Int
    public let center: Bool

    public init(
        sampleRate: Int = 16_000,
        nMels: Int = 64,
        nFFT: Int = 320,
        hopLength: Int = 160,
        winLength: Int = 320,
        center: Bool = false
    ) {
        self.sampleRate = sampleRate
        self.nMels = nMels
        self.nFFT = nFFT
        self.hopLength = hopLength
        self.winLength = winLength
        self.center = center
    }
}

public final class MelSpectrogramProcessor: @unchecked Sendable {
    public let config: MelSpectrogramConfig
    public let nFreqs: Int

    private let window: [Float]
    private let filterbank: [Float]
    private let cosTable: [Float]
    private let sinTable: [Float]

    public init(
        config: MelSpectrogramConfig = MelSpectrogramConfig(),
        assetsDirectory: URL
    ) throws {
        guard !config.center else {
            throw GigaAMError.notImplemented("MelSpectrogram.center=true is not implemented")
        }

        guard config.nFFT == config.winLength else {
            throw GigaAMError.notImplemented("nFFT != winLength is not implemented")
        }

        self.config = config
        self.nFreqs = config.nFFT / 2 + 1

        let windowURL = assetsDirectory.appendingPathComponent("hann_window.f32.bin")
        let filterbankURL = assetsDirectory.appendingPathComponent("mel_filterbank_mel_freq.f32.bin")

        let window = try Self.readFloat32Binary(windowURL)
        let filterbank = try Self.readFloat32Binary(filterbankURL)

        guard window.count == config.winLength else {
            throw GigaAMError.invalidArguments(
                "Invalid hann window size: \(window.count), expected \(config.winLength)"
            )
        }

        guard filterbank.count == config.nMels * nFreqs else {
            throw GigaAMError.invalidArguments(
                "Invalid mel filterbank size: \(filterbank.count), expected \(config.nMels * nFreqs)"
            )
        }

        self.window = window
        self.filterbank = filterbank

        let tables = Self.makeDFTTables(nFFT: config.nFFT, nFreqs: nFreqs)
        self.cosTable = tables.cos
        self.sinTable = tables.sin
    }

    public func compute(samples: [Float]) throws -> [[Float]] {
        guard samples.count >= config.winLength else {
            throw GigaAMError.invalidArguments(
                "Audio is shorter than winLength: samples=\(samples.count), winLength=\(config.winLength)"
            )
        }

        let frameCount = Self.outputLength(sampleCount: samples.count, config: config)

        var power = [Float](
            repeating: 0,
            count: nFreqs * frameCount
        )

        // STFT power, layout [freq, frame], matching torch.stft(...).abs().pow(2).
        for frameIndex in 0..<frameCount {
            let frameOffset = frameIndex * config.hopLength

            for freqIndex in 0..<nFreqs {
                let tableOffset = freqIndex * config.nFFT

                var real = Float(0)
                var imag = Float(0)

                for n in 0..<config.nFFT {
                    let sample = samples[frameOffset + n] * window[n]
                    real += sample * cosTable[tableOffset + n]
                    imag -= sample * sinTable[tableOffset + n]
                }

                power[freqIndex * frameCount + frameIndex] = real * real + imag * imag
            }
        }

        var resultFlat = [Float](
            repeating: 0,
            count: config.nMels * frameCount
        )

        // mel_power = filterbank [mel, freq] @ power [freq, frame]
        for melIndex in 0..<config.nMels {
            let melOffset = melIndex * nFreqs
            let outputOffset = melIndex * frameCount

            for frameIndex in 0..<frameCount {
                var value = Float(0)

                for freqIndex in 0..<nFreqs {
                    value += filterbank[melOffset + freqIndex] * power[freqIndex * frameCount + frameIndex]
                }

                let clamped = min(max(value, 1e-9), 1e9)
                resultFlat[outputOffset + frameIndex] = logf(clamped)
            }
        }

        var result = Array(
            repeating: Array(repeating: Float(0), count: frameCount),
            count: config.nMels
        )

        for melIndex in 0..<config.nMels {
            let offset = melIndex * frameCount

            result[melIndex].withUnsafeMutableBufferPointer { destination in
                resultFlat.withUnsafeBufferPointer { source in
                    destination.baseAddress!.update(
                        from: source.baseAddress!.advanced(by: offset),
                        count: frameCount
                    )
                }
            }
        }

        return result
    }

    public func computeFlat(samples: [Float]) throws -> (features: [Float], shape: [Int], length: Int) {
        let matrix = try compute(samples: samples)
        let frameCount = matrix.first?.count ?? 0

        return (
            features: matrix.flatMap { $0 },
            shape: [1, config.nMels, frameCount],
            length: frameCount
        )
    }

    private struct DFTTables {
        let cos: [Float]
        let sin: [Float]
    }

    private static func makeDFTTables(nFFT: Int, nFreqs: Int) -> DFTTables {
        var cosTable = [Float](repeating: 0, count: nFreqs * nFFT)
        var sinTable = [Float](repeating: 0, count: nFreqs * nFFT)

        let twoPi = 2.0 * Double.pi

        for freqIndex in 0..<nFreqs {
            let offset = freqIndex * nFFT

            for n in 0..<nFFT {
                let angle = twoPi * Double(freqIndex * n) / Double(nFFT)
                cosTable[offset + n] = Float(cos(angle))
                sinTable[offset + n] = Float(sin(angle))
            }
        }

        return DFTTables(cos: cosTable, sin: sinTable)
    }

    private static func outputLength(sampleCount: Int, config: MelSpectrogramConfig) -> Int {
        if config.center {
            return sampleCount / config.hopLength + 1
        }

        return ((sampleCount - config.winLength) / config.hopLength) + 1
    }

    private static func readFloat32Binary(_ url: URL) throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GigaAMError.fileNotFound(url.path)
        }

        let data = try Data(contentsOf: url)

        guard data.count % MemoryLayout<Float>.size == 0 else {
            throw GigaAMError.invalidArguments(
                "Float32 binary size is not divisible by 4: \(url.path)"
            )
        }

        var values = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)

        _ = values.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination)
        }

        return values
    }
}

public enum MelSpectrogram {
    public static func compute(
        samples: [Float],
        config: MelSpectrogramConfig = MelSpectrogramConfig(),
        assetsDirectory: URL
    ) throws -> [[Float]] {
        let processor = try MelSpectrogramProcessor(
            config: config,
            assetsDirectory: assetsDirectory
        )

        return try processor.compute(samples: samples)
    }

    public static func outputLength(sampleCount: Int, config: MelSpectrogramConfig = MelSpectrogramConfig()) -> Int {
        if config.center {
            return sampleCount / config.hopLength + 1
        }

        return ((sampleCount - config.winLength) / config.hopLength) + 1
    }
}
