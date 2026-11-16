import XCTest
@testable import GigaAM

/// Tests for `GigaAMProModel.buildWords` — grouping the RNNT emission trace
/// into timestamped words. Pure function, no model files required.
final class BuildWordsTests: XCTestCase {

    /// 40 ms — the production value (10 ms mel hop × 4 conformer subsampling).
    private let frameDuration: TimeInterval = 0.04

    private let vocab: [Int: String] = [
        1: "▁при",
        2: "вет",
        3: "▁мир",
        4: ",",
        5: "<unk>",
        6: "!",
    ]

    private func step(_ token: Int, frame: Int, blank: Bool = false) -> RNNTGreedyStepTrace {
        RNNTGreedyStepTrace(
            timeIndex: frame,
            symbolIndex: 0,
            token: token,
            logProb: 0,
            isBlank: blank
        )
    }

    private func words(_ steps: [RNNTGreedyStepTrace]) -> [GigaAMProWord] {
        GigaAMProModel.buildWords(
            steps: steps,
            piece: { self.vocab[$0] },
            frameDuration: frameDuration
        )
    }

    func testGroupsSubwordsIntoWordsAtBoundaries() {
        let result = words([step(1, frame: 0), step(2, frame: 1), step(3, frame: 5)])

        XCTAssertEqual(result.map(\.text), ["привет", "мир"])
    }

    func testWordTimesSpanFirstToLastTokenFrame() {
        let result = words([step(1, frame: 0), step(2, frame: 3), step(3, frame: 10)])

        XCTAssertEqual(result[0].start, 0.0, accuracy: 1e-9)
        // end = (last token frame + 1) × frameDuration
        XCTAssertEqual(result[0].end, 0.16, accuracy: 1e-9)
        XCTAssertEqual(result[1].start, 0.4, accuracy: 1e-9)
        XCTAssertEqual(result[1].end, 0.44, accuracy: 1e-9)
    }

    func testPunctuationAttachesToPrecedingWord() {
        let result = words([step(3, frame: 0), step(4, frame: 1)])

        XCTAssertEqual(result.map(\.text), ["мир,"])
    }

    func testUnkIsAStandaloneWord() {
        let result = words([step(1, frame: 0), step(5, frame: 2), step(3, frame: 4)])

        XCTAssertEqual(result.map(\.text), ["при", "⁇", "мир"])
        XCTAssertEqual(result[1].start, 0.08, accuracy: 1e-9)
        XCTAssertEqual(result[1].end, 0.12, accuracy: 1e-9)
    }

    func testBlankStepsAndControlTokensAreSkipped() {
        let result = words([
            step(1, frame: 0),
            step(99, frame: 1, blank: true),   // blank emission
            step(2, frame: 2),
            step(1000, frame: 3),              // not in vocab -> control token
        ])

        XCTAssertEqual(result.map(\.text), ["привет"])
        XCTAssertEqual(result[0].end, 0.12, accuracy: 1e-9)
    }

    func testLeadingContinuationTokenStartsAWord() {
        // A trace can begin mid-word (e.g. after chunking); the piece has no "▁".
        let result = words([step(2, frame: 0), step(3, frame: 2)])

        XCTAssertEqual(result.map(\.text), ["вет", "мир"])
    }

    func testEmptyTraceProducesNoWords() {
        XCTAssertTrue(words([]).isEmpty)
        XCTAssertTrue(words([step(99, frame: 0, blank: true)]).isEmpty)
    }
}
