import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MeetingJob: Identifiable {
    enum State { case waiting, running, done, failed, cancelled }
    let id = UUID()
    let input: URL
    var state = State.waiting
    var stage = "В очереди"
    var progress: Double?
    var transcript: String?
    var output: MeetingOutput?
    var error: String?
}

@MainActor
final class MeetingQueue: ObservableObject {
    @Published var jobs: [MeetingJob] = []
    @Published var pickerPresented = false
    private var filePanel: NSOpenPanel?
    private var worker: Task<MeetingOutput, Error>?
    private var activeID: UUID?
    var hasPendingJobs: Bool { jobs.contains { $0.state == .waiting || $0.state == .running } }

    func chooseFiles() {
        guard !pickerPresented else { return }
        pickerPresented = true
        let panel = NSOpenPanel()
        filePanel = panel
        panel.title = "Выберите запись встречи"
        panel.prompt = "Распознать"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["mp3", "wav", "webm", "mp4"].compactMap { UTType(filenameExtension: $0) }
        panel.begin { [weak self] response in
            Task { @MainActor in
                self?.pickerPresented = false
                self?.filePanel = nil
                if response == .OK { self?.enqueue(panel.urls) }
            }
        }
    }

    func enqueue(_ urls: [URL]) {
        if pickerPresented { filePanel?.cancel(nil) }
        for url in urls {
            var job = MeetingJob(input: url)
            if !["mp3", "wav", "webm", "mp4"].contains(url.pathExtension.lowercased()) {
                job.state = .failed
                job.stage = "Неподдерживаемый формат"
                job.error = "Выберите MP3, WAV, WebM или MP4."
            }
            jobs.append(job)
        }
        startNext()
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if id == activeID {
            jobs[index].stage = "Отмена…"
            worker?.cancel()
        } else if jobs[index].state == .waiting {
            jobs[index].state = .cancelled
            jobs[index].stage = "Отменено"
        }
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state == .failed || jobs[index].state == .cancelled else { return }
        jobs[index].state = .waiting
        jobs[index].stage = "В очереди"
        jobs[index].error = nil
        jobs[index].progress = nil
        startNext()
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .cancelled && $0.transcript == nil }
    }

    private func startNext() {
        guard worker == nil, let index = jobs.firstIndex(where: { $0.state == .waiting }) else { return }
        let job = jobs[index]
        let settings = Result { try MeetingSettings.current() }
        jobs[index].state = .running
        activeID = job.id
        let task = Task.detached(priority: .userInitiated) { [self] in
            try await MeetingPipeline.run(input: job.input, settings: settings.get(), transcript: job.transcript) { event in
                await self.receive(event, for: job.id)
            }
        }
        worker = task
        Task {
            let result = await task.result
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index].progress = nil
                switch result {
                case .success(let output):
                    jobs[index].state = .done
                    jobs[index].stage = "Готово"
                    jobs[index].output = output
                    jobs[index].transcript = nil
                case .failure(let error):
                    jobs[index].state = error is CancellationError ? .cancelled : .failed
                    jobs[index].stage = error is CancellationError ? "Отменено" : "Ошибка"
                    jobs[index].error = error is CancellationError ? nil : error.localizedDescription
                }
            }
            worker = nil
            activeID = nil
            startNext()
        }
    }

    private func receive(_ event: MeetingEvent, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .stage(let stage):
            jobs[index].stage = stage
            jobs[index].progress = nil
        case .progress(let value): jobs[index].progress = value
        case .transcript(let text): jobs[index].transcript = text
        }
    }
}
