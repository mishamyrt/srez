import Foundation

actor MeetingCoordinator {
    private var jobs: [MeetingJob]
    private let transcription: TranscriptionService
    private let settings: @Sendable (MeetingJob.Kind) async throws -> MeetingSettings
    private let combine: @Sendable ([MeetingOutput], URL) throws -> MeetingOutput
    private var transcriptionWorker: (id: UUID, task: Task<MeetingOutput, Error>)?
    private var summaryWorker: (id: UUID, task: Task<MeetingOutput, Error>)?
    private var combinationWorker: Task<MeetingOutput, Error>?
    private var observers: [UUID: AsyncStream<MeetingSnapshot>.Continuation] = [:]

    init(
        jobs: [MeetingJob] = [],
        transcription: TranscriptionService = .init(),
        settings: @escaping @Sendable (MeetingJob.Kind) async throws
            -> MeetingSettings = {
                try MeetingSettings.current(summarizing: $0 == .summarization)
            },
        combine: @escaping @Sendable ([MeetingOutput], URL) throws -> MeetingOutput = {
            try MeetingFileStore.combineTranscripts($0, directory: $1)
        }
    ) {
        self.jobs = jobs
        self.transcription = transcription
        self.settings = settings
        self.combine = combine
    }

    func snapshot() -> MeetingSnapshot {
        MeetingSnapshot(
            jobs: jobs,
            combining: combinationWorker != nil,
            hasPendingJobs: transcriptionWorker != nil || summaryWorker !=
                nil || combinationWorker != nil ||
                jobs
                .contains { $0.state == .waiting || $0.state == .running }
        )
    }

    func updates() -> AsyncStream<MeetingSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MeetingSnapshot>
            .makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield(snapshot())
        continuation
            .onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func publish() {
        for observer in observers.values {
            observer.yield(snapshot())
        }
    }

    func enqueue(_ urls: [URL]) {
        for url in urls {
            var job = MeetingJob(input: url)
            if !["mp3", "wav", "webm", "mp4", "m4a"]
                .contains(url.pathExtension.lowercased())
            {
                job.state = .failed
                job.stage = .unsupportedFormat
                job.error = "Выберите MP3, WAV, WebM, MP4 или M4A."
            }
            jobs.append(job)
        }
        startNext()
        publish()
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        let worker = jobs[index]
            .kind == .transcription ? transcriptionWorker : summaryWorker
        if worker?.id == id {
            jobs[index].stage = .cancelling
            worker?.task.cancel()
        } else if jobs[index].state == .waiting {
            jobs[index].state = .cancelled
            jobs[index].stage = .cancelled
        }
        publish()
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state == .failed || jobs[index].state == .cancelled
        else { return }
        jobs[index].state = .waiting
        jobs[index].stage = jobs[index]
            .kind == .transcription ? .queued : .queuedForSummary
        jobs[index].error = nil
        jobs[index].progress = nil
        startNext()
        publish()
    }

    func summarize(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].canSummarize else { return }
        jobs[index].kind = .summarization
        jobs[index].state = .waiting
        jobs[index].stage = .queuedForSummary
        startNext()
        publish()
    }

    func cancelCombination() {
        combinationWorker?.cancel()
    }

    func summarizeTogether(_ ids: Set<UUID>) async throws {
        guard combinationWorker == nil else { return }
        let selected = jobs.filter { ids.contains($0.id) && $0.canSelectForSummary }
        guard selected.count > 1, selected.count == ids.count else { return }
        let outputs = selected.compactMap(\.output)
        let settings = settings
        let combine = combine
        let task = Task.detached(priority: .userInitiated) {
            let configuration = try await settings(.summarization)
            try Task.checkCancellation()
            return try combine(outputs, configuration.outputDirectory)
        }
        combinationWorker = task
        publish()
        defer { combinationWorker = nil; publish() }
        let output = try await withTaskCancellationHandler {
            let output = try await task.value
            try Task.checkCancellation()
            if task.isCancelled {
                throw CancellationError()
            }
            return output
        } onCancel: { task.cancel() }
        var job = MeetingJob(input: output.transcript)
        job.kind = .summarization
        job.output = output
        job.stage = .queuedForSummary
        jobs.append(job)
        startNext()
    }

    func remove(_ id: UUID) {
        cancel(id); jobs.removeAll { $0.id == id }; publish()
    }

    func cancelAll() {
        for job in jobs
            where job.state == .waiting || job.state == .running
        {
            cancel(job.id)
        }
        cancelCombination()
    }

    func waitUntilIdle() async {
        while snapshot().hasPendingJobs {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func startNext() {
        startNext(kind: .transcription); startNext(kind: .summarization)
    }

    private func startNext(kind: MeetingJob.Kind) {
        let worker = kind == .transcription ? transcriptionWorker : summaryWorker
        guard worker == nil,
              let index = jobs
                  .firstIndex(where: { $0.state == .waiting && $0.kind == kind })
        else { return }
        let job = jobs[index]
        jobs[index].state = .running
        let settings = settings
        let transcription = transcription
        let task = Task.detached(priority: .userInitiated) { [self] in
            let settings = try await settings(kind)
            try Task.checkCancellation()
            let update: @Sendable (MeetingEvent) async -> Void = { await self.receive(
                $0,
                for: job.id
            ) }
            switch kind {
            case .transcription:
                return try await transcription.run(
                    input: job.input,
                    settings: settings,
                    transcript: job.transcript,
                    update: update
                )
            case .summarization:
                guard let output = job.output
                else { throw MeetingError(message: "Нет сохранённой расшифровки.") }
                let service = SummarizationService(provider: SummaryProviderFactory
                    .make(settings.provider))
                return try await service.summarize(
                    output,
                    directory: settings.outputDirectory,
                    update: update
                )
            }
        }
        if kind == .transcription {
            transcriptionWorker = (job.id, task)
        } else {
            summaryWorker = (job.id, task)
        }
        Task { let result = await task.result; await finish(
            job.id,
            kind: kind,
            result: result
        ) }
    }

    private func finish(
        _ id: UUID,
        kind: MeetingJob.Kind,
        result: Result<MeetingOutput, Error>
    ) async {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].progress = nil
            switch result {
            case let .success(output):
                jobs[index].state = .done
                jobs[index].stage = kind == .transcription ? .transcriptReady : .completed
                jobs[index].output = output
                jobs[index].transcript = nil
            case let .failure(error):
                jobs[index].state = error is CancellationError ? .cancelled : .failed
                jobs[index].stage = error is CancellationError ? .cancelled : .failed
                jobs[index].error = error is CancellationError ? nil : error
                    .localizedDescription
            }
        }
        if kind == .transcription {
            if !jobs
                .contains(where: { $0.state == .waiting && $0.kind == .transcription })
            {
                await transcription.unload()
            }
            transcriptionWorker = nil
        } else {
            summaryWorker = nil
        }
        startNext(kind: kind)
        publish()
    }

    private func receive(_ event: MeetingEvent, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case let .stage(stage): jobs[index].stage = stage; jobs[index].progress = nil
        case let .progress(value): jobs[index].progress = value
        case let .transcript(text): jobs[index].transcript = text
        }
        publish()
    }
}
