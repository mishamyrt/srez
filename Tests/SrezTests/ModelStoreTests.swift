import XCTest
@testable import Srez

final class ModelStoreTests: XCTestCase {
    private let checksum = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testDownloadReuseAndRepairRejectIncompleteFiles() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let cached = directory.appendingPathComponent("model.bin")
        let temporary = directory.appendingPathComponent("download.tmp")

        func install(body: String, status: Int = 200) async throws {
            try await ModelStore.installFile(named: "model.bin", checksum: checksum, in: directory) { url in
                try Data(body.utf8).write(to: temporary)
                return (temporary, try XCTUnwrap(HTTPURLResponse(
                    url: url, statusCode: status, httpVersion: nil, headerFields: nil
                )))
            }
        }

        try await install(body: "abc")
        XCTAssertEqual(try String(contentsOf: cached), "abc")
        XCTAssertFalse(fm.fileExists(atPath: temporary.path))
        try await ModelStore.installFile(named: "model.bin", checksum: checksum, in: directory) { _ in
            XCTFail("A verified model must be usable offline")
            throw URLError(.notConnectedToInternet)
        }

        // A damaged cache must be repaired, and a failed download must never replace it.
        try Data("damaged".utf8).write(to: cached)
        for (body, status) in [("ab", 200), ("abc", 404)] {
            do {
                try await install(body: body, status: status)
                XCTFail("Invalid download was accepted")
            } catch { XCTAssertTrue(error is MeetingError) }
            XCTAssertEqual(try String(contentsOf: cached), "damaged")
            XCTAssertFalse(fm.fileExists(atPath: temporary.path))
        }
        try await install(body: "abc")
        XCTAssertEqual(try String(contentsOf: cached), "abc")
    }

    func testCancelledDownloadDoesNotInstallFile() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let task = Task {
            try await ModelStore.installFile(named: "model.bin", checksum: checksum, in: directory) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.cancelled)
            }
        }
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
