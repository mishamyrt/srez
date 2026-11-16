import XCTest
@testable import GigaAMKit

final class MelSpectrogramTests: XCTestCase {
    func testAcceleratedMelMatchesDirectDFT() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = MelSpectrogramConfig(nMels: 4)
        let window = (0..<320).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 320)) }
        let filters = (0..<(4 * 161)).map { Float($0 % 17 + 1) / 17 }
        try window.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent("hann_window.f32.bin")) }
        try filters.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent("mel_filterbank_mel_freq.f32.bin")) }
        let processor = try MelSpectrogramProcessor(config: config, assetsDirectory: directory)
        let noise = (0..<960).map { Float(($0 * 71 + 13) % 101) / 101 - 0.5 }
        let tone = (0..<960).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) }
        let impulse = [Float(1)] + [Float](repeating: 0, count: 959)
        for samples in [[Float](repeating: 0, count: 960), noise, tone, impulse] {
            let actual = try processor.computeFlat(samples: samples)
            let expected = directMel(samples: samples, window: window, filters: filters)
            XCTAssertEqual(actual.shape, [1, 4, 5])
            XCTAssertEqual(actual.length, 5)
            for (value, reference) in zip(actual.features, expected) {
                XCTAssertEqual(value, reference, accuracy: 0.001)
            }
        }
        XCTAssertThrowsError(try processor.computeFlat(samples: [Float](repeating: 0, count: 319)))
    }

    private func directMel(samples: [Float], window: [Float], filters: [Float]) -> [Float] {
        let frames = (samples.count - 320) / 160 + 1
        var power = [Float](repeating: 0, count: 161 * frames)
        for frame in 0..<frames {
            for frequency in 0..<161 {
                var real: Float = 0
                var imag: Float = 0
                for n in 0..<320 {
                    let angle = 2 * Double.pi * Double(frequency * n) / 320
                    let value = samples[frame * 160 + n] * window[n]
                    real += value * Float(cos(angle))
                    imag -= value * Float(sin(angle))
                }
                power[frequency * frames + frame] = real * real + imag * imag
            }
        }
        var result: [Float] = []
        for mel in 0..<4 {
            for frame in 0..<frames {
                var value: Float = 0
                for frequency in 0..<161 { value += filters[mel * 161 + frequency] * power[frequency * frames + frame] }
                result.append(logf(min(max(value, 1e-9), 1e9)))
            }
        }
        return result
    }
}
