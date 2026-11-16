import Foundation

@MainActor
final class AppDependencies {
    let settingsStore: SettingsStore
    let coordinator: MeetingCoordinator
    let meetings: MeetingsViewModel
    let settings: SettingsViewModel

    init(store: SettingsStore? = nil) {
        let store = store ?? SettingsStore()
        store.registerDefaults()
        settingsStore = store
        coordinator = MeetingCoordinator(
            transcription: TranscriptionService(modelStore: ModelStore()),
            settings: { try await store.current(summarizing: $0 == .summarization) },
            makeProvider: { SummaryProviderFactory.make($0) }
        )
        meetings = MeetingsViewModel(coordinator: coordinator, settings: store)
        settings = SettingsViewModel(store: store)
    }
}
