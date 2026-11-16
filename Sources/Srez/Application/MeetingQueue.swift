import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MeetingQueue: ObservableObject {
    @Published var jobs: [MeetingJob] = []
    @Published var pickerPresented = false
    @Published private(set) var combining = false
    private var combinationWorker: Task<MeetingOutput, Error>?
    private let combine: @Sendable ([MeetingOutput], URL) throws -> MeetingOutput

    init(combine: @escaping @Sendable ([MeetingOutput], URL) throws -> MeetingOutput = {
        try MeetingFileStore.combineTranscripts($0, directory: $1)
    }) {
        self.combine = combine
    }

    private var filePanel: NSOpenPanel?
    private let modelStore = ModelStore()
    private var transcriptionWorker: (id: UUID, task: Task<MeetingOutput, Error>)?
    private var summaryWorker: (id: UUID, task: Task<MeetingOutput, Error>)?
    var hasPendingJobs: Bool {
        combining || transcriptionWorker != nil || summaryWorker != nil || jobs
            .contains { $0.state == .waiting || $0.state == .running }
    }

    func chooseFiles() {
        guard !pickerPresented else { return }
        pickerPresented = true
        let panel = NSOpenPanel()
        filePanel = panel
        panel.title = "Выберите запись встречи"
        panel.prompt = "Распознать"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["mp3", "wav", "webm", "mp4", "m4a"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.begin { [weak self] response in
            Task { @MainActor in
                self?.pickerPresented = false
                self?.filePanel = nil
                if response == .OK {
                    self?.enqueue(panel.urls)
                }
            }
        }
    }

    func enqueue(_ urls: [URL]) {
        if pickerPresented {
            filePanel?.cancel(nil)
        }
        for url in urls {
            var job = MeetingJob(input: url)
            if !["mp3", "wav", "webm", "mp4", "m4a"]
                .contains(url.pathExtension.lowercased())
            {
                job.state = .failed
                job.stage = "Неподдерживаемый формат"
                job.error = "Выберите MP3, WAV, WebM, MP4 или M4A."
            }
            jobs.append(job)
        }
        startNext()
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let worker = jobs[index].output == nil ? transcriptionWorker : summaryWorker
        if worker?.id == id {
            jobs[index].stage = "Отмена…"
            worker?.task.cancel()
        } else if jobs[index].state == .waiting {
            jobs[index].state = .cancelled
            jobs[index].stage = "Отменено"
        }
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state == .failed || jobs[index].state == .cancelled
        else { return }
        jobs[index].state = .waiting
        jobs[index].stage = jobs[index].output == nil ? "В очереди" : "В очереди на суммаризацию"
        jobs[index].error = nil
        jobs[index].progress = nil
        startNext()
    }

    func summarize(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].canSummarize else { return }
        jobs[index].state = .waiting
        jobs[index].stage = "В очереди на суммаризацию"
        startNext()
    }

    func cancelCombination() {
        combinationWorker?.cancel()
    }

    func summarizeTogether(_ ids: Set<UUID>) async throws {
        guard !combining else { return }
        let selected = jobs.filter { ids.contains($0.id) && $0.canSelectForSummary }
        guard selected.count > 1, selected.count == ids.count else { return }
        let settings = try MeetingSettings.current(summarizing: true)
        let outputs = selected.compactMap(\.output)
        let combine = combine
        combining = true
        let task = Task.detached(priority: .userInitiated) {
            try combine(outputs, settings.outputDirectory)
        }
        combinationWorker = task
        defer {
            combinationWorker = nil
            combining = false
        }
        let output = try await withTaskCancellationHandler {
            let output = try await task.value
            try Task.checkCancellation()
            if task.isCancelled {
                throw CancellationError()
            }
            return output
        } onCancel: {
            task.cancel()
        }
        var job = MeetingJob(input: output.transcript)
        job.output = output
        job.stage = "В очереди на суммаризацию"
        jobs.append(job)
        startNext()
    }

    func remove(_ id: UUID) {
        cancel(id)
        jobs.removeAll { $0.id == id }
    }

    private func startNext() {
        startNext(summarizing: false)
        startNext(summarizing: true)
    }

    private func startNext(summarizing: Bool) {
        let worker = summarizing ? summaryWorker : transcriptionWorker
        guard worker == nil, let index = jobs.firstIndex(where: {
            $0.state == .waiting && ($0.output != nil) == summarizing
        }) else { return }
        let job = jobs[index]
        let settings = Result { try MeetingSettings.current(summarizing: summarizing) }
        jobs[index].state = .running
        let modelStore = modelStore
        let task = Task.detached(priority: .userInitiated) { [self] in
            let update: @Sendable (MeetingEvent) async -> Void = { event in
                await self.receive(event, for: job.id)
            }
            if let output = job.output {
                return try await SummarizationService(provider: SummaryProviderFactory
                    .make(settings.get().provider)).summarize(
                    output,
                    directory: settings.get().outputDirectory,
                    update: update
                )
            }
            return try await TranscriptionService(modelStore: modelStore).run(
                input: job.input,
                settings: settings.get(),
                transcript: job.transcript,
                update: update
            )
        }
        if summarizing {
            summaryWorker = (job.id, task)
        } else {
            transcriptionWorker = (job.id, task)
        }
        Task {
            let result = await task.result
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index].progress = nil
                switch result {
                case let .success(output):
                    jobs[index].state = .done
                    jobs[index].stage = output.summary == nil ? "Расшифровка готова" : "Готово"
                    jobs[index].output = output
                    jobs[index].transcript = nil
                case let .failure(error):
                    jobs[index].state = error is CancellationError ? .cancelled : .failed
                    jobs[index].stage = error is CancellationError ? "Отменено" : "Ошибка"
                    jobs[index].error = error is CancellationError ? nil : error
                        .localizedDescription
                }
            }
            if summarizing {
                summaryWorker = nil
            } else {
                if !jobs.contains(where: { $0.state == .waiting && $0.output == nil }) {
                    await modelStore.unload()
                }
                transcriptionWorker = nil
            }
            startNext(summarizing: summarizing)
        }
    }

    private func receive(_ event: MeetingEvent, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case let .stage(stage):
            jobs[index].stage = stage
            jobs[index].progress = nil
        case let .progress(value): jobs[index].progress = value
        case let .transcript(text): jobs[index].transcript = text
        }
    }
}
