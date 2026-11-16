import AppKit
import Combine

@MainActor
final class MeetingsDelegate: NSObject, NSApplicationDelegate {
    let queue = MeetingQueue()
    private var mainWindow: NSWindow?
    private var jobsObservation: AnyCancellable?

    func applicationDidFinishLaunching(_: Notification) {
        mainWindow = NSApp.windows.first { $0.title == "Srez" }
        jobsObservation = queue.$jobs.map(\.isEmpty).removeDuplicates()
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
            if queue.jobs.isEmpty {
                queue.chooseFiles()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        queue.enqueue(urls)
        application.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(
        _: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        if queue.jobs.isEmpty {
            queue.chooseFiles()
            return false
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication
        .TerminateReply
    {
        guard queue.hasPendingJobs || queue.jobs
            .contains(where: { $0.transcript != nil }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Закрыть приложение?"
        alert.informativeText = "Обработка будет остановлена. Очередь и расшифровки, для которых не удалось сохранить результат, не сохраняются после выхода."
        alert.addButton(withTitle: "Продолжить работу")
        alert.addButton(withTitle: "Выйти")
        guard alert.runModal() == .alertSecondButtonReturn
        else { return .terminateCancel }
        queue.cancelCombination()
        for job in queue.jobs where job.state == .waiting {
            queue.cancel(job.id)
        }
        for job in queue.jobs where job.state == .running {
            queue.cancel(job.id)
        }
        Task {
            while queue.hasPendingJobs {
                try? await Task.sleep(for: .milliseconds(100))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
