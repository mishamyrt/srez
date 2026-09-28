import XCTest
@testable import Srez

final class MeetingPipelineTests: XCTestCase {
    func testNamesPairsAndRawToggle() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let summary = MeetingSummary(title: "../План: релиз/осень", markdown: "# План\nГотовим релиз.")
        let first = try MeetingPipeline.save(summary, transcript: "исходный текст", directory: directory, saveRaw: true)
        XCTAssertEqual(first.markdown.lastPathComponent, "План релиз осень.md")
        XCTAssertEqual(first.raw?.lastPathComponent, "План релиз осень.raw.txt")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(first.raw)), "исходный текст")
        let second = try MeetingPipeline.save(summary, transcript: "другой текст", directory: directory, saveRaw: false)
        XCTAssertEqual(second.markdown.lastPathComponent, "План релиз осень (2).md")
        XCTAssertNil(second.raw)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("План релиз осень (2).raw.txt").path))
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(first.raw)), "исходный текст")
        XCTAssertEqual(MeetingPipeline.fileStem("../\n:/"), "Встреча")
        XCTAssertLessThanOrEqual(MeetingPipeline.fileStem(String(repeating: "🧑🏽‍💻", count: 100)).utf8.count, 180)
    }

    func testLongTranscriptSplitsWithoutLosingText() {
        for text in [String(repeating: "Обсудили выпуск. Ответственный — Миша.\n", count: 2_000),
                     String(repeating: "я", count: 50_001), " пробел", ""] {
            let parts = MeetingPipeline.splitTranscript(text)
            XCTAssertEqual(parts.joined(), text)
            XCTAssertTrue(parts.allSatisfy { $0.count <= 24_000 })
        }
        XCTAssertEqual(MeetingPipeline.splitTranscript(" я ", limit: 1).joined(), " я ")
    }

    func testRetrySummarizesCachedTranscriptAndPassesModel() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("fake-codex")
        // A local CLI stand-in exercises stdin, argument boundaries and structured output without a network call.
        let script = #"""
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --output-last-message) shift; result="$1" ;;
                --model) shift; model="$1" ;;
                --config|-c) shift
                    case "$1" in model_reasoning_effort=*) reasoning="$1" ;; esac ;;
            esac
            shift
        done
        [ "$model" = 'test-model' ] || exit 20
        [ "$reasoning" = 'model_reasoning_effort="high"' ] || exit 22
        input=$(cat)
        case "$input" in *Обсудили*) ;; *) exit 21 ;; esac
        printf '%s' '{"title":"План встречи","markdown":"# План встречи\nОбсудили выпуск."}' > "$result"
        """#
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let settings = MeetingSettings(
            outputDirectory: directory, modelDirectory: directory,
            ffmpeg: directory.appendingPathComponent("missing-ffmpeg"), codex: cli,
            codexModel: "test-model", codexReasoning: "high", saveRaw: true
        )
        let transcript = String(repeating: "Обсудили выпуск. ", count: 2_000)
        let output = try await MeetingPipeline.run(
            input: directory.appendingPathComponent("missing-audio.wav"),
            settings: settings, transcript: transcript, update: { _ in }
        )
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(output.raw)), transcript)
        XCTAssertTrue(try String(contentsOf: output.markdown).contains("Обсудили выпуск"))
    }

    func testProcessFailureAndCancellation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await MeetingPipeline.runProcess(URL(fileURLWithPath: "/bin/sh"),
                                                  arguments: ["-c", "echo deliberate-error >&2; exit 7"], directory: directory)
            XCTFail("Expected nonzero exit to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("deliberate-error"))
            XCTAssertTrue(error.localizedDescription.contains("7"))
        }
        let task = Task {
            try await MeetingPipeline.runProcess(URL(fileURLWithPath: "/bin/sleep"),
                                                  arguments: ["30"], directory: directory)
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
