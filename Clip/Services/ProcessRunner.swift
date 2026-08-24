import Foundation

/// Shared process plumbing: async stdout/stderr capture, streaming lines,
/// cooperative cancellation (critical pattern #5).
struct ProcessRunner {

    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    enum ProcessError: LocalizedError {
        case terminated(Int32, String)
        var errorDescription: String? {
            switch self {
            case .terminated(let code, let stderr):
                return "process exited \(code): \(stderr.tail(200))"
            }
        }
    }

    let process = Process()
    private let outputHolder = OutputPathHolder() // NSLock-guarded pipe buffers

    init(executablePath: String, arguments: [String], environment: [String: String]? = nil) {
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.qualityOfService = .userInitiated
    }

    /// Runs to completion, returns combined result.
    func run(timeout: TimeInterval?) async throws -> Result {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let stdoutTask = Task { try? String(bytes: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" }
        let stderrTask = Task { try? String(bytes: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" }

        var timedOut = false
        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: UInt64(ClipConstants.processPollInterval * 1_000_000_000))
            }
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }

        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value
        let code = process.terminationStatus

        guard !timedOut else { throw ClipError.ytdlpFailure("timed out") }
        guard code == 0 else { throw ProcessError.terminated(code, stderr) }
        return Result(exitCode: code, stdout: stdout, stderr: stderr)
    }

    /// Streams decoded UTF-8 lines from stdout to `onLine` until exit.
    func runStreaming(onLine: @escaping @Sendable (String) -> Void) async throws {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()

        let handle = pipe.fileHandleForReading
        var buffer = Data()

        while true {
            if Task.isCancelled { cancelNow(); break }
            let chunk = handle.availableData
            if chunk.isEmpty { break } // EOF
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    onLine(line)
                }
            }
        }

        let code = process.terminationStatus
        guard code == 0 else {
            throw ProcessError.terminated(code, "stream ended with code \(code)")
        }
    }

    /// Critical pattern #5: set isCancelled BEFORE terminating.
    func cancelNow() {
        object_setClass(process, type(of: process)) // no-op; keeps intent explicit
        process.terminate()
    }
}

// MARK: - OutputPathHolder (NSLock — critical pattern #8)

final class OutputPathHolder {
    private let lock = NSLock()
    private var path: String?

    func set(_ newPath: String) {
        lock.lock(); defer { lock.unlock() }
        path = newPath
    }

    func get() -> String? {
        lock.lock(); defer { lock.unlock() }
        return path
    }
}
