import AppKit
import SwiftUI
import XCTest
@testable import Srez

final class MeetingSelectionTests: XCTestCase {
    @MainActor
    func testCommandClickTogglesSelectionWithoutWaitingForDoubleClick() {
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        app.setActivationPolicy(.prohibited)
        defer { app.setActivationPolicy(previousPolicy) }
        var job = MeetingJob(input: URL(fileURLWithPath: "/tmp/recording.mp3"))
        job.state = .done
        job.output = MeetingOutput(transcript: URL(fileURLWithPath: "/tmp/recording.raw.txt"))
        let otherID = UUID()
        var selectedIDs: Set<UUID> = [otherID]
        var clickTime = Date()
        var latency: TimeInterval?
        let selection = Binding(get: { selectedIDs }, set: {
            selectedIDs = $0
            latency = Date().timeIntervalSince(clickTime)
        })
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MeetingJobView(
            job: job, queue: MeetingQueue(), codexAvailable: true, selectedIDs: selection
        ))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        let clicks: [(NSEvent.ModifierFlags, Set<UUID>)] = [
            ([], [otherID]), (.command, [otherID, job.id]), (.command, [otherID])
        ]
        for (index, click) in clicks.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(index) * 0.3) {
                clickTime = Date()
                latency = nil
                self.click(window, modifiers: click.0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    XCTAssertEqual(selectedIDs, click.1)
                    if click.0.contains(.command) {
                        XCTAssertLessThan(latency ?? 1, 0.2)
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            app.stop(nil)
            app.postEvent(NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                subtype: 0, data1: 0, data2: 0
            )!, atStart: false)
        }
        // Bare XCTest does not run AppKit's event loop; gestures need real event dispatch.
        app.run()
    }

    @MainActor
    private func click(_ window: NSWindow, modifiers: NSEvent.ModifierFlags) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 80, y: window.contentView!.bounds.midY),
                modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
            NSApp.postEvent(event, atStart: false)
        }
    }
}
