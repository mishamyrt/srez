import SwiftUI

@main
struct SrezApp: App {
    @NSApplicationDelegateAdaptor(MeetingsDelegate.self) private var delegate

    init() {
        MeetingSettings.registerDefaults()
    }

    var body: some Scene {
        Window("Srez", id: "meetings") {
            MeetingsView(model: delegate.model)
        }
        .defaultSize(width: 420, height: 550)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть запись…") { delegate.model.chooseFiles() }
                    .keyboardShortcut("o")
            }
        }
        Settings { MeetingSettingsView() }
    }
}
