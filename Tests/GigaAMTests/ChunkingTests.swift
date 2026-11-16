import XCTest
@testable import GigaAM

final class ChunkingTests: XCTestCase {
    func testLongAudioStaysWithinChunksAndKeepsFinalSamples() throws {
        let chunkSize = try GigaAMRecognizer.chunkSize(duration: 20, sampleRate: 16_000)
        let ranges = GigaAMRecognizer.chunkRanges(sampleCount: 45_523_736, chunkSize: chunkSize)

        XCTAssertEqual(ranges.count, 143)
        XCTAssertEqual(ranges.first, 0..<320_000)
        XCTAssertEqual(ranges.last, 45_440_000..<45_523_736)
        XCTAssertTrue(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        XCTAssertTrue(ranges.allSatisfy { $0.count <= chunkSize })

        XCTAssertEqual(
            GigaAMRecognizer.chunkRanges(sampleCount: 320_001, chunkSize: chunkSize),
            [0..<320_001]
        )
        XCTAssertThrowsError(try GigaAMRecognizer.chunkSize(duration: 0, sampleRate: 16_000))
    }
}
