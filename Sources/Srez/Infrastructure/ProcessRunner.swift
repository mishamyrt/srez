import Darwin
import Foundation

enum ProcessRunner {
    static func run(
        _ executable: URL, arguments: [String], directory: URL, stdin: URL? = nil
    ) async throws {
        try Task.checkCancellation()
        let log = directory.appendingPathComponent("process-\(UUID().uuidString).log")
        FileManager.default.createFile(
            atPath: log.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        let stderr = try FileHandle(forWritingTo: log)
        let input = try stdin.map { try FileHandle(forReadingFrom: $0) }
        defer {
            try? stderr.close()
            try? input?.close()
            try? FileManager.default.removeItem(at: log)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            executable.deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            environment["PATH"] ?? "",
        ]
        .joined(separator: ":")
        process.environment = environment
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        do {
            while process.isRunning {
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
        } catch {
            if process.isRunning {
                process.terminate()
                // Reap before allowing the next queued job to start, even if SIGTERM is
                // ignored.
                await Task.detached {
                    for _ in 0 ..< 20 {
                        if !process.isRunning {
                            break
                        }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    // isRunning already reflects termination; waitUntilExit can block on
                    // Foundation's run loop.
                    while process
                        .isRunning
                    {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }.value
            }
            throw error
        }
        guard process.terminationStatus == 0 else {
            let handle = try FileHandle(forReadingFrom: log)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            try handle.seek(toOffset: length > 6000 ? length - 6000 : 0)
            // Truncation may start inside a UTF-8 sequence; keep the remaining diagnostic
            // readable.
            // swiftlint:disable:next optional_data_string_conversion
            let details = try String(
                decoding: handle.readToEnd() ?? Data(),
                as: UTF8.self
            )
            throw MeetingError(
                message: "\(executable.lastPathComponent) завершился с кодом \(process.terminationStatus).\n\(details)"
            )
        }
    }
}
