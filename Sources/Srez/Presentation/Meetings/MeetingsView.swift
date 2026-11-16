import AppKit
import SwiftUI

struct MeetingsView: View {
    @ObservedObject private var queue: MeetingQueue
    @AppStorage("outputDirectory") private var outputDirectory = ""
    @AppStorage("codexPath") private var codexPath = ""
    @State private var codexAvailable = false
    @State private var isScrolled = false
    @State private var isOutputHovered = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var summaryError: String?

    init(queue: MeetingQueue) {
        self.queue = queue
    }

    private var selectableIDs: Set<UUID> {
        Set(queue.jobs.filter(\.canSelectForSummary).map(\.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(queue.jobs) { job in
                        MeetingJobView(
                            job: job,
                            queue: queue,
                            codexAvailable: codexAvailable,
                            selectedIDs: $selectedIDs
                        )
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
                    .help(
                        "Объединить расшифровки в порядке списка и создать общий конспект"
                    )
                    Button("Снять выделение", systemImage: "xmark") {
                        selectedIDs.removeAll()
                    }
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
                        panel
                            .directoryURL =
                            URL(fileURLWithPath: (outputDirectory as NSString)
                                    .expandingTildeInPath)
                    }
                    if panel.runModal() == .OK,
                       let url = panel.url
                    {
                        outputDirectory = url.path
                    }
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
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification))
        { _ in
            codexAvailable = MeetingSettings.isCodexAvailable(at: codexPath)
        }
        .onChange(of: selectableIDs) { _, ids in selectedIDs.formIntersection(ids) }
        .alert("Не удалось объединить расшифровки", isPresented: Binding(
            get: { summaryError != nil }, set: {
                if !$0 {
                    summaryError = nil
                }
            }
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
