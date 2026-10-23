import AppKit
import Combine
import SwiftUI

@main
struct SrezApp: App {
    @NSApplicationDelegateAdaptor(MeetingsDelegate.self) private var delegate

    init() { MeetingSettings.registerDefaults() }

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

@MainActor
final class MeetingsDelegate: NSObject, NSApplicationDelegate {
    let queue = MeetingQueue()
    private var mainWindow: NSWindow?
    private var jobsObservation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainWindow = NSApp.windows.first { $0.title == "Srez" }
        jobsObservation = queue.$jobs.map(\.isEmpty).removeDuplicates().sink { [weak self] isEmpty in
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
            if queue.jobs.isEmpty { queue.chooseFiles() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        queue.enqueue(urls)
        application.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if queue.jobs.isEmpty {
            queue.chooseFiles()
            return false
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard queue.hasPendingJobs || queue.jobs.contains(where: { $0.transcript != nil }) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Закрыть приложение?"
        alert.informativeText = "Обработка будет остановлена. Очередь и расшифровки, для которых не удалось сохранить результат, не сохраняются после выхода."
        alert.addButton(withTitle: "Продолжить работу")
        alert.addButton(withTitle: "Выйти")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        for job in queue.jobs where job.state == .waiting { queue.cancel(job.id) }
        for job in queue.jobs where job.state == .running { queue.cancel(job.id) }
        Task {
            while queue.hasPendingJobs { try? await Task.sleep(for: .milliseconds(100)) }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct MeetingsView: View {
    @ObservedObject var queue: MeetingQueue
    @AppStorage("outputDirectory") private var outputDirectory = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(queue.jobs) { job in
                        jobView(job)
                        Divider().padding(.leading, 46)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            Divider()
            HStack {
                Text((outputDirectory as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(outputDirectory)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: 360, minHeight: 320)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible, placement: .primaryAction)
                windowActions.sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { Spacer() }
                windowActions
            }
        }
    }

    private var windowActions: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 6) {
                Button("Открыть запись…", systemImage: "folder") { queue.chooseFiles() }
                    .disabled(queue.pickerPresented)
                    .help("Открыть запись… (⌘O)")
                SettingsLink {
                    Label("Настройки", systemImage: "gearshape")
                }
                .help("Настройки")
            }
            .padding(.trailing, 3)
            .buttonStyle(ToolbarActionButtonStyle())
            .labelStyle(.iconOnly)
            .font(.system(size: 16))
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func jobView(_ job: MeetingJob) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: job.input.path))
                .resizable()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.input.lastPathComponent)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.input.lastPathComponent)
                    .textSelection(.enabled)
                if job.state == .running {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .accessibilityLabel("Прогресс обработки")
                }
                Text(job.state == .done ? (job.output?.summary?.deletingPathExtension().lastPathComponent ?? job.stage) : job.stage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = job.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if job.transcript != nil && (job.state == .failed || job.state == .cancelled) {
                    Text("Расшифровка сохранена в памяти до закрытия приложения.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if job.canSummarize {
                    Button { queue.summarize(job.id) } label: {
                        Label {
                            Text("Summarize")
                        } icon: {
                            ZStack {
                                Image(systemName: "circle.fill")
                                Image("Summarize", bundle: .module)
                                    .resizable()
                                    .frame(width: 9, height: 9)
                                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                            }
                        }
                    }
                    .help("Суммаризировать расшифровку")
                }
                if let output = job.output {
                    Button("Показать в Finder", systemImage: "magnifyingglass.circle.fill") {
                        NSWorkspace.shared.activateFileViewerSelecting([output.file])
                    }
                    .help("Показать в Finder")
                }
                if job.state == .failed || job.state == .cancelled {
                    Button(job.retryTitle, systemImage: "arrow.clockwise.circle.fill") { queue.retry(job.id) }
                        .help(job.retryTitle)
                }
                Button("Убрать из списка", systemImage: "xmark.circle.fill") { queue.remove(job.id) }
                    .help(job.state == .running || job.state == .waiting ? "Отменить и убрать из списка" : "Убрать из списка")
            }
            .buttonStyle(JobActionButtonStyle())
            .labelStyle(.iconOnly)
            .font(.system(size: 14))
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let output = job.output { NSWorkspace.shared.open(output.file) }
        }
        .contextMenu {
            if let output = job.output {
                Button(output.summary == nil ? "Открыть расшифровку" : "Открыть резюме") { NSWorkspace.shared.open(output.file) }
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([output.file]) }
                if output.summary != nil {
                    Button("Открыть расшифровку") { NSWorkspace.shared.open(output.transcript) }
                }
            }
            if job.canSummarize {
                Button("Summarize") { queue.summarize(job.id) }
            }
            if job.state == .running || job.state == .waiting {
                Button("Отменить") { queue.cancel(job.id) }
                    .disabled(job.stage == "Отмена…")
            }
            if job.state == .failed || job.state == .cancelled {
                Button(job.retryTitle) { queue.retry(job.id) }
            }
            Button("Убрать из списка") { queue.remove(job.id) }
        }
    }
}

private struct ToolbarActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration)
    }

    private struct Content: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(width: 20, height: 16)
                .padding(6)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(isEnabled && (isHovered || configuration.isPressed) ? 0.1 : 0))
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { isHovered = $0 }
        }
    }
}

private struct JobActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration)
    }

    private struct Content: View {
        let configuration: ButtonStyle.Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovered || configuration.isPressed ? .secondary : .tertiary)
                .onHover { isHovered = $0 }
        }
    }
}

struct MeetingSettingsView: View {
    @AppStorage("outputDirectory") private var output = ""
    @AppStorage("ffmpegPath") private var ffmpeg = ""
    @AppStorage("codexPath") private var codex = ""
    @AppStorage("codexModel") private var codexModel = "gpt-6-sol"
    @AppStorage("codexReasoning") private var codexReasoning = "medium"

    var body: some View {
        Form {
            Section("Результаты") {
                pathRow("Папка", value: $output, directory: true)
                Text("Расшифровка сохраняется сразу, резюме создаётся по кнопке Summarize. Существующие файлы не перезаписываются.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Распознавание") {
                pathRow("ffmpeg", value: $ffmpeg, directory: false)
                Text("Модель речи скачивается автоматически при первом распознавании (около 445 МБ).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Codex") {
                pathRow("Codex CLI", value: $codex, directory: false)
                Picker("Модель", selection: $codexModel) {
                    ForEach(MeetingSettings.codexModels, id: \.self) { Text($0).tag($0) }
                }
                Picker("Рассуждение", selection: $codexReasoning) {
                    ForEach(MeetingSettings.reasoningLevels, id: \.self) { Text($0).tag($0) }
                }
                Text("Используется текущая авторизация CLI. Текст встречи отправляется в Codex; аудио обрабатывается локально.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Изменения применяются к следующему файлу в очереди или повторной попытке.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 610, height: 500)
    }

    private func pathRow(_ title: String, value: Binding<String>, directory: Bool) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: value).labelsHidden()
                Button("Выбрать…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = directory
                    panel.canChooseFiles = !directory
                    panel.canCreateDirectories = directory
                    panel.prompt = "Выбрать"
                    if !value.wrappedValue.isEmpty {
                        panel.directoryURL = URL(fileURLWithPath: (value.wrappedValue as NSString).expandingTildeInPath)
                    }
                    if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path }
                }
            }
        }
    }
}
