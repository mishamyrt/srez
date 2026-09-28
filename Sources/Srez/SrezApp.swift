import AppKit
import SwiftUI

@main
struct SrezApp: App {
    @NSApplicationDelegateAdaptor(MeetingsDelegate.self) private var delegate

    init() { MeetingSettings.registerDefaults() }

    var body: some Scene {
        Window("Srez", id: "meetings") {
            MeetingsView(queue: delegate.queue)
        }
        .defaultSize(width: 680, height: 480)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainWindow = NSApp.windows.first { $0.title == "Srez" }
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Протоколы встреч").font(.title2.bold())
                    Text("Запись → расшифровка → резюме").foregroundStyle(.secondary)
                }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Настройки")
                Button("Открыть запись…") { queue.chooseFiles() }
                    .buttonStyle(.borderedProminent)
                    .disabled(queue.pickerPresented)
            }.padding(24)
            Divider()
            if queue.jobs.isEmpty {
                ContentUnavailableView {
                    Label("Выберите запись встречи", systemImage: "doc.badge.waveform")
                } description: {
                    Text("MP3, WAV, WebM или MP4\nМожно открыть несколько файлов: они попадут в очередь.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(queue.jobs) { job in
                            jobView(job)
                            Divider()
                        }
                    }.padding(24)
                }
            }
            Divider()
            HStack {
                Text("Распознавание на Mac · Суммаризация через Codex")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if queue.jobs.contains(where: { $0.state == .done }) {
                    Button("Убрать завершённые") { queue.clearFinished() }.font(.caption)
                }
            }.padding(12)
        }
        .frame(minWidth: 600, minHeight: 380)
    }

    @ViewBuilder
    private func jobView(_ job: MeetingJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: job.state == .done ? "checkmark.circle.fill" : "doc.badge.waveform")
                    .foregroundStyle(job.state == .done ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.output?.markdown.deletingPathExtension().lastPathComponent ?? job.input.lastPathComponent)
                        .font(.headline).textSelection(.enabled)
                    Text(job.stage).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if job.state == .running || job.state == .waiting {
                    Button("Отменить") { queue.cancel(job.id) }
                        .disabled(job.stage == "Отмена…")
                }
                if job.state == .failed || job.state == .cancelled {
                    Button(job.transcript == nil ? "Повторить" : "Повторить суммаризацию") { queue.retry(job.id) }
                }
            }
            if job.state == .running {
                if let progress = job.progress {
                    HStack {
                        ProgressView(value: progress)
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                    }
                } else { ProgressView().controlSize(.small) }
            }
            if let error = job.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if job.transcript != nil && (job.state == .failed || job.state == .cancelled) {
                Text("Расшифровка сохранена в памяти до закрытия приложения.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let output = job.output {
                HStack {
                    Button("Открыть Markdown") { NSWorkspace.shared.open(output.markdown) }
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([output.markdown]) }
                    if let raw = output.raw {
                        Button("Расшифровка") { NSWorkspace.shared.open(raw) }
                    }
                }
            }
        }
    }
}

struct MeetingSettingsView: View {
    @AppStorage("outputDirectory") private var output = ""
    @AppStorage("modelDirectory") private var model = ""
    @AppStorage("ffmpegPath") private var ffmpeg = ""
    @AppStorage("codexPath") private var codex = ""
    @AppStorage("codexModel") private var codexModel = "gpt-6-sol"
    @AppStorage("codexReasoning") private var codexReasoning = "medium"
    @AppStorage("saveRaw") private var saveRaw = true

    var body: some View {
        Form {
            Section("Результаты") {
                pathRow("Папка", value: $output, directory: true)
                Toggle("Сохранять сырую расшифровку (.raw.txt)", isOn: $saveRaw)
                Text("Резюме и расшифровка получают имя по теме встречи. Существующие файлы не перезаписываются.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Распознавание") {
                pathRow("Модель GigaAM", value: $model, directory: true)
                pathRow("ffmpeg", value: $ffmpeg, directory: false)
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
