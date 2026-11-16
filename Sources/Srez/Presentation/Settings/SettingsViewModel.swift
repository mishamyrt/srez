import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var outputDirectory: String {
        didSet { store.set(
            outputDirectory,
            for: "outputDirectory"
        ) }
    }

    @Published var codexPath: String {
        didSet { store.set(codexPath, for: "codexPath") }
    }

    @Published var codexModel: String {
        didSet { store.set(codexModel, for: "codexModel") }
    }

    @Published var codexReasoning: String {
        didSet { store.set(
            codexReasoning,
            for: "codexReasoning"
        ) }
    }

    @Published private(set) var providerAvailable = false
    private let store: SettingsStore
    private var observation: AnyCancellable?

    var providerName: String {
        SummaryProviderFactory.name(for: store.provider)
    }

    var models: [String] {
        SummaryProviderFactory.models(for: store.provider)
    }

    var reasoningLevels: [String] {
        SummaryProviderFactory.reasoningLevels(for: store.provider)
    }

    init(store: SettingsStore) {
        self.store = store
        outputDirectory = store.string("outputDirectory")
        codexPath = store.string("codexPath")
        codexModel = store.string("codexModel")
        codexReasoning = store.string("codexReasoning")
        refresh()
        observation = store.changes.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        if outputDirectory != store
            .string("outputDirectory")
        {
            outputDirectory = store.string("outputDirectory")
        }
        if codexPath != store
            .string("codexPath")
        {
            codexPath = store.string("codexPath")
        }
        if codexModel != store
            .string("codexModel")
        {
            codexModel = store.string("codexModel")
        }
        if codexReasoning != store
            .string("codexReasoning")
        {
            codexReasoning = store.string("codexReasoning")
        }
        providerAvailable = SummaryProviderFactory.isAvailable(store.provider)
    }

    func chooseOutputDirectory() {
        if let url = FileDialogs.choosePath(
            current: outputDirectory,
            directory: true,
            title: "Выберите папку результатов"
        ) {
            outputDirectory = url.path
        }
    }

    func chooseCodex() {
        if let url = FileDialogs
            .choosePath(current: codexPath, directory: false)
        {
            codexPath = url.path
        }
    }
}
