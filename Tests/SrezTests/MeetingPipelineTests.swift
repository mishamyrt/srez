import XCTest
@testable import Srez

final class MeetingPipelineTests: XCTestCase {
    func testSummaryNamesAndTranscriptPreservation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("recording.raw.txt")
        try "исходный текст".write(to: transcript, atomically: true, encoding: .utf8)
        let summary = MeetingSummary(title: "../План: релиз/осень", markdown: "# План\nГотовим релиз.")
        let first = try MeetingPipeline.save(summary, transcript: transcript, directory: directory)
        XCTAssertEqual(first.summary?.lastPathComponent, "План релиз осень.md")
        XCTAssertEqual(first.transcript, transcript)
        XCTAssertEqual(first.file, first.summary)
        let second = try MeetingPipeline.save(summary, transcript: transcript, directory: directory)
        XCTAssertEqual(second.summary?.lastPathComponent, "План релиз осень (2).md")
        XCTAssertEqual(try String(contentsOf: first.transcript), "исходный текст")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(first.summary)), summary.markdown + "\n")
        XCTAssertEqual(MeetingPipeline.fileStem("../\n:/"), "Встреча")
        XCTAssertLessThanOrEqual(MeetingPipeline.fileStem(String(repeating: "🧑🏽‍💻", count: 100)).utf8.count, 180)
    }

    func testTranscriptionSavesWithoutCodexAndDoesNotOverwrite() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = MeetingSettings(
            outputDirectory: directory, ffmpeg: directory.appendingPathComponent("missing-ffmpeg"),
            codex: directory.appendingPathComponent("missing-codex"), codexModel: "", codexReasoning: "medium"
        )
        for (index, text) in ["исходный текст", "вторая запись"].enumerated() {
            let output = try await MeetingPipeline.run(
                input: directory.appendingPathComponent("Запись.mp3"), settings: settings, transcript: text
            ) { event in
                if case .stage(let stage) = event { XCTAssertFalse(stage.contains("Суммаризация")) }
            }
            XCTAssertNil(output.summary)
            XCTAssertEqual(output.file, output.transcript)
            XCTAssertEqual(output.transcript.lastPathComponent, index == 0 ? "Запись.raw.txt" : "Запись (2).raw.txt")
            XCTAssertEqual(try String(contentsOf: output.transcript), text)
        }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("Запись.raw.txt")), "исходный текст")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
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

    func testSummarizesSavedTranscriptAndPassesModel() async throws {
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
            outputDirectory: directory,
            ffmpeg: directory.appendingPathComponent("missing-ffmpeg"), codex: cli,
            codexModel: "test-model", codexReasoning: "high"
        )
        let transcript = String(repeating: "Обсудили выпуск. ", count: 2_000)
        let transcription = try await MeetingPipeline.run(
            input: directory.appendingPathComponent("missing-audio.wav"),
            settings: settings, transcript: transcript, update: { _ in }
        )
        XCTAssertNil(transcription.summary)
        let output = try await MeetingPipeline.summarize(transcription, settings: settings, update: { _ in })
        XCTAssertEqual(output.transcript, transcription.transcript)
        XCTAssertEqual(try String(contentsOf: output.transcript), transcript)
        XCTAssertTrue(try String(contentsOf: XCTUnwrap(output.summary)).contains("Обсудили выпуск"))
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
