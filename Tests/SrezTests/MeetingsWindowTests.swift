import AppKit
import XCTest
@testable import Srez

final class MeetingsWindowTests: XCTestCase {
    @MainActor
    func testEmptyWindowStaysVisibleAndReopensWithoutFilePicker() async throws {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        defer { app.setActivationPolicy(previousPolicy) }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 550),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Srez"
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let delegate = MeetingsDelegate()

        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        // The former startup picker was delayed by 350 ms.
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(delegate.dependencies.meetings.pickerPresented)

        window.orderOut(nil)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false))
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(delegate.dependencies.meetings.pickerPresented)
    }
}
