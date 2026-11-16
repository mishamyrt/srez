import AppKit
import SwiftUI

struct MeetingJobView: View {
    let job: MeetingJob
    @ObservedObject private var queue: MeetingQueue
    let codexAvailable: Bool
    @Binding var selectedIDs: Set<UUID>
    @State private var hoveredHint: String?

    init(
        job: MeetingJob,
        queue: MeetingQueue,
        codexAvailable: Bool,
        selectedIDs: Binding<Set<UUID>>
    ) {
        self.job = job
        self.queue = queue
        self.codexAvailable = codexAvailable
        _selectedIDs = selectedIDs
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: job.input.path))
                .resizable()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.input.lastPathComponent)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.input.lastPathComponent)
                    .textSelection(.enabled)
                if job.state == .running {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .accessibilityLabel("Прогресс обработки")
                }
                Text(hoveredHint ??
                    (job
                        .state == .done ?
                        (job.output?.summary?.deletingPathExtension()
                            .lastPathComponent ?? job
                            .stage) : job.stage))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error = job.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if job.transcript != nil,
                   job.state == .failed || job.state == .cancelled
                {
                    Text("Расшифровка сохранена в памяти до закрытия приложения.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if job.canSummarize, codexAvailable {
                    Button { queue.summarize(job.id) } label: {
                        Label {
                            Text("Summarize")
                        } icon: {
                            ZStack {
                                Image(systemName: "circle.fill")
                                Image("Summarize", bundle: .module)
                                    .resizable()
                                    .frame(width: 10, height: 10)
                                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                            }
                        }
                    }
                    .buttonStyle(JobActionButtonStyle(
                        hint: "Суммаризировать",
                        hoveredHint: $hoveredHint
                    ))
                }
                if let output = job.output {
                    Button(
                        "Показать в Finder",
                        systemImage: "magnifyingglass.circle.fill"
                    ) {
                        NSWorkspace.shared.activateFileViewerSelecting([output.file])
                    }
                    .buttonStyle(JobActionButtonStyle(
                        hint: "Показать в Finder",
                        hoveredHint: $hoveredHint
                    ))
                }
                if job.state == .failed || job.state == .cancelled,
                   job.output == nil || codexAvailable
                {
                    Button(job.retryTitle, systemImage: "arrow.clockwise.circle.fill") {
                        queue.retry(job.id)
                    }
                    .buttonStyle(JobActionButtonStyle(
                        hint: job.retryTitle,
                        hoveredHint: $hoveredHint
                    ))
                }
                Button("Убрать из списка", systemImage: "xmark.circle.fill") {
                    queue.remove(job.id)
                }
                .buttonStyle(JobActionButtonStyle(
                    hint: job.state == .running || job
                        .state == .waiting ? "Отменить и убрать из списка" :
                        "Убрать из списка",
                    hoveredHint: $hoveredHint
                ))
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 14))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(selectedIDs.contains(job.id) ? Color.accentColor.opacity(0.18) : Color
            .clear)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 58)
                .padding(.trailing, 12)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if NSApp.currentEvent?.modifierFlags.contains(.command) != true,
               let output = job.output
            {
                NSWorkspace.shared.open(output.file)
            }
        }
        // Run alongside the double-click gesture so selection does not wait for its
        // timeout.
        .simultaneousGesture(TapGesture().modifiers(.command)
            .onEnded { toggleSelection() })
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selectedIDs.contains(job.id) ? .isSelected : [])
        .accessibilityActions {
            if codexAvailable, job.canSelectForSummary {
                Button(selectedIDs
                    .contains(job.id) ? "Снять выделение" :
                    "Выбрать для общей суммаризации")
                {
                    toggleSelection()
                }
            }
        }
        .contextMenu {
            if let output = job.output {
                Button(output.summary == nil ? "Открыть расшифровку" : "Открыть резюме") {
                    NSWorkspace.shared.open(output.file)
                }
                Button("Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([output.file])
                }
                if output.summary != nil {
                    Button("Открыть расшифровку") {
                        NSWorkspace.shared.open(output.transcript)
                    }
                }
            }
            if job.canSummarize, codexAvailable {
                Button("Суммаризировать") { queue.summarize(job.id) }
            }
            if job.state == .running || job.state == .waiting {
                Button("Отменить") { queue.cancel(job.id) }
                    .disabled(job.stage == "Отмена…")
            }
            if job.state == .failed || job.state == .cancelled,
               job.output == nil || codexAvailable
            {
                Button(job.retryTitle) { queue.retry(job.id) }
            }
            Button("Убрать из списка") { queue.remove(job.id) }
        }
    }

    private func toggleSelection() {
        guard codexAvailable, job.canSelectForSummary else { return }
        if selectedIDs.contains(job.id) {
            selectedIDs.remove(job.id)
        } else {
            selectedIDs.insert(job.id)
        }
    }
}
