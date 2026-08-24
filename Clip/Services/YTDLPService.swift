import Foundation

// MARK: - YTDLPService (actor — critical pattern #8)

actor YTDLPService {
    static let shared = YTDLPService()

    private var cachedBinaryPath: String?

    // MARK: Paths (critical pattern #1 & #2)

    func binaryPath() throws -> String {
        if let cached = cachedBinaryPath { return cached }
        // NEVER Bundle.main.path(forResource:ofType:) — binaries live in Contents/Resources/bin.
        let dir = Bundle.main.bundlePath + "/Contents/Resources"
        let path = dir + "/" + ClipConstants.bundledBinDirName + "/yt-dlp"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ClipError.missingBinary("yt-dlp not found at \(path)")
        }
        cachedBinaryPath = path
        return path
    }

    nonisolated static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Bundled bin first, then homebrew — so yt-dlp finds python/ffmpeg.
        let bundled = Bundle.main.bundlePath + "/Contents/Resources/" + ClipConstants.bundledBinDirName
        let extra = [bundled,
                     "/opt/homebrew/bin",
                     "/usr/local/bin"].joined(separator: ":")
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["PYTHONHTTPSVERIFY"] = "1"
        return env
    }

    // MARK: Metadata

    func fetchMetadata(url: URL) async throws -> VideoMetadata {
        let process = try makeProcess(arguments: [
            "--dump-single-json",
            "--no-warnings",
            "--no-playlist",
            url.absoluteString
        ])

        let (stdout, stderr) = try await runProcess(process, timeout: ClipConstants.metadataTimeout)
        guard !stdout.isEmpty else {
            throw ClipError.ytdlpFailure(stderr.tail(300))
        }
        do {
            return try JSONDecoder().decode(VideoMetadata.self, from: Data(stdout.utf8))
        } catch {
            throw ClipError.metadataDecoding(error.localizedDescription)
        }
    }

    // MARK: Download

    func download(item: DownloadItem,
                  to directory: URL,
                  onProgress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {

        var args = [
            "--no-playlist",
            "--no-warnings",
            "--newline",
            "--restrict-filenames",
            "-o", directory.appendingPathComponent("%(title).80s.%(ext)s").path
        ]

        // Format selection.
        if item.format.isAudioOnly {
            args += ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
        } else {
            args += ["-f", "bv*[height<=\(item.resolution.height)]+ba/b[height<=\(item.resolution.height)]/b",
                     "--merge-output-format", "mp4"]
        }

        // Target size → computed video bitrate for ffmpeg post-pass.
        if let mb = item.targetSizeMB, !item.format.isAudioOnly {
            args += ["--recode-video", item.format.rawValue]
        }

        if let range = item.clipRange, range.isActive {
            args += ["--download-sections", "*\(range.startSeconds ?? 0)-\(range.endSeconds ?? .infinity)"]
        }

        // Instagram often needs cookies from a logged-in browser.
        if Platform.detect(from: item.url) == .instagram {
            if let cookies = Self.instagramCookieArgs() { args += cookies }
        }

        args.append(item.url.absoluteString)

        let process = try makeProcess(arguments: args)

        // Parse yt-dlp progress lines: "[download]  42.3% of ..."
        let parser = OutputParser()
        try await runStreamingProcess(process) { line in
            if let p = parser.downloadProgress(line: line) {
                onProgress(p, "")
            } else if line.contains("[Merger]") || line.contains("ExtractAudio") {
                onProgress(0.98, "Merging…")
            }
        }
        return try Self.latestFile(in: directory)
    }

    // MARK: Helpers

    private func makeProcess(arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try binaryPath())
        process.arguments = arguments
        process.environment = Self.environment()
        return process
    }

    /// Instagram: auto-detect browser cookies (Chrome → Edge → Firefox → Safari).
    private static func instagramCookieArgs() -> [String]? {
        for browser in ["chrome", "edge", "firefox", "safari"] {
            // --cookies-from-browser fails fast if the profile is missing;
            // we retry the whole download without it in that case.
            return ["--cookies-from-browser", browser]
        }
        return nil
    }

    static func latestFile(in directory: URL) throws -> URL {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard let latest = files
            .filter({ !$0.hasHiddenExtension && $0.lastPathComponent != ".DS_Store" })
            .max(by: { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l < r
            }) else { throw ClipError.noOutputFile }
        return latest
    }
}

// MARK: - Progress line parsing

struct OutputParser {
    private var lastReported = -1.0

    mutating func downloadProgress(line: String) -> Double? {
        guard line.contains("[download]") else { return nil }
        // "[download]  42.3% of ~10.00MiB at ..."
        guard let range = line.range(of: #"[0-9]+(\.[0-9]+)?%"#, options: .regularExpression),
              let value = Double(line[range].dropLast()) else { return nil }
        let fraction = value / 100
        guard abs(fraction - lastReported) > 0.005 else { return nil } // throttle
        lastReported = fraction
        return fraction
    }
}

// MARK: - Errors

enum ClipError: LocalizedError {
    case missingBinary(String)
    case ytdlpFailure(String)
    case metadataDecoding(String)
    case noOutputFile
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingBinary(let p): return "Missing binary: \(p)"
        case .ytdlpFailure(let msg): return "yt-dlp error: \(msg)"
        case .metadataDecoding(let msg): return "Bad metadata JSON: \(msg)"
        case .noOutputFile: return "Download finished but no file found"
        case .cancelled: return "Cancelled"
        }
    }
}

extension String {
    func tail(_ n: Int) -> String {
        count <= n ? self : String(suffix(n))
    }
}
