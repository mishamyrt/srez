import AVFoundation
import XCTest
@testable import GigaAMKit

final class AudioLoaderTests: XCTestCase {
    func testStreamingKeepsSamplesAndMergesShortTail() throws {
        for count in [320, 320_000, 320_001, 640_319, 640_320] {
            let samples = (0..<count).map { Float($0 % 100) / 100 }
            let url = try audioFile(samples: samples)
            defer { try? FileManager.default.removeItem(at: url) }
            let reader = try AudioLoader.Reader(url: url, targetSampleRate: 16_000)
            var chunks: [[Float]] = []
            while let chunk = try reader.nextChunk(size: 320_000) { chunks.append(chunk) }
            XCTAssertEqual(chunks.flatMap { $0 }, samples)
            XCTAssertEqual(chunks.map(\.count), GigaAMRecognizer.chunkRanges(sampleCount: count, chunkSize: 320_000).map(\.count))
            XCTAssertNil(try reader.nextChunk(size: 320_000))
        }
    }

    func testStreamingResamplesAndMixesStereo() throws {
        for (sampleRate, channels, expected) in [(16_000.0, 2, Float(0.5)), (48_000.0, 1, Float(0.25))] {
            let url = try audioFile(samples: [Float](repeating: 0.25, count: Int(sampleRate)),
                                    sampleRate: sampleRate, channels: AVAudioChannelCount(channels), channelOffset: 0.5)
            defer { try? FileManager.default.removeItem(at: url) }
            let reader = try AudioLoader.Reader(url: url, targetSampleRate: 16_000)
            var samples: [Float] = []
            while let chunk = try reader.nextChunk(size: 4096) { samples += chunk }
            XCTAssertEqual(samples.count, 16_000)
            // Skip the resampler's edge transient.
            XCTAssertTrue(samples[100..<15_900].allSatisfy { abs($0 - expected) < 0.001 })
        }
    }

    func testStreamingCancellationAndEmptyInput() async throws {
        let url = try audioFile(samples: [])
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try AudioLoader.Reader(url: url, targetSampleRate: 16_000)
        XCTAssertNil(try reader.nextChunk(size: 320_000))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let reader = try AudioLoader.Reader(url: url, targetSampleRate: 16_000)
            return try reader.nextChunk(size: 320_000)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func audioFile(samples: [Float], sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1, channelOffset: Float = 0) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                               channels: channels, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        if !samples.isEmpty {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for channel in 0..<Int(channels) {
                for frame in samples.indices {
                    buffer.floatChannelData![channel][frame] = samples[frame] + Float(channel) * channelOffset
                }
            }
            try file.write(from: buffer)
        }
        return url
    }
}
