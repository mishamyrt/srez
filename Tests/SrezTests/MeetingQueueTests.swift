import XCTest
@testable import Srez

final class MeetingQueueTests: XCTestCase {
    @MainActor
    func testRemovingJobsCancelsWorkBeforeAdvancingQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("fake-codex")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)

        let defaults = UserDefaults.standard
        let settings: [String: Any] = [
            "outputDirectory": directory.path, "codexPath": cli.path,
            "ffmpegPath": "/usr/bin/false"
        ]
        let previous = settings.keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in previous { defaults.set(value, forKey: key) } }
        for (key, value) in settings { defaults.set(value, forKey: key) }

        let queue = MeetingQueue()
        var first = MeetingJob(input: directory.appendingPathComponent("first.mp3"))
        first.state = .failed
        let transcript = directory.appendingPathComponent("first.raw.txt")
        try "Обсудили выпуск.".write(to: transcript, atomically: true, encoding: .utf8)
        first.output = MeetingOutput(transcript: transcript)
        var second = MeetingJob(input: directory.appendingPathComponent("second.mp3"))
        second.output = first.output
        var completed = MeetingJob(input: directory.appendingPathComponent("completed.mp3"))
        completed.state = .done
        queue.jobs = [first, second, completed]

        queue.retry(first.id)
        queue.remove(first.id)
        XCTAssertEqual(queue.jobs.map(\.id), [second.id, completed.id])
        XCTAssertEqual(queue.jobs.first?.state, .waiting)
        XCTAssertTrue(queue.hasPendingJobs)

        for _ in 0..<100 {
            if queue.jobs.first?.state == .running { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(queue.jobs.first?.state, .running)
        queue.remove(second.id)
        queue.remove(completed.id)
        queue.remove(UUID())
        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertTrue(queue.hasPendingJobs)
        for _ in 0..<100 {
            if !queue.hasPendingJobs { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(queue.hasPendingJobs)
        XCTAssertEqual(try String(contentsOf: transcript), "Обсудили выпуск.")

        queue.jobs = [MeetingJob(input: directory.appendingPathComponent("waiting.mp3"))]
        queue.remove(queue.jobs[0].id)
        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertFalse(queue.hasPendingJobs)
    }

    @MainActor
    func testTranscriptionWaitsForSummarizeAndSwitchesRevealedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("fake-codex")
        try writeCodex(to: cli)
        let defaults = UserDefaults.standard
        let keys = ["outputDirectory", "ffmpegPath", "codexPath"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in previous { defaults.set(value, forKey: key) } }
        defaults.set(directory.path, forKey: "outputDirectory")
        defaults.set("/usr/bin/false", forKey: "ffmpegPath")
        defaults.set("", forKey: "codexPath")

        let queue = MeetingQueue()
        var job = MeetingJob(input: directory.appendingPathComponent("recording.mp3"))
        job.state = .failed
        job.transcript = "Обсудили выпуск."
        queue.jobs = [job]
        queue.summarize(job.id)
        XCTAssertEqual(queue.jobs[0].state, .failed)
        queue.retry(job.id)
        try await waitForQueue(queue)
        XCTAssertEqual(queue.jobs[0].state, .done)
        XCTAssertTrue(queue.jobs[0].canSummarize)
        XCTAssertNil(queue.jobs[0].transcript)
        let output = try XCTUnwrap(queue.jobs[0].output)
        XCTAssertEqual(output.file, output.transcript)
        XCTAssertNil(output.summary)

        defaults.set("", forKey: "ffmpegPath")
        defaults.set(cli.path, forKey: "codexPath")
        queue.summarize(job.id)
        queue.summarize(job.id)
        XCTAssertFalse(queue.jobs[0].canSummarize)
        try await waitForQueue(queue)
        XCTAssertEqual(queue.jobs[0].state, .done)
        let summarized = try XCTUnwrap(queue.jobs[0].output)
        XCTAssertEqual(summarized.file, summarized.summary)
        XCTAssertEqual(summarized.transcript, output.transcript)
        XCTAssertFalse(queue.jobs[0].canSummarize)
        queue.summarize(job.id)
        XCTAssertFalse(queue.hasPendingJobs)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".md") }.count, 1)
    }

    @MainActor
    func testFailedSummaryKeepsTranscriptAndCanRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("fake-codex")
        try "#!/bin/sh\nexit 7\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let defaults = UserDefaults.standard
        let keys = ["outputDirectory", "ffmpegPath", "codexPath"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in previous { defaults.set(value, forKey: key) } }
        defaults.set(directory.path, forKey: "outputDirectory")
        defaults.set("", forKey: "ffmpegPath")
        defaults.set(cli.path, forKey: "codexPath")

        let transcript = directory.appendingPathComponent("recording.raw.txt")
        try "Обсудили выпуск.".write(to: transcript, atomically: true, encoding: .utf8)
        let queue = MeetingQueue()
        var job = MeetingJob(input: directory.appendingPathComponent("missing.mp3"))
        job.state = .done
        job.output = MeetingOutput(transcript: transcript)
        queue.jobs = [job]
        queue.summarize(job.id)
        try await waitForQueue(queue)
        XCTAssertEqual(queue.jobs[0].state, .failed)
        XCTAssertNotNil(queue.jobs[0].error)
        XCTAssertEqual(queue.jobs[0].output?.file, transcript)
        XCTAssertEqual(queue.jobs[0].retryTitle, "Повторить суммаризацию")
        XCTAssertEqual(try String(contentsOf: transcript), "Обсудили выпуск.")

        try writeCodex(to: cli)
        queue.retry(job.id)
        try await waitForQueue(queue)
        XCTAssertEqual(queue.jobs[0].state, .done)
        XCTAssertNil(queue.jobs[0].error)
        XCTAssertNotNil(queue.jobs[0].output?.summary)
        XCTAssertEqual(queue.jobs[0].output?.transcript, transcript)
    }

    private func writeCodex(to cli: URL) throws {
        try #"""
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
            case "$1" in --output-last-message) shift; result="$1" ;; esac
            shift
        done
        cat > /dev/null
        printf '%s' '{"title":"План встречи","markdown":"# План встречи\nОбсудили выпуск."}' > "$result"
        """#.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    }

    @MainActor
    private func waitForQueue(_ queue: MeetingQueue) async throws {
        for _ in 0..<200 {
            if !queue.hasPendingJobs { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Queue did not finish")
    }
}
