import XCTest
@testable import Srez

final class AudioConverterTests: XCTestCase {
    private enum BodyError: Error { case failed }

    func testConvertedAudioLivesThroughBodyAndIsRemovedOnSuccessOrFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("original.mp3")
        try "original".write(to: input, atomically: true, encoding: .utf8)
        let executable = directory.appendingPathComponent("fake-ffmpeg")
        try #"""
        #!/bin/sh
        for last in "$@"; do :; done
        printf '%s' "$last" > "$(dirname "$0")/converted-path"
        printf 'converted' > "$last"
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        for fail in [false, true] {
            do {
                let text: String = try await AudioConverter.withWAV(input: input, executable: executable) { wav in
                    try await Task.sleep(for: .milliseconds(10))
                    XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
                    if fail { throw BodyError.failed }
                    return try String(contentsOf: wav)
                }
                XCTAssertFalse(fail)
                XCTAssertEqual(text, "converted")
            } catch {
                XCTAssertTrue(fail)
                XCTAssertTrue(error is BodyError)
            }
            let path = try String(contentsOf: directory.appendingPathComponent("converted-path"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
            XCTAssertEqual(try String(contentsOf: input), "original")
        }
    }
}
