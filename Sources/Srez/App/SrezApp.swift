import SwiftUI

@main
struct SrezApp: App {
    @NSApplicationDelegateAdaptor(MeetingsDelegate.self) private var delegate

    var body: some Scene {
        Window("Srez", id: "meetings") {
            MeetingsView(model: delegate.dependencies.meetings)
        }
        .defaultSize(width: 420, height: 550)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть запись…") { delegate.dependencies.meetings.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }
        Settings { SettingsView(model: delegate.dependencies.settings) }
    }
}
