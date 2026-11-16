import XCTest
@testable import Srez

final class MeetingSettingsTests: XCTestCase {
    @MainActor
    func testSettingsKeepLegacyKeysAndShareEditsBetweenViewModels() async throws {
        let suite = "Srez-Settings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/tmp/old", forKey: "outputDirectory")
        let store = SettingsStore(defaults: defaults)
        let dependencies = AppDependencies(store: store)
        let before = try store.current()
        dependencies.settings.outputDirectory = "/tmp/new"
        for _ in 0..<100 where dependencies.meetings.outputDirectory != "/tmp/new" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(defaults.string(forKey: "outputDirectory"), "/tmp/new")
        XCTAssertEqual(dependencies.meetings.outputDirectory, "/tmp/new")
        XCTAssertEqual(before.outputDirectory.path, "/tmp/old")
        XCTAssertEqual(try store.current().outputDirectory.path, "/tmp/new")
        dependencies.settings.codexModel = "chosen-model"
        guard case let .codex(configuration) = try store.current().provider else { return XCTFail("Expected Codex") }
        XCTAssertEqual(configuration.model, "chosen-model")
        XCTAssertEqual(defaults.string(forKey: "codexModel"), "chosen-model")
    }

    func testCodexAvailabilityRequiresAnExecutableFile() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake codex")
        XCTAssertFalse(CodexProvider.isAvailable(at: ""))
        XCTAssertFalse(CodexProvider.isAvailable(at: " \n"))
        XCTAssertFalse(CodexProvider.isAvailable(at: executable.path))
        XCTAssertFalse(CodexProvider.isAvailable(at: directory.path))

        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        XCTAssertFalse(CodexProvider.isAvailable(at: executable.path))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertTrue(CodexProvider.isAvailable(at: executable.path))
        XCTAssertTrue(CodexProvider.isAvailable(at: " \(executable.path)\n"))

        let link = directory.appendingPathComponent("codex-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: executable)
        XCTAssertTrue(CodexProvider.isAvailable(at: link.path))
        try fm.removeItem(at: executable)
        XCTAssertFalse(CodexProvider.isAvailable(at: link.path))
    }

    @MainActor
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

        let settings = try SettingsStore().current(bundle: XCTUnwrap(Bundle(url: app)))
        XCTAssertEqual(settings.ffmpeg, ffmpeg)
        XCTAssertTrue(fm.isExecutableFile(atPath: settings.ffmpeg.path))

        let movedApp = directory.appendingPathComponent("Renamed Srez.app")
        try fm.moveItem(at: app, to: movedApp)
        let movedBundle = try XCTUnwrap(Bundle(url: movedApp))
        let moved = try SettingsStore().current(bundle: movedBundle)
        XCTAssertEqual(moved.ffmpeg, movedApp.appendingPathComponent("Contents/MacOS/ffmpeg"))
        XCTAssertTrue(fm.isExecutableFile(atPath: moved.ffmpeg.path))

        // A broken application must not silently fall back to a machine-specific path.
        try fm.removeItem(at: moved.ffmpeg)
        let broken = try SettingsStore().current(bundle: movedBundle)
        XCTAssertEqual(broken.ffmpeg, moved.ffmpeg)
        do {
            _ = try await TranscriptionService().run(
                input: directory.appendingPathComponent("recording.mp3"), settings: broken.transcription, update: { _ in }
            )
            XCTFail("Expected the missing bundled executable to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("встроенный ffmpeg"))
        }
    }
}
