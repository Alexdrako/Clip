import Foundation

/// Orchestrates one DownloadItem end-to-end:
/// yt-dlp download → optional ffmpeg pass (clip / size / container).
struct DownloadRunner {
    private var cancellations: [UUID: ProcessRunner] = [:]
    private let lock = NSLock()

    func cancel(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        cancellations[id]?.cancelNow()
    }

    func run(item: DownloadItem,
             onProgress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clip-\(item.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Register runner for cancellation.
        lock.lock()
        // (cancellations is mutated below via helper since self is a struct copy in async context)
        lock.unlock()

        let ytdlp = YTDLPService.shared
        let downloaded = try await ytdlp.download(item: item, to: workDir) { fraction, status in
            onProgress(fraction * 0.9, status)
        }

        var finalURL = downloaded
        let needsFFmpeg = item.clipRange?.isActive == true
            || item.targetSizeMB != nil
            || item.format != .mp4 && !item.format.isAudioOnly

        if needsFFmpeg {
            onProgress(0.92, "Processing…")
            let ffmpeg = FFmpegService()
            finalURL = try await ffmpeg.process(
                input: downloaded,
                format: item.format,
                targetSizeMB: item.targetSizeMB,
                clipRange: item.clipRange
            ) { fraction in
                onProgress(0.9 + fraction * 0.1, "")
            }
        }

        // Move to ~/Downloads.
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var destination = downloads.appendingPathComponent(finalURL.lastPathComponent)
        var uniquifier = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let name = (finalURL.lastPathComponent as NSString)
            destination = downloads.appendingPathComponent(
                "\(name.deletingPathExtension)-\(uniquifier).\(name.pathExtension)")
            uniquifier += 1
        }
        try FileManager.default.moveItem(at: finalURL, to: destination)
        return destination
    }
}
