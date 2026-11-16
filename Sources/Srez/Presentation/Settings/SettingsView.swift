import SwiftUI

struct SettingsView: View {
    @ObservedObject private var model: SettingsViewModel
    init(model: SettingsViewModel) {
        self.model = model
    }

    var body: some View {
        Form {
            Section {
                pathRow(
                    "Папка с результатами",
                    value: $model.outputDirectory,
                    choose: model.chooseOutputDirectory
                )
            }
            Section(model.providerName) {
                pathRow("Codex CLI", value: $model.codexPath, choose: model.chooseCodex)
                Picker("Модель", selection: $model.codexModel) {
                    ForEach(model.models, id: \.self) { Text($0).tag($0) }
                }
                Picker("Рассуждение", selection: $model.codexReasoning) {
                    ForEach(model.reasoningLevels, id: \.self) { Text($0).tag($0) }
                }
                Text(model.providerAvailable
                    ? "Используется текущая авторизация CLI. Текст встречи отправляется в Codex; аудио обрабатывается локально."
                    :
                    "Codex CLI не найден. Для суммаризации встреч установите Codex и авторизуйтесь в нём.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 610, height: 500)
    }

    private func pathRow(
        _ title: String,
        value: Binding<String>,
        choose: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fixedSize()
                Text(value.wrappedValue).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle).help(value.wrappedValue)
                    .textSelection(.enabled)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Button("Выбрать…", action: choose)
        }
    }
}
