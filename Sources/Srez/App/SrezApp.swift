import SwiftUI

@main
struct SrezApp: App {
    @NSApplicationDelegateAdaptor(MeetingsDelegate.self) private var delegate

    init() {
        MeetingSettings.registerDefaults()
    }

    var body: some Scene {
        Window("Srez", id: "meetings") {
            MeetingsView(queue: delegate.queue)
        }
        .defaultSize(width: 420, height: 550)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть запись…") { delegate.queue.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }
        Settings { MeetingSettingsView() }
    }
}
