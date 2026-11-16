import Combine
import Foundation

@MainActor
final class MeetingsViewModel: ObservableObject {
    @Published private(set) var jobs: [MeetingJob] = []
    @Published private(set) var pickerPresented = false
    @Published private(set) var combining = false
    @Published private(set) var hasPendingJobs = false
    @Published private(set) var providerAvailable = false
    @Published private(set) var outputDirectory = ""
    @Published var selectedIDs: Set<UUID> = []
    @Published var summaryError: String?
    private let coordinator: MeetingCoordinator
    private let dialogs = FileDialogs()
    private let settings: SettingsStore
    private var observation: Task<Void, Never>?
    private var settingsObservation: AnyCancellable?

    init(coordinator: MeetingCoordinator, settings: SettingsStore) {
        self.coordinator = coordinator
        self.settings = settings
        refreshSettings()
        settingsObservation = settings.changes.receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshSettings()
            }
        observation = Task { [weak self, coordinator] in
            for await snapshot in await coordinator.updates() {
                self?.apply(snapshot)
            }
        }
    }

    deinit { observation?.cancel() }

    private func apply(_ snapshot: MeetingSnapshot) {
        jobs = snapshot.jobs
        combining = snapshot.combining
        hasPendingJobs = snapshot.hasPendingJobs
        selectedIDs.formIntersection(jobs.filter(\.canSelectForSummary).map(\.id))
    }

    func refreshSettings() {
        outputDirectory = settings.string("outputDirectory")
        providerAvailable = SummaryProviderFactory.isAvailable(settings.provider)
    }

    func chooseFiles() {
        guard !pickerPresented else { return }
        pickerPresented = true
        dialogs.chooseRecordings { [weak self] urls in
            guard let self else { return }
            pickerPresented = false
            if !urls.isEmpty {
                enqueue(urls)
            }
        }
    }

    func chooseOutputDirectory() {
        if let url = FileDialogs.choosePath(
            current: outputDirectory,
            directory: true,
            title: "Выберите папку результатов"
        ) {
            settings.set(url.path, for: "outputDirectory")
            refreshSettings()
        }
    }

    func enqueue(_ urls: [URL]) {
        if pickerPresented {
            dialogs.cancelRecordings()
        }
        Task { await coordinator.enqueue(urls) }
    }

    func cancel(_ id: UUID) {
        Task { await coordinator.cancel(id) }
    }

    func retry(_ id: UUID) {
        Task { await coordinator.retry(id) }
    }

    func summarize(_ id: UUID) {
        Task { await coordinator.summarize(id) }
    }

    func remove(_ id: UUID) {
        Task { await coordinator.remove(id) }
    }

    func summarizeTogether() {
        let ids = selectedIDs
        Task {
            do { try await coordinator.summarizeTogether(ids); selectedIDs.subtract(ids) }
            catch is CancellationError {}
            catch { summaryError = error.localizedDescription }
        }
    }
}
