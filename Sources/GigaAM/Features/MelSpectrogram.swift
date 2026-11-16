import Accelerate
import Foundation

public struct MelSpectrogramConfig: Sendable, Codable, Hashable {
    public let sampleRate: Int
    public let nMels: Int
    public let nFFT: Int
    public let hopLength: Int
    public let winLength: Int
    public let center: Bool

    public init(
        sampleRate: Int = 16000,
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
    private let dft: vDSP_DFT_Setup

    public init(
        config: MelSpectrogramConfig = MelSpectrogramConfig(),
        assetsDirectory: URL
    ) throws {
        guard !config.center else {
            throw GigaAMError
                .notImplemented("MelSpectrogram.center=true is not implemented")
        }

        guard config.nFFT == config.winLength else {
            throw GigaAMError.notImplemented("nFFT != winLength is not implemented")
        }

        self.config = config
        nFreqs = config.nFFT / 2 + 1

        let windowURL = assetsDirectory.appendingPathComponent("hann_window.f32.bin")
        let filterbankURL = assetsDirectory
            .appendingPathComponent("mel_filterbank_mel_freq.f32.bin")

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

        guard let dft = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(config.nFFT), .FORWARD)
        else {
            throw GigaAMError.invalidArguments("Unsupported DFT length: \(config.nFFT)")
        }
        self.dft = dft
    }

    deinit { vDSP_DFT_DestroySetup(dft) }

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

        // Complex DFT keeps the same unnormalized power and first nFFT / 2 + 1 bins.
        var real = [Float](repeating: 0, count: config.nFFT)
        let imag = real
        var realOut = real
        var imagOut = real
        for frameIndex in 0 ..< frameCount {
            let frameOffset = frameIndex * config.hopLength
            for sampleIndex in 0 ..< config.nFFT {
                real[sampleIndex] = samples[frameOffset + sampleIndex] *
                    window[sampleIndex]
            }
            vDSP_DFT_Execute(dft, real, imag, &realOut, &imagOut)
            for freqIndex in 0 ..< nFreqs {
                power[freqIndex * frameCount + frameIndex] =
                    realOut[freqIndex] * realOut[freqIndex] + imagOut[freqIndex] *
                    imagOut[freqIndex]
            }
        }

        var resultFlat = [Float](
            repeating: 0,
            count: config.nMels * frameCount
        )

        // mel_power = filterbank [mel, freq] @ power [freq, frame]
        for melIndex in 0 ..< config.nMels {
            let melOffset = melIndex * nFreqs
            let outputOffset = melIndex * frameCount

            for frameIndex in 0 ..< frameCount {
                var value = Float(0)

                for freqIndex in 0 ..< nFreqs {
                    value += filterbank[melOffset + freqIndex] *
                        power[freqIndex * frameCount + frameIndex]
                }

                let clamped = min(max(value, 1e-9), 1e9)
                resultFlat[outputOffset + frameIndex] = logf(clamped)
            }
        }

        var result = Array(
            repeating: Array(repeating: Float(0), count: frameCount),
            count: config.nMels
        )

        for melIndex in 0 ..< config.nMels {
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

    public func computeFlat(samples: [Float]) throws
        -> (features: [Float], shape: [Int], length: Int)
    {
        let matrix = try compute(samples: samples)
        let frameCount = matrix.first?.count ?? 0

        return (
            features: matrix.flatMap(\.self),
            shape: [1, config.nMels, frameCount],
            length: frameCount
        )
    }

    private static func outputLength(
        sampleCount: Int,
        config: MelSpectrogramConfig
    ) -> Int {
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

        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else {
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

    public static func outputLength(
        sampleCount: Int,
        config: MelSpectrogramConfig = MelSpectrogramConfig()
    ) -> Int {
        if config.center {
            return sampleCount / config.hopLength + 1
        }

        return ((sampleCount - config.winLength) / config.hopLength) + 1
    }
}
