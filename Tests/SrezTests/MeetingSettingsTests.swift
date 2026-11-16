import XCTest
@testable import Srez

final class MeetingSettingsTests: XCTestCase {
    func testCodexAvailabilityRequiresAnExecutableFile() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake codex")
        XCTAssertFalse(MeetingSettings.isCodexAvailable(at: ""))
        XCTAssertFalse(MeetingSettings.isCodexAvailable(at: " \n"))
        XCTAssertFalse(MeetingSettings.isCodexAvailable(at: executable.path))
        XCTAssertFalse(MeetingSettings.isCodexAvailable(at: directory.path))

        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        XCTAssertFalse(MeetingSettings.isCodexAvailable(at: executable.path))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertTrue(MeetingSettings.isCodexAvailable(at: executable.path))
        XCTAssertTrue(MeetingSettings.isCodexAvailable(at: " \(executable.path)\n"))

        let link = directory.appendingPathComponent("codex-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertTrue(MeetingSettings.isCodexAvailable(at: link.path))
        try fm.removeItem(at: executable)
        XCTAssertFalse(MeetingSettings.isCodexAvailable(at: link.path))
    }

    func testBundledFFmpegOverridesLegacyPathAndSurvivesAppMove() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Srez.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleIdentifier": "local.srez.tests.\(UUID().uuidString)",
            "CFBundleExecutable": "Srez", "CFBundlePackageType": "APPL"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let ffmpeg = macOS.appendingPathComponent("ffmpeg")
        try "#!/bin/sh\nexit 0\n".write(to: ffmpeg, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ffmpeg.path)

        let defaults = UserDefaults.standard
        let keys = ["outputDirectory", "ffmpegPath", "codexPath"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in previous { defaults.set(value, forKey: key) } }
        defaults.set(directory.path, forKey: "outputDirectory")
        defaults.set("/usr/bin/false", forKey: "ffmpegPath")
        defaults.set("", forKey: "codexPath")

        let settings = try MeetingSettings.current(bundle: XCTUnwrap(Bundle(url: app)))
        XCTAssertEqual(settings.ffmpeg, ffmpeg)
        XCTAssertTrue(fm.isExecutableFile(atPath: settings.ffmpeg.path))

        let movedApp = directory.appendingPathComponent("Renamed Srez.app")
        try fm.moveItem(at: app, to: movedApp)
        let movedBundle = try XCTUnwrap(Bundle(url: movedApp))
        let moved = try MeetingSettings.current(bundle: movedBundle)
        XCTAssertEqual(moved.ffmpeg, movedApp.appendingPathComponent("Contents/MacOS/ffmpeg"))
        XCTAssertTrue(fm.isExecutableFile(atPath: moved.ffmpeg.path))

        // A broken application must not silently fall back to a machine-specific path.
        try fm.removeItem(at: moved.ffmpeg)
        let broken = try MeetingSettings.current(bundle: movedBundle)
        XCTAssertEqual(broken.ffmpeg, moved.ffmpeg)
        do {
            _ = try await TranscriptionService().run(
                input: directory.appendingPathComponent("recording.mp3"), settings: broken, update: { _ in }
            )
            XCTFail("Expected the missing bundled executable to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("встроенный ffmpeg"))
        }
    }
}
