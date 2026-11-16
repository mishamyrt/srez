import Foundation
import AVFoundation

public struct AudioBuffer: Sendable {
    public let samples: [Float]
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public enum AudioLoader {
    public static func loadMonoFloat32(
        url: URL,
        targetSampleRate: Int = 16_000
    ) throws -> AudioBuffer {
        let reader = try Reader(url: url, targetSampleRate: targetSampleRate)
        var samples: [Float] = []
        while let chunk = try reader.nextChunk(size: 4096) {
            samples.append(contentsOf: chunk)
        }
        return AudioBuffer(samples: samples, sampleRate: targetSampleRate)
    }

    final class Reader {
        let estimatedSampleCount: Int
        private let file: AVAudioFile
        private let converter: AVAudioConverter?
        private let inputBuffer: AVAudioPCMBuffer
        private var pending: [Float]?
        private var finished = false

        init(url: URL, targetSampleRate: Int) throws {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw GigaAMError.fileNotFound(url.path)
            }
            guard targetSampleRate > 0 else {
                throw GigaAMError.invalidArguments("Sample rate must be positive")
            }
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            estimatedSampleCount = Int(ceil(Double(file.length) * Double(targetSampleRate) / file.processingFormat.sampleRate))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
                throw GigaAMError.invalidArguments("Failed to allocate source audio buffer")
            }
            inputBuffer = buffer
            if file.processingFormat.sampleRate == Double(targetSampleRate) {
                converter = nil
            } else {
                guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: Double(targetSampleRate), channels: 1, interleaved: false),
                      let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
                    throw GigaAMError.invalidArguments("Failed to create audio converter")
                }
                self.converter = converter
            }
        }

        func nextChunk(size: Int) throws -> [Float]? {
            try Task.checkCancellation()
            guard size >= 320 else {
                throw GigaAMError.invalidArguments("Audio chunks must contain at least 320 samples")
            }
            guard !finished else { return nil }
            var chunk = try pending ?? read(upToCount: size)
            let next = try read(upToCount: size)
            if next.count < 320 {
                chunk.append(contentsOf: next)
                pending = nil
                finished = true
            } else {
                pending = next
            }
            return chunk.isEmpty ? nil : chunk
        }

        private func read(upToCount count: Int) throws -> [Float] {
            var samples: [Float] = []
            while samples.count < count {
                try Task.checkCancellation()
                let part = try readBuffer(upToCount: count - samples.count)
                if part.isEmpty { break }
                samples.append(contentsOf: part)
            }
            return samples
        }

        private func readBuffer(upToCount count: Int) throws -> [Float] {
            guard count > 0, count <= Int(UInt32.max) else {
                throw GigaAMError.invalidArguments("Invalid audio chunk size: \(count)")
            }
            let format = converter?.outputFormat ?? file.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                throw GigaAMError.invalidArguments("Failed to allocate output audio buffer")
            }
            if let converter {
                var readError: Error?
                var conversionError: NSError?
                let status = converter.convert(to: buffer, error: &conversionError) { [self] requested, status in
                    do {
                        try Task.checkCancellation()
                        guard file.framePosition < file.length else {
                            status.pointee = .endOfStream
                            return nil
                        }
                        let frames = min(AVAudioFramePosition(min(requested, inputBuffer.frameCapacity)),
                                         file.length - file.framePosition)
                        try file.read(into: inputBuffer, frameCount: AVAudioFrameCount(frames))
                        status.pointee = inputBuffer.frameLength == 0 ? .endOfStream : .haveData
                        return inputBuffer.frameLength == 0 ? nil : inputBuffer
                    } catch {
                        readError = error
                        status.pointee = .endOfStream
                        return nil
                    }
                }
                if let readError { throw readError }
                if let conversionError { throw conversionError }
                guard status != .error else {
                    throw GigaAMError.invalidArguments("Audio conversion failed")
                }
            } else {
                let frames = min(AVAudioFramePosition(count), file.length - file.framePosition)
                if frames > 0 { try file.read(into: buffer, frameCount: AVAudioFrameCount(frames)) }
            }
            guard let channels = buffer.floatChannelData else {
                throw GigaAMError.invalidArguments("Audio has no Float32 channel data")
            }
            let frames = Int(buffer.frameLength)
            let channelCount = Int(format.channelCount)
            if channelCount == 1 {
                return Array(UnsafeBufferPointer(start: channels[0], count: frames))
            }
            var samples = [Float](repeating: 0, count: frames)
            for channel in 0..<channelCount {
                for frame in 0..<frames { samples[frame] += channels[channel][frame] / Float(channelCount) }
            }
            return samples
        }
    }
}
