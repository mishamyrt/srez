import XCTest
@testable import Srez

final class MeetingsViewModelTests: XCTestCase {
    @MainActor
    func testViewModelProjectsCoordinatorStateAndReleasesObservation() async throws {
        var first = MeetingJob(input: URL(fileURLWithPath: "/tmp/first.mp3"))
        first.state = .done
        first.output = MeetingOutput(transcript: URL(fileURLWithPath: "/tmp/first.raw.txt"))
        var second = MeetingJob(input: URL(fileURLWithPath: "/tmp/second.mp3"))
        second.state = .done
        second.output = MeetingOutput(transcript: URL(fileURLWithPath: "/tmp/second.raw.txt"))
        let coordinator = makeCoordinator(jobs: [first, second])
        var model: MeetingsViewModel? = MeetingsViewModel(coordinator: coordinator, settings: SettingsStore())
        weak var released = model
        for _ in 0..<100 where model?.jobs.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model?.jobs.map(\.id), [first.id, second.id])
        model?.selectedIDs = [first.id, second.id]
        await coordinator.remove(first.id)
        for _ in 0..<100 where model?.jobs.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model?.selectedIDs, [second.id])
        XCTAssertEqual(model?.jobs.first?.id, second.id)
        await coordinator.remove(second.id)
        for _ in 0..<100 where model?.jobs.isEmpty == false { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model?.jobs.count, 0)
        XCTAssertEqual(model?.selectedIDs, [])
        model = nil
        await Task.yield()
        XCTAssertNil(released)
    }
}
