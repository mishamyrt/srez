import AppKit
import UniformTypeIdentifiers

@MainActor
final class FileDialogs {
    private var recordingPanel: NSOpenPanel?

    func chooseRecordings(completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        recordingPanel = panel
        panel.title = "Выберите запись встречи"
        panel.prompt = "Распознать"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["mp3", "wav", "webm", "mp4", "m4a"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.begin { [weak self] response in
            Task { @MainActor in
                self?.recordingPanel = nil
                completion(response == .OK ? panel.urls : [])
            }
        }
    }

    func cancelRecordings() {
        recordingPanel?.cancel(nil)
    }

    static func choosePath(
        current: String,
        directory: Bool,
        title: String? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title ?? "Выбрать"
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.canCreateDirectories = directory
        panel.prompt = "Выбрать"
        if !current
            .isEmpty
        {
            panel
                .directoryURL = URL(fileURLWithPath: (current as NSString)
                    .expandingTildeInPath)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
