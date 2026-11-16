import AppKit
import SwiftUI

struct MeetingsView: View {
    @ObservedObject private var model: MeetingsViewModel
    @State private var isScrolled = false
    @State private var isOutputHovered = false

    init(model: MeetingsViewModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.jobs) { job in
                        MeetingRowView(
                            job: job,
                            model: model,
                            providerAvailable: model.providerAvailable,
                            selectedIDs: $model.selectedIDs
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
            if !model.selectedIDs.isEmpty {
                HStack {
                    Text("Выбрано: \(model.selectedIDs.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(model.combining ? "Объединение…" : "Суммаризировать вместе") {
                        model.summarizeTogether()
                    }
                    .disabled(model.selectedIDs.count < 2 || !model
                        .providerAvailable || model.combining)
                    .help(
                        "Объединить расшифровки в порядке списка и создать общий конспект"
                    )
                    Button("Снять выделение", systemImage: "xmark") {
                        model.selectedIDs.removeAll()
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
                Text((model.outputDirectory as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.outputDirectory)
                    .textSelection(.enabled)
                Spacer()
                Button("Выбрать папку результатов", systemImage: "folder") {
                    model.chooseOutputDirectory()
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
            model.enqueue(files)
            return true
        }
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification))
        { _ in
            model.refreshSettings()
        }
        .alert("Не удалось объединить расшифровки", isPresented: Binding(
            get: { model.summaryError != nil }, set: {
                if !$0 {
                    model.summaryError = nil
                }
            }
        )) {
            Button("ОК", role: .cancel) { model.summaryError = nil }
        } message: {
            Text(model.summaryError ?? "")
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
                Button("Открыть запись…", systemImage: "document") { model.chooseFiles() }
                    .disabled(model.pickerPresented)
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
