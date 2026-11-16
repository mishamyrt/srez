import XCTest
@testable import Srez

final class MeetingCoordinatorTests: XCTestCase {
    @MainActor
    func testCombiningDoesNotBlockMainActorAndCanBeCancelled() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let restore = configure(directory, cli: URL(fileURLWithPath: "/usr/bin/false"))
        defer { restore() }
        let originals = try jobs(in: directory, texts: ["Первая.", "Вторая."])
        let queue = MeetingCoordinator(jobs: originals) { outputs, directory in
            XCTAssertFalse(Thread.isMainThread)
            Thread.sleep(forTimeInterval: 0.3)
            return try MeetingFileStore.combineTranscripts(outputs, directory: directory)
        }
        let ids = Set(originals.map(\.id))
        let started = Date()
        let task = Task { try await queue.summarizeTogether(ids) }
        try await waitUntil { await queue.snapshot().combining }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        let pending = await queue.snapshot()
        XCTAssertTrue(pending.hasPendingJobs)
        try await queue.summarizeTogether(ids)
        await queue.cancelCombination()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let snapshot = await queue.snapshot()
        XCTAssertFalse(snapshot.combining)
        XCTAssertFalse(snapshot.hasPendingJobs)
        XCTAssertEqual(snapshot.jobs.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    @MainActor
    func testCombinedSummaryPreservesOriginalJobsAndCanRetry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("fake-codex")
        try executable("#!/bin/sh\nexit 7\n", at: cli)
        let restore = configure(directory, cli: cli)
        defer { restore() }
        var originals = try jobs(in: directory, texts: ["Первая запись.", "Вторая запись.", "Не выбрана."])
        let existing = directory.appendingPathComponent("existing.md")
        try "Прежний конспект.".write(to: existing, atomically: true, encoding: .utf8)
        originals[1].output?.summary = existing
        var ineligible = originals
        ineligible[1].state = .failed
        let other = MeetingCoordinator(jobs: ineligible)
        try await other.summarizeTogether(Set(ineligible.prefix(2).map(\.id)))
        let otherSnapshot = await other.snapshot()
        XCTAssertEqual(otherSnapshot.jobs.count, 3)
        let queue = MeetingCoordinator(jobs: originals)
        let ids = Set(originals.prefix(2).map(\.id))
        try await queue.summarizeTogether([])
        try await queue.summarizeTogether([originals[0].id])
        try await queue.summarizeTogether([originals[0].id, UUID()])
        var snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.jobs.count, 3)
        try await queue.summarizeTogether(ids)
        try await waitForQueue(queue)
        snapshot = await queue.snapshot()
        let combined = try XCTUnwrap(snapshot.jobs.last)
        let transcript = try XCTUnwrap(combined.output?.transcript)
        XCTAssertEqual(try String(contentsOf: transcript), "Первая запись.\n\nВторая запись.")
        XCTAssertEqual(combined.state, .failed)
        XCTAssertEqual(combined.retryTitle, "Повторить суммаризацию")
        XCTAssertTrue(snapshot.jobs.prefix(3).allSatisfy { $0.state == .done })
        await queue.remove(originals[0].id)
        try writeCodex(to: cli)
        await queue.retry(combined.id)
        try await waitForQueue(queue)
        snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.jobs.last?.state, .done)
        XCTAssertNotNil(snapshot.jobs.last?.output?.summary)
        XCTAssertEqual(snapshot.jobs.last?.output?.transcript, transcript)
        let request = try String(contentsOf: directory.appendingPathComponent("request.txt"))
        XCTAssertTrue(request.contains("Первая запись.\\n\\nВторая запись."))
        XCTAssertFalse(request.contains("Не выбрана."))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls")), "call\n")
        XCTAssertEqual(try originals.map { try String(contentsOf: XCTUnwrap($0.output?.transcript)) },
                       ["Первая запись.", "Вторая запись.", "Не выбрана."])
        XCTAssertEqual(try String(contentsOf: existing), "Прежний конспект.")
        XCTAssertEqual(snapshot.jobs[0].output?.summary, existing)
    }

    @MainActor
    func testSeparateQueuesRunInParallelAndCancelIndependently() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["ffmpeg", "codex"] {
            try executable("#!/bin/sh\n/usr/bin/touch \"$(dirname \"$0\")/\(name)-started\"\nexec /bin/sleep 30\n",
                           at: directory.appendingPathComponent("fake-\(name)"))
        }
        let restore = configure(directory, cli: directory.appendingPathComponent("fake-codex"),
                                ffmpeg: directory.appendingPathComponent("fake-ffmpeg"))
        defer { restore() }
        var originals = try jobs(in: directory, texts: ["Обсудили выпуск.", "Обсудили выпуск."])
        var recording = MeetingJob(input: directory.appendingPathComponent("recording.mp3"))
        recording.state = .failed
        var nextRecording = MeetingJob(input: directory.appendingPathComponent("next.mp3"))
        nextRecording.transcript = "Следующая запись."
        originals = [recording, nextRecording] + originals
        let queue = MeetingCoordinator(jobs: originals)
        await queue.retry(recording.id)
        await queue.summarize(originals[2].id)
        await queue.summarize(originals[3].id)
        var snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.jobs.map(\.state), [.running, .waiting, .running, .waiting])
        try await waitUntil {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("ffmpeg-started").path) &&
                FileManager.default.fileExists(atPath: directory.appendingPathComponent("codex-started").path)
        }
        await queue.cancel(recording.id)
        try await waitUntil { await queue.snapshot().jobs[1].state == .done }
        snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.jobs[0].state, .cancelled)
        XCTAssertEqual(snapshot.jobs[2].state, .running)
        XCTAssertEqual(snapshot.jobs[3].state, .waiting)
        XCTAssertNil(snapshot.jobs[1].output?.summary)
        await queue.retry(recording.id)
        await queue.remove(originals[2].id)
        try await waitUntil { await queue.snapshot().jobs.last?.state == .running }
        snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.jobs[0].state, .running)
        XCTAssertEqual(snapshot.jobs.last?.id, originals[3].id)
        await queue.remove(recording.id)
        await queue.remove(originals[3].id)
        snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.jobs.map(\.id), [nextRecording.id])
        try await waitForQueue(queue)
        snapshot = await queue.snapshot()
        XCTAssertFalse(snapshot.hasPendingJobs)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(originals[2].output?.transcript)), "Обсудили выпуск.")
    }

    @MainActor
    func testRemovingJobsCancelsWorkBeforeAdvancingQueue() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("fake-codex")
        try executable("#!/bin/sh\nexec /bin/sleep 30\n", at: cli)
        let restore = configure(directory, cli: cli)
        defer { restore() }
        var originals = try jobs(in: directory, texts: ["Обсудили выпуск.", "Обсудили выпуск."])
        originals[0].kind = .summarization
        originals[0].state = .failed
        originals[1].kind = .summarization
        originals[1].state = .waiting
        var completed = MeetingJob(input: directory.appendingPathComponent("completed.mp3"))
        completed.state = .done
        let queue = MeetingCoordinator(jobs: originals + [completed])
        await queue.retry(originals[0].id)
        await queue.remove(originals[0].id)
        try await waitUntil { await queue.snapshot().jobs.first?.state == .running }
        await queue.remove(originals[1].id)
        await queue.remove(completed.id)
        await queue.remove(UUID())
        try await waitForQueue(queue)
        let snapshot = await queue.snapshot()
        XCTAssertTrue(snapshot.jobs.isEmpty)
        XCTAssertFalse(snapshot.hasPendingJobs)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(originals[0].output?.transcript)), "Обсудили выпуск.")
        let waiting = MeetingJob(input: directory.appendingPathComponent("waiting.mp3"))
        let waitingQueue = MeetingCoordinator(jobs: [waiting])
        await waitingQueue.remove(waiting.id)
        let waitingSnapshot = await waitingQueue.snapshot()
        XCTAssertTrue(waitingSnapshot.jobs.isEmpty)
        XCTAssertFalse(waitingSnapshot.hasPendingJobs)
    }

    @MainActor
    func testTranscriptionWaitsForSummarizeAndSwitchesRevealedFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("fake-codex")
        try writeCodex(to: cli)
        let restore = configure(directory, cli: cli)
        defer { restore() }
        var job = MeetingJob(input: directory.appendingPathComponent("recording.mp3"))
        job.state = .failed
        job.transcript = "Обсудили выпуск."
        let queue = MeetingCoordinator(jobs: [job])
        await queue.summarize(job.id)
        var snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.jobs[0].state, .failed)
        await queue.retry(job.id)
        try await waitForQueue(queue)
        snapshot = await queue.snapshot()
        XCTAssertTrue(snapshot.jobs[0].canSummarize)
        XCTAssertNil(snapshot.jobs[0].transcript)
        let output = try XCTUnwrap(snapshot.jobs[0].output)
        XCTAssertEqual(output.file, output.transcript)
        XCTAssertNil(output.summary)
        await queue.summarize(job.id)
        await queue.summarize(job.id)
        try await waitForQueue(queue)
        snapshot = await queue.snapshot()
        let summarized = try XCTUnwrap(snapshot.jobs[0].output)
        XCTAssertEqual(summarized.file, summarized.summary)
        XCTAssertEqual(summarized.transcript, output.transcript)
        XCTAssertFalse(snapshot.jobs[0].canSummarize)
        await queue.summarize(job.id)
        snapshot = await queue.snapshot()
        XCTAssertFalse(snapshot.hasPendingJobs)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".md") }.count, 1)
    }

    @MainActor
    func testFailedSummaryKeepsTranscriptAndCanRetry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("fake-codex")
        try executable("#!/bin/sh\nexit 7\n", at: cli)
        let restore = configure(directory, cli: cli)
        defer { restore() }
        let original = try XCTUnwrap(jobs(in: directory, texts: ["Обсудили выпуск."]).first)
        let queue = MeetingCoordinator(jobs: [original])
        await queue.summarize(original.id)
        try await waitForQueue(queue)
        var snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.jobs[0].state, .failed)
        XCTAssertNotNil(snapshot.jobs[0].error)
        XCTAssertEqual(snapshot.jobs[0].output?.file, original.output?.transcript)
        XCTAssertEqual(snapshot.jobs[0].retryTitle, "Повторить суммаризацию")
        try writeCodex(to: cli)
        await queue.retry(original.id)
        try await waitForQueue(queue)
        snapshot = await queue.snapshot()
        XCTAssertEqual(snapshot.jobs[0].state, .done)
        XCTAssertNil(snapshot.jobs[0].error)
        XCTAssertNotNil(snapshot.jobs[0].output?.summary)
        XCTAssertEqual(snapshot.jobs[0].output?.transcript, original.output?.transcript)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func executable(_ text: String, at url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    private func configure(_ directory: URL, cli: URL, ffmpeg: URL = URL(fileURLWithPath: "/usr/bin/false")) -> () -> Void {
        let defaults = UserDefaults.standard
        let settings = ["outputDirectory": directory.path, "codexPath": cli.path, "ffmpegPath": ffmpeg.path]
        let previous = settings.keys.map { ($0, defaults.object(forKey: $0)) }
        for (key, value) in settings { defaults.set(value, forKey: key) }
        return { for (key, value) in previous { defaults.set(value, forKey: key) } }
    }
    private func jobs(in directory: URL, texts: [String]) throws -> [MeetingJob] {
        try texts.enumerated().map { index, text in
            let transcript = directory.appendingPathComponent("\(index).raw.txt")
            try text.write(to: transcript, atomically: true, encoding: .utf8)
            var job = MeetingJob(input: directory.appendingPathComponent("\(index).mp3"))
            job.state = .done
            job.output = MeetingOutput(transcript: transcript)
            return job
        }
    }
    private func waitForQueue(_ queue: MeetingCoordinator) async throws {
        try await waitUntil { await !queue.snapshot().hasPendingJobs }
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Queue did not reach the expected state")
    }
    private func writeCodex(to cli: URL) throws {
        try #"""
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
            case "$1" in --output-last-message) shift; result="$1" ;; esac
            shift
        done
        stubdir=$(dirname "$0")
        cat > "$stubdir/request.txt"
        echo call >> "$stubdir/calls"
        printf '%s' '{"title":"План встречи","meeting_type":"project","summary":[{"text":"Обсудили выпуск.","source_ids":["p1s1"]}],"topics":[],"decisions":[],"actions":[],"open_questions":[]}' > "$result"
        """#.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    }

}
