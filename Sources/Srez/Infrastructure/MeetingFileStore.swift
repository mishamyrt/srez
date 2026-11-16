import Foundation

enum MeetingFileStore {
    static func combineTranscripts(
        _ outputs: [MeetingOutput],
        directory: URL
    ) throws -> MeetingOutput {
        let texts = try outputs.map { output in
            try Task.checkCancellation()
            let text = try String(contentsOf: output.transcript, encoding: .utf8)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingError(
                    message: "Расшифровка «\(output.transcript.lastPathComponent)» пуста. Нет текста для суммаризации."
                )
            }
            return text
        }
        try Task.checkCancellation()
        try prepareOutputDirectory(directory)
        let file = try saveFile(
            texts.joined(separator: "\n\n"),
            title: "Общая расшифровка (\(outputs.count))",
            extension: "raw.txt",
            directory: directory
        )
        return MeetingOutput(transcript: file)
    }

    static func fileStem(_ title: String) -> String {
        let forbidden = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "/\\:"))
        var name = title.components(separatedBy: forbidden).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.lowercased().hasSuffix(".md") {
            name.removeLast(3)
        }
        while name.utf8.count > 180 {
            name.removeLast()
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return name.isEmpty ? "Встреча" : name
    }

    static func save(
        _ summary: MeetingSummary, transcript: URL, directory: URL
    ) throws -> MeetingOutput {
        let file = try saveFile(
            summary.markdown + "\n",
            title: summary.title,
            extension: "md",
            directory: directory
        )
        return MeetingOutput(transcript: transcript, summary: file)
    }

    static func prepareOutputDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard fm.isWritableFile(atPath: directory.path) else {
            throw MeetingError(message: "Нет доступа на запись в папку результатов.")
        }
    }

    static func saveFile(
        _ text: String,
        title: String,
        extension suffix: String,
        directory: URL
    ) throws -> URL {
        let fm = FileManager.default
        let stem = fileStem(title)
        var index = 1
        while true {
            let name = stem + (index == 1 ? "" : " (\(index))")
            let file = directory.appendingPathComponent(name + "." + suffix)
            if fm.fileExists(atPath: file.path) {
                index += 1
                continue
            }
            // Exclusive creation also prevents overwriting a file created after the check
            // above.
            try Data(text.utf8).write(to: file, options: .withoutOverwriting)
            return file
        }
    }
}
