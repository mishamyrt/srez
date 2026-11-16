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
        queue.cancelCombination()
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
    @AppStorage("codexPath") private var codexPath = ""
    @State private var codexAvailable = false
    @State private var isScrolled = false
    @State private var isOutputHovered = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var summaryError: String?

    private var selectableIDs: Set<UUID> {
        Set(queue.jobs.filter(\.canSelectForSummary).map(\.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(queue.jobs) { job in
                        MeetingJobView(job: job, queue: queue, codexAvailable: codexAvailable,
                                       selectedIDs: $selectedIDs)
                    }
                }
                .padding(.top, 8)
                .onGeometryChange(for: Bool.self) { geometry in
                    geometry.frame(in: .named("meetingsScroll")).minY < 0
                } action: { isScrolled = $0 }
            }
            .coordinateSpace(name: "meetingsScroll")
            .overlay(alignment: .top) {
                if isScrolled {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 0.5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            Divider()
            if !selectedIDs.isEmpty {
                HStack {
                    Text("Выбрано: \(selectedIDs.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(queue.combining ? "Объединение…" : "Суммаризировать вместе") {
                        let ids = selectedIDs
                        Task {
                            do {
                                try await queue.summarizeTogether(ids)
                                selectedIDs.subtract(ids)
                            } catch is CancellationError {
                            } catch {
                                summaryError = error.localizedDescription
                            }
                        }
                    }
                    .disabled(selectedIDs.count < 2 || !codexAvailable || queue.combining)
                    .help("Объединить расшифровки в порядке списка и создать общий конспект")
                    Button("Снять выделение", systemImage: "xmark") { selectedIDs.removeAll() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            HStack {
                Text((outputDirectory as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(outputDirectory)
                    .textSelection(.enabled)
                Spacer()
                Button("Выбрать папку результатов", systemImage: "folder") {
                    let panel = NSOpenPanel()
                    panel.title = "Выберите папку результатов"
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.prompt = "Выбрать"
                    if !outputDirectory.isEmpty {
                        panel.directoryURL = URL(fileURLWithPath: (outputDirectory as NSString).expandingTildeInPath)
                    }
                    if panel.runModal() == .OK, let url = panel.url { outputDirectory = url.path }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 14)
                .help("Выбрать папку результатов")
                .opacity(isOutputHovered ? 1 : 0)
                .allowsHitTesting(isOutputHovered)
                .accessibilityHidden(!isOutputHovered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .windowBackgroundColor))
            .contentShape(Rectangle())
            .onHover { isOutputHovered = $0 }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(minWidth: 360, minHeight: 320)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            queue.enqueue(files)
            return true
        }
        .task(id: codexPath) {
            codexAvailable = MeetingSettings.isCodexAvailable(at: codexPath)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            codexAvailable = MeetingSettings.isCodexAvailable(at: codexPath)
        }
        .onChange(of: selectableIDs) { _, ids in selectedIDs.formIntersection(ids) }
        .alert("Не удалось объединить расшифровки", isPresented: Binding(
            get: { summaryError != nil }, set: { if !$0 { summaryError = nil } }
        )) {
            Button("ОК", role: .cancel) { summaryError = nil }
        } message: {
            Text(summaryError ?? "")
        }
        .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
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
                Button("Открыть запись…", systemImage: "document") { queue.chooseFiles() }
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

}

struct MeetingJobView: View {
    let job: MeetingJob
    @ObservedObject var queue: MeetingQueue
    let codexAvailable: Bool
    @Binding var selectedIDs: Set<UUID>
    @State private var hoveredHint: String?

    var body: some View {
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
                Text(hoveredHint ?? (job.state == .done ? (job.output?.summary?.deletingPathExtension().lastPathComponent ?? job.stage) : job.stage))
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
                if job.canSummarize && codexAvailable {
                    Button { queue.summarize(job.id) } label: {
                        Label {
                            Text("Summarize")
                        } icon: {
                            ZStack {
                                Image(systemName: "circle.fill")
                                Image("Summarize", bundle: .module)
                                    .resizable()
                                    .frame(width: 10, height: 10)
                                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                            }
                        }
                    }
                    .buttonStyle(JobActionButtonStyle(hint: "Суммаризировать", hoveredHint: $hoveredHint))
                }
                if let output = job.output {
                    Button("Показать в Finder", systemImage: "magnifyingglass.circle.fill") {
                        NSWorkspace.shared.activateFileViewerSelecting([output.file])
                    }
                    .buttonStyle(JobActionButtonStyle(hint: "Показать в Finder", hoveredHint: $hoveredHint))
                }
                if (job.state == .failed || job.state == .cancelled) && (job.output == nil || codexAvailable) {
                    Button(job.retryTitle, systemImage: "arrow.clockwise.circle.fill") { queue.retry(job.id) }
                        .buttonStyle(JobActionButtonStyle(hint: job.retryTitle, hoveredHint: $hoveredHint))
                }
                Button("Убрать из списка", systemImage: "xmark.circle.fill") { queue.remove(job.id) }
                    .buttonStyle(JobActionButtonStyle(
                        hint: job.state == .running || job.state == .waiting ? "Отменить и убрать из списка" : "Убрать из списка",
                        hoveredHint: $hoveredHint
                    ))
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 14))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(selectedIDs.contains(job.id) ? Color.accentColor.opacity(0.18) : Color.clear)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 58)
                .padding(.trailing, 12)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if NSApp.currentEvent?.modifierFlags.contains(.command) != true, let output = job.output {
                NSWorkspace.shared.open(output.file)
            }
        }
        // Run alongside the double-click gesture so selection does not wait for its timeout.
        .simultaneousGesture(TapGesture().modifiers(.command).onEnded { toggleSelection() })
        .accessibilityAddTraits(selectedIDs.contains(job.id) ? .isSelected : [])
        .accessibilityActions {
            if codexAvailable && job.canSelectForSummary {
                Button(selectedIDs.contains(job.id) ? "Снять выделение" : "Выбрать для общей суммаризации") {
                    toggleSelection()
                }
            }
        }
        .contextMenu {
            if let output = job.output {
                Button(output.summary == nil ? "Открыть расшифровку" : "Открыть резюме") { NSWorkspace.shared.open(output.file) }
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([output.file]) }
                if output.summary != nil {
                    Button("Открыть расшифровку") { NSWorkspace.shared.open(output.transcript) }
                }
            }
            if job.canSummarize && codexAvailable {
                Button("Суммаризировать") { queue.summarize(job.id) }
            }
            if job.state == .running || job.state == .waiting {
                Button("Отменить") { queue.cancel(job.id) }
                    .disabled(job.stage == "Отмена…")
            }
            if (job.state == .failed || job.state == .cancelled) && (job.output == nil || codexAvailable) {
                Button(job.retryTitle) { queue.retry(job.id) }
            }
            Button("Убрать из списка") { queue.remove(job.id) }
        }
    }

    private func toggleSelection() {
        guard codexAvailable && job.canSelectForSummary else { return }
        if selectedIDs.contains(job.id) { selectedIDs.remove(job.id) }
        else { selectedIDs.insert(job.id) }
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
    let hint: String
    @Binding var hoveredHint: String?

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, hint: hint, hoveredHint: $hoveredHint)
    }

    private struct Content: View {
        let configuration: ButtonStyle.Configuration
        let hint: String
        @Binding var hoveredHint: String?
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovered || configuration.isPressed ? .secondary : .tertiary)
                .onHover { hovering in
                    isHovered = hovering
                    if hovering {
                        hoveredHint = hint
                    } else if hoveredHint == hint {
                        hoveredHint = nil
                    }
                }
                .onChange(of: hint) { oldHint, newHint in
                    if isHovered && hoveredHint == oldHint { hoveredHint = newHint }
                }
                .onDisappear {
                    if hoveredHint == hint { hoveredHint = nil }
                }
        }
    }
}

struct MeetingSettingsView: View {
    @AppStorage("outputDirectory") private var output = ""
    @AppStorage("codexPath") private var codex = ""
    @AppStorage("codexModel") private var codexModel = "gpt-6-sol"
    @AppStorage("codexReasoning") private var codexReasoning = "medium"
    @State private var codexAvailable = false

    var body: some View {
        Form {
            Section() {
                pathRow("Папка с результатами", value: $output, directory: true)
            }
            Section("Codex") {
                pathRow("Codex CLI", value: $codex, directory: false)
                Picker("Модель", selection: $codexModel) {
                    ForEach(MeetingSettings.codexModels, id: \.self) { Text($0).tag($0) }
                }
                Picker("Рассуждение", selection: $codexReasoning) {
                    ForEach(MeetingSettings.reasoningLevels, id: \.self) { Text($0).tag($0) }
                }
                Text(codexAvailable
                     ? "Используется текущая авторизация CLI. Текст встречи отправляется в Codex; аудио обрабатывается локально."
                     : "Codex CLI не найден. Для суммаризации встреч установите Codex и авторизуйтесь в нём.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 610, height: 500)
        .task(id: codex) {
            codexAvailable = MeetingSettings.isCodexAvailable(at: codex)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            codexAvailable = MeetingSettings.isCodexAvailable(at: codex)
        }
    }

    private func pathRow(_ title: String, value: Binding<String>, directory: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fixedSize()
                Text(value.wrappedValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(value.wrappedValue)
                    .textSelection(.enabled)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
            .fixedSize()
        }
    }
}
