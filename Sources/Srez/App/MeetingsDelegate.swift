import AppKit
import Combine

@MainActor
final class MeetingsDelegate: NSObject, NSApplicationDelegate {
    let dependencies = AppDependencies()
    private var model: MeetingsViewModel {
        dependencies.meetings
    }

    private var mainWindow: NSWindow?
    private var jobsObservation: AnyCancellable?

    func applicationDidFinishLaunching(_: Notification) {
        mainWindow = NSApp.windows.first { $0.title == "Srez" }
        jobsObservation = model.$jobs.map(\.isEmpty).removeDuplicates()
            .sink { [weak self] isEmpty in
                if isEmpty {
                    self?.mainWindow?.orderOut(nil)
                } else {
                    self?.mainWindow?.makeKeyAndOrderFront(nil)
                }
            }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Finder's open event arrives during launch; let it suppress the initial picker.
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            if await dependencies.coordinator.snapshot().jobs.isEmpty {
                model.chooseFiles()
            }
        }
    }

    func applicationDidBecomeActive(_: Notification) {
        dependencies.settingsStore.refresh()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.enqueue(urls)
        application.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(
        _: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        Task {
            if await dependencies.coordinator.snapshot().jobs.isEmpty {
                model.chooseFiles()
            } else {
                mainWindow?.makeKeyAndOrderFront(nil)
            }
        }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication
        .TerminateReply
    {
        Task {
            let snapshot = await dependencies.coordinator.snapshot()
            if snapshot.hasPendingJobs || snapshot.hasUnsavedTranscripts {
                let alert = NSAlert()
                alert.messageText = "Закрыть приложение?"
                alert.informativeText = "Обработка будет остановлена. Очередь и расшифровки, для которых не удалось сохранить результат, не сохраняются после выхода."
                alert.addButton(withTitle: "Продолжить работу")
                alert.addButton(withTitle: "Выйти")
                guard alert.runModal() == .alertSecondButtonReturn else {
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
                await dependencies.coordinator.cancelAll()
                do { try await dependencies.coordinator.waitUntilIdle() }
                catch { sender.reply(toApplicationShouldTerminate: false); return }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
