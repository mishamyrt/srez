import AppKit
import SwiftUI

struct MeetingSettingsView: View {
    @AppStorage("outputDirectory") private var output = ""
    @AppStorage("codexPath") private var codex = ""
    @AppStorage("codexModel") private var codexModel = "gpt-6-sol"
    @AppStorage("codexReasoning") private var codexReasoning = "medium"
    @State private var codexAvailable = false

    var body: some View {
        Form {
            Section {
                pathRow("Папка с результатами", value: $output, directory: true)
            }
            Section("Codex") {
                pathRow("Codex CLI", value: $codex, directory: false)
                Picker("Модель", selection: $codexModel) {
                    ForEach(MeetingSettings.codexModels, id: \.self) { Text($0).tag($0) }
                }
                Picker("Рассуждение", selection: $codexReasoning) {
                    ForEach(MeetingSettings.reasoningLevels, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Text(codexAvailable
                    ? "Используется текущая авторизация CLI. Текст встречи отправляется в Codex; аудио обрабатывается локально."
                    :
                    "Codex CLI не найден. Для суммаризации встреч установите Codex и авторизуйтесь в нём.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 610, height: 500)
        .task(id: codex) {
            codexAvailable = MeetingSettings.isCodexAvailable(at: codex)
        }
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification))
        { _ in
            codexAvailable = MeetingSettings.isCodexAvailable(at: codex)
        }
    }

    private func pathRow(
        _ title: String,
        value: Binding<String>,
        directory: Bool
    ) -> some View {
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
                    panel
                        .directoryURL =
                        URL(fileURLWithPath: (value.wrappedValue as NSString)
                                .expandingTildeInPath)
                }
                if panel.runModal() == .OK,
                   let url = panel.url
                {
                    value.wrappedValue = url.path
                }
            }
            .fixedSize()
        }
    }
}
