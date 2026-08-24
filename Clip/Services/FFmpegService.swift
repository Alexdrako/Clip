import Foundation

// MARK: - FFmpegService

struct FFmpegService {

    /// Applies clip range / target size / container conversion.
    /// - Parameter onFraction: 0…1 progress of the ffmpeg pass.
    func process(input: URL,
                 format: OutputFormat,
                 targetSizeMB: Int?,
                 clipRange: ClipRange?,
                 onFraction: @escaping @Sendable (Double) -> Void) async throws -> URL {

        let ffmpegPath = try Self.binaryPath()
        let outputExt = format.isAudioOnly ? "mp3" : (format == .webm ? "webm" : (format == .mov ? "mov" : "mp4"))
        let output = input.deletingLastPathComponent()
            .appendingPathComponent(input.deletingPathExtension().lastPathComponent + "_clip." + outputExt)

        var args = ["-y", "-hide_banner", "-loglevel", "error"]

        // Trim before re-encode so target-size math covers only the kept span.
        if let range = clipRange, range.isActive {
            if let start = range.startSeconds { args += ["-ss", String(format: "%.2f", start)] }
            if let end = range.endSeconds {
                args += ["-t", String(format: "%.2f", max(0.1, end - (range.startSeconds ?? 0)))]
            }
        }
        args += ["-i", input.path]

        // Duration probe for bitrate math.
        let duration = try? await probeDuration(of: input)

        if let mb = targetSizeMB {
            // Bitrate budget: (size_bits / duration) split between audio + video.
            let totalBits = Double(mb) * 8_388_608 * ClipConstants.bitrateSafetyFactor
            let audioKbps = format.isAudioOnly ? 192.0 : 128.0
            let seconds = duration ?? 60
            let videoKbps = max(100, totalBits / max(1, seconds) / 1000 - audioKbps)
            if format == .webm {
                args += ["-c:v", "libvpx-vp9", "-b:v", "\(Int(videoKbps))k",
                         "-c:a", "libopus", "-b:a", "\(Int(audioKbps))k"]
            } else if format.isAudioOnly {
                args += ["-c:a", "libmp3lame", "-b:a", "\(Int(audioKbps))k"]
            } else {
                args += ["-c:v", "libx264", "-b:v", "\(Int(videoKbps))k",
                         "-preset", "fast", "-pix_fmt", "yuv420p",
                         "-c:a", "aac", "-b:a", "\(Int(audioKbps))k"]
            }
        } else if format == .mp3 {
            args += ["-c:a", "libmp3lame", "-q:a", "0"]
        } else {
            // Container change / trim only — copy streams where possible.
            if !format.isAudioOnly {
                args += ["-c:v", "copy", "-c:a", "copy"]
            }
        }

        args.append(output.path)

        let runner = ProcessRunner(executablePath: ffmpegPath, arguments: args,
                                   environment: YTDLPService.environment())

        // Rough progress from output file growth vs expected size.
        let expectedBytes = targetSizeMB.map { Double($0) * 1_048_576 }
        let watcher = Task.detached { [weak runner] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: output.path),
                      let size = attrs[.size] as? Double else { continue }
                if let expected = expectedBytes, expected > 0 {
                    onFraction(min(size / expected, 0.99))
                } else {
                    onFraction(min(size / 40_000_000, 0.99)) // fallback heuristic
                }
            }
        }

        do {
            _ = try await runner.run(timeout: nil)
        } catch {
            watcher.cancel()
            throw error
        }
        watcher.cancel()
        onFraction(1.0)

        try? FileManager.default.removeItem(at: input) // replace intermediate with processed
        return output
    }

    /// ffprobe duration in seconds.
    func probeDuration(of url: URL) async throws -> Double {
        let ffprobePath = try Self.ffprobeBinaryPath()
        let runner = ProcessRunner(
            executablePath: ffprobePath,
            arguments: ["-v", "error", "-show_entries", "format=duration",
                        "-of", "default=noprint_wrappers=1:nokey=1", url.path],
            environment: YTDLPService.environment())
        let result = try await runner.run(timeout: 15)
        return Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: Paths (critical pattern #1)

    static func binaryPath() throws -> String {
        try bundledExecutable("ffmpeg")
    }

    static func ffprobeBinaryPath() throws -> String {
        try bundledExecutable("ffprobe")
    }

    private static func bundledExecutable(_ name: String) throws -> String {
        let path = Bundle.main.bundlePath + "/Contents/Resources/" + ClipConstants.bundledBinDirName + "/" + name
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ClipError.missingBinary("\(name) not found at \(path)")
        }
        return path
    }
}
