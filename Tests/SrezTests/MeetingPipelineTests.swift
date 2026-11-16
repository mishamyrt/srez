import XCTest
@testable import Srez

final class MeetingPipelineTests: XCTestCase {
    func testCombinesTranscriptsWithoutOverwritingSourcesOrPreviousResults() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let texts = ["Первая запись.\n", "Вторая запись."]
        let outputs = try texts.enumerated().map { index, text in
            let transcript = directory.appendingPathComponent("\(index).raw.txt")
            try text.write(to: transcript, atomically: true, encoding: .utf8)
            return MeetingOutput(transcript: transcript)
        }
        let results = directory.appendingPathComponent("results")
        let first = try MeetingFileStore.combineTranscripts(outputs, directory: results)
        let second = try MeetingFileStore.combineTranscripts(outputs, directory: results)
        XCTAssertNil(first.summary)
        XCTAssertNotEqual(first.transcript, second.transcript)
        for output in [first, second] {
            XCTAssertEqual(try String(contentsOf: output.transcript), texts.joined(separator: "\n\n"))
        }
        XCTAssertEqual(try outputs.map { try String(contentsOf: $0.transcript) }, texts)
    }

    func testCombiningBlankOrMissingTranscriptDoesNotSavePartialText() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = directory.appendingPathComponent("valid.raw.txt")
        let blank = directory.appendingPathComponent("blank.raw.txt")
        try "Исходный текст.".write(to: valid, atomically: true, encoding: .utf8)
        try " \n ".write(to: blank, atomically: true, encoding: .utf8)
        let results = directory.appendingPathComponent("results")
        for invalid in [blank, directory.appendingPathComponent("missing.raw.txt")] {
            XCTAssertThrowsError(try MeetingFileStore.combineTranscripts(
                [MeetingOutput(transcript: valid), MeetingOutput(transcript: invalid)], directory: results
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: results.path))
        }
        XCTAssertEqual(try String(contentsOf: valid), "Исходный текст.")
    }

    func testSummaryNamesAndTranscriptPreservation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("recording.raw.txt")
        try "исходный текст".write(to: transcript, atomically: true, encoding: .utf8)
        let summary = MeetingSummary(title: "../План: релиз/осень", meetingType: .project,
                                     summary: [.init(text: "Готовим релиз.", sourceIDs: ["p1s1"])])
        let first = try MeetingFileStore.save(summary, transcript: transcript, directory: directory)
        XCTAssertEqual(first.summary?.lastPathComponent, "План релиз осень.md")
        XCTAssertEqual(first.transcript, transcript)
        XCTAssertEqual(first.file, first.summary)
        let second = try MeetingFileStore.save(summary, transcript: transcript, directory: directory)
        XCTAssertEqual(second.summary?.lastPathComponent, "План релиз осень (2).md")
        XCTAssertEqual(try String(contentsOf: first.transcript), "исходный текст")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(first.summary)), summary.markdown + "\n")
        XCTAssertEqual(MeetingFileStore.fileStem("../\n:/"), "Встреча")
        XCTAssertLessThanOrEqual(MeetingFileStore.fileStem(String(repeating: "🧑🏽‍💻", count: 100)).utf8.count, 180)
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

    func testSummaryGroupsBoundUTF8EscapingAndInstructions() throws {
        let sources = (0..<12).map { index in
            TranscriptSource(id: "s\(index)", text: String(repeating: "👩‍👩‍👧‍👦\\\"\n", count: 600))
        }
        for partial in [true, false] {
            let groups = try MeetingPipeline.summaryInputGroups(sources, partial: partial)
            XCTAssertGreaterThan(groups.count, 1)
            XCTAssertEqual(groups.flatMap { $0 }.map(\.id), sources.map(\.id))
            for group in groups {
                XCTAssertLessThanOrEqual(try MeetingPipeline.summaryPrompt(group, partial: partial).utf8.count,
                                         MeetingPipeline.summaryPromptLimit)
            }
        }
        let oversized = TranscriptSource(id: "huge", text: String(repeating: "я", count: MeetingPipeline.summaryPromptLimit))
        XCTAssertThrowsError(try MeetingPipeline.summaryInputGroups([oversized], partial: true))
    }

    func testOversizedFactsAreReducedWithBoundedRequestsAndEvidenceChecks() async throws {
        let big = ["p1s1", "p2s1"].map { id in
            MeetingNotes(topics: [.init(title: "Тема", kind: .general, details: [
                .init(kind: .fact, text: String(repeating: "Факт. ", count: 6_000), sourceIDs: [id])
            ])])
        }
        let small = ["p1s1", "p2s1"].map { id in
            MeetingNotes(topics: [.init(title: "Тема", kind: .general, details: [
                .init(kind: .fact, text: "Факт.", sourceIDs: [id])
            ])])
        }
        let summary = MeetingSummary(title: "Тема", meetingType: .general,
                                     summary: [.init(text: "Факт.", sourceIDs: ["p1s1", "p2s1"])])
        let encoder = JSONEncoder()
        let cases: [([MeetingNotes], String?, Int)] = [
            (small, nil, 5), (big, "лимит запроса", 4), ([small[1]], "вне объединяемых фактов", 3)
        ]
        for (reductions, expectedError, calls) in cases {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let responses = try (big + reductions).map { try encoder.encode($0) } + [encoder.encode(summary)]
            let settings = try codexSettings(in: directory, responses: responses)
            let transcript = String(repeating: "Факт. ", count: 5_000)
            let output = try await MeetingPipeline.run(input: directory.appendingPathComponent("meeting.wav"),
                                                       settings: settings, transcript: transcript, update: { _ in })
            do {
                let result = try await MeetingPipeline.summarize(output, settings: settings, update: { _ in })
                XCTAssertNil(expectedError)
                XCTAssertNotNil(result.summary)
            } catch {
                XCTAssertNotNil(expectedError)
                XCTAssertTrue(error.localizedDescription.contains(expectedError ?? "unexpected success case error"))
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".md") })
            }
            XCTAssertEqual(try String(contentsOf: output.transcript), transcript)
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls")), "\(calls)\n")
            for call in 1...calls {
                let request = try Data(contentsOf: directory.appendingPathComponent("request-\(call).txt"))
                XCTAssertLessThanOrEqual(request.count, MeetingPipeline.summaryPromptLimit)
            }
            let merge = try JSONDecoder().decode([MeetingNotes].self, from: requestData(in: directory, call: 3))
            XCTAssertEqual(merge.first?.sourceIDs, Set(["p1s1"]))
        }
    }

    func testSummarizesSavedTranscriptAndPassesModel() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = ["p1s1", "p2s1"].map { id in
            MeetingNotes(topics: [.init(title: "Выпуск", kind: .project, details: [
                .init(kind: .status, text: "Обсудили выпуск.", sourceIDs: [id])
            ])])
        }
        let summary = MeetingSummary(
            title: "План встречи", meetingType: .project,
            summary: [.init(text: "Обсудили выпуск.", sourceIDs: ["p1s1", "p2s1"])],
            topics: notes.flatMap(\.topics)
        )
        let encoder = JSONEncoder()
        let settings = try codexSettings(in: directory, responses: notes.map { try encoder.encode($0) }
                                        + [try encoder.encode(summary)])
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
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls")), "3\n")
        let first = try requestData(in: directory, call: 1)
        let second = try requestData(in: directory, call: 2)
        let firstSources = try JSONDecoder().decode([TranscriptSource].self, from: first)
        let secondSources = try JSONDecoder().decode([TranscriptSource].self, from: second)
        XCTAssertEqual(secondSources.first?.id, firstSources.last?.id)
        XCTAssertEqual((firstSources + secondSources.dropFirst()).map(\.text).joined(), transcript)
        let finalNotes = try JSONDecoder().decode([MeetingNotes].self, from: requestData(in: directory, call: 3))
        XCTAssertEqual(finalNotes.map(\.sourceIDs), [Set(["p1s1"]), Set(["p2s1"])])
        let partialSchema = try String(contentsOf: directory.appendingPathComponent("schema-1.json"))
        let finalSchema = try String(contentsOf: directory.appendingPathComponent("schema-3.json"))
        XCTAssertFalse(partialSchema.contains("meeting_type"))
        XCTAssertTrue(finalSchema.contains("meeting_type"))
        XCTAssertFalse(finalSchema.contains("markdown"))
    }

    func testShortTranscriptUsesOneCallAndOmitsAbsentSections() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let summary = MeetingSummary(title: "Обратная связь", meetingType: .oneOnOne, topics: [
            .init(title: "Нагрузка", kind: .oneOnOne, details: [
                .init(kind: .concern, text: "Слишком много параллельных задач.", sourceIDs: ["p1s1"])
            ])
        ])
        let settings = try codexSettings(in: directory, responses: [JSONEncoder().encode(summary)])
        let output = try await MeetingPipeline.run(
            input: directory.appendingPathComponent("meeting.wav"), settings: settings,
            transcript: "Слишком много параллельных задач.", update: { _ in }
        )
        let result = try await MeetingPipeline.summarize(output, settings: settings, update: { _ in })
        let markdown = try String(contentsOf: XCTUnwrap(result.summary))
        XCTAssertFalse(markdown.contains("Тип встречи:"))
        XCTAssertTrue(markdown.contains("## Обсуждавшиеся вопросы"))
        for title in ["Краткое резюме", "Решения", "Задачи", "Открытые вопросы", "Не зафиксировано"] {
            XCTAssertFalse(markdown.contains(title))
        }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls")), "1\n")
        let sources = try JSONDecoder().decode([TranscriptSource].self, from: requestData(in: directory, call: 1))
        XCTAssertEqual(sources.map(\.text).joined(), "Слишком много параллельных задач.")
    }

    func testInvalidSummaryKeepsTranscriptAndDoesNotSaveMarkdown() async throws {
        let invalidResponses = [
            #"{"title":"старый формат","markdown":"текст"}"#,
            #"{"title":"тема","meeting_type":"unknown","summary":[],"topics":[],"decisions":[],"actions":[],"open_questions":[]}"#,
            #"{"title":"тема","meeting_type":"general","summary":[{"text":"вывод","source_ids":["missing"]}],"topics":[],"decisions":[],"actions":[],"open_questions":[]}"#,
            #"{"title":"тема","meeting_type":"general","summary":[],"topics":[],"decisions":[],"actions":[],"open_questions":[]}"#
        ]
        for response in invalidResponses {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let settings = try codexSettings(in: directory, responses: [Data(response.utf8)])
            let output = try await MeetingPipeline.run(
                input: directory.appendingPathComponent("meeting.wav"), settings: settings,
                transcript: "Исходный текст.", update: { _ in }
            )
            do {
                _ = try await MeetingPipeline.summarize(output, settings: settings, update: { _ in })
                XCTFail("Expected invalid summary to fail")
            } catch { XCTAssertTrue(error is MeetingError) }
            XCTAssertEqual(try String(contentsOf: output.transcript), "Исходный текст.")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".md") })
        }
    }

    func testFinalSummaryCannotCiteUnextractedSource() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = MeetingNotes(topics: [.init(title: "Тема", kind: .general, details: [
            .init(kind: .fact, text: "Факт.", sourceIDs: ["p1s1"])
        ])])
        let summary = MeetingSummary(title: "Тема", meetingType: .general,
                                     summary: [.init(text: "Факт.", sourceIDs: ["p2s1"])])
        let encoder = JSONEncoder()
        let settings = try codexSettings(in: directory, responses: [
            encoder.encode(notes), encoder.encode(MeetingNotes()), encoder.encode(summary)
        ])
        let output = try await MeetingPipeline.run(
            input: directory.appendingPathComponent("meeting.wav"), settings: settings,
            transcript: String(repeating: "Факт. ", count: 5_000), update: { _ in }
        )
        do {
            _ = try await MeetingPipeline.summarize(output, settings: settings, update: { _ in })
            XCTFail("Expected source outside extracted facts to fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("вне извлечённых")) }
    }

    func testInvalidPartialFactsStopBeforeMerge() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = MeetingNotes(actions: [.init(text: "Проверить.", sourceIDs: ["p2s1"])])
        let settings = try codexSettings(in: directory, responses: [JSONEncoder().encode(invalid)])
        let output = try await MeetingPipeline.run(
            input: directory.appendingPathComponent("meeting.wav"), settings: settings,
            transcript: String(repeating: "Факт. ", count: 5_000), update: { _ in }
        )
        do {
            _ = try await MeetingPipeline.summarize(output, settings: settings, update: { _ in })
            XCTFail("Expected facts citing a different part to fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("источника")) }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls")), "1\n")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".md") })
    }

    func testBlankTranscriptDoesNotCallCodex() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = try codexSettings(in: directory, responses: [])
        let output = try await MeetingPipeline.run(
            input: directory.appendingPathComponent("meeting.wav"), settings: settings,
            transcript: " \n ", update: { _ in }
        )
        do {
            _ = try await MeetingPipeline.summarize(output, settings: settings, update: { _ in })
            XCTFail("Expected a blank transcript to fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Расшифровка пуста")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("calls").path))
        XCTAssertEqual(try String(contentsOf: output.transcript), " \n ")
    }

    func testProcessFailureKeepsInvalidUTF8Diagnostics() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await ProcessRunner.run(
                URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '\\377deliberate-error' >&2; exit 7"], directory: directory
            )
            XCTFail("Expected nonzero exit to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("deliberate-error"))
            XCTAssertTrue(error.localizedDescription.contains("7"))
        }
    }

    func testProcessFailureAndCancellation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                                  arguments: ["-c", "echo deliberate-error >&2; exit 7"], directory: directory)
            XCTFail("Expected nonzero exit to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("deliberate-error"))
            XCTAssertTrue(error.localizedDescription.contains("7"))
        }
        let tasks = (0..<2).map { _ in
            Task {
                try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"),
                                                      arguments: ["30"], directory: directory)
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        for task in tasks { task.cancel() }
        for task in tasks {
            do {
                try await task.value
                XCTFail("Expected cancellation")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // Exercise the real CLI boundary and preserve each request for assertions, without a network call.
    private func codexSettings(in directory: URL, responses: [Data]) throws -> MeetingSettings {
        for (index, response) in responses.enumerated() {
            try response.write(to: directory.appendingPathComponent("response-\(index + 1).json"))
        }
        let cli = directory.appendingPathComponent("fake-codex")
        try #"""
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --output-last-message) shift; result="$1" ;;
                --output-schema) shift; schema="$1" ;;
                --model) shift; model="$1" ;;
                --config|-c) shift
                    case "$1" in model_reasoning_effort=*) reasoning="$1" ;; esac ;;
            esac
            shift
        done
        [ "$model" = 'test-model' ] || exit 20
        [ "$reasoning" = 'model_reasoning_effort="high"' ] || exit 22
        stubdir=$(dirname "$0")
        count=0
        if [ -f "$stubdir/calls" ]; then count=$(cat "$stubdir/calls"); fi
        count=$((count + 1))
        echo "$count" > "$stubdir/calls"
        cat > "$stubdir/request-$count.txt"
        cp "$schema" "$stubdir/schema-$count.json"
        cp "$stubdir/response-$count.json" "$result"
        """#.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return MeetingSettings(outputDirectory: directory, ffmpeg: directory.appendingPathComponent("missing-ffmpeg"),
                               codex: cli, codexModel: "test-model", codexReasoning: "high")
    }

    private func requestData(in directory: URL, call: Int) throws -> Data {
        let prompt = try String(contentsOf: directory.appendingPathComponent("request-\(call).txt"))
        let start = try XCTUnwrap(prompt.range(of: "<meeting_data>\n"))
        let end = try XCTUnwrap(prompt.range(of: "\n</meeting_data>", options: .backwards))
        return Data(prompt[start.upperBound..<end.lowerBound].utf8)
    }
}
