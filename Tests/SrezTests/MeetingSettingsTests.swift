import XCTest
@testable import Srez

final class MeetingSettingsTests: XCTestCase {
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
            _ = try await MeetingPipeline.run(
                input: directory.appendingPathComponent("recording.mp3"), settings: broken, update: { _ in }
            )
            XCTFail("Expected the missing bundled executable to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("встроенный ffmpeg"))
        }
    }
}
