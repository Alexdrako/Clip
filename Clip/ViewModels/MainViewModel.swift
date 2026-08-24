import Foundation
import SwiftUI

// MARK: - Output options shared by UI + services

enum OutputFormat: String, CaseIterable, Identifiable {
    case mp4, mov, webm, mp3
    var id: String { rawValue }
    var isAudioOnly: Bool { self == .mp3 }
}

enum TargetResolution: String, CaseIterable, Identifiable {
    case p2160 = "4K", p1440 = "1440p", p1080 = "1080p"
    case p720 = "720p", p480 = "480p", p360 = "360p"

    var id: String { rawValue }
    var height: Int {
        switch self {
        case .p2160: return 2160
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        case .p360: return 360
        }
    }
}

/// User-selected in/out points. `nil` bounds mean "from start" / "to end".
struct ClipRange: Equatable, Codable {
    var startSeconds: Double?
    var endSeconds: Double?

    var isActive: Bool { startSeconds != nil || endSeconds != nil }
}

// MARK: - MainViewModel

@MainActor
final class MainViewModel: ObservableObject {
    @Published var urlText = ""
    @Published var metadata: VideoMetadata?
    @Published var isAnalyzing = false
    @Published var analysisError: String?
    @Published var selectedFormat: OutputFormat = .mp4
    @Published var selectedResolution: TargetResolution = .p1080
    @Published var targetSizeMB: Int?
    @Published var customSizeText = ""
    @Published var clipEnabled = false
    @Published var clipRange = ClipRange(startSeconds: nil, endSeconds: nil)

    private let ytdlp = YTDLPService.shared

    var detectedURL: URL? {
        URLDetector.firstURL(in: urlText)
    }

    var canAnalyze: Bool {
        detectedURL != nil && !isAnalyzing
    }

    func pasteFromClipboard() {
        if let string = NSPasteboard.general.string(forType: .string) {
            urlText = string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func analyze() async {
        guard let url = detectedURL else { return }
        isAnalyzing = true
        analysisError = nil
        defer { isAnalyzing = false }
        do {
            // Reddit extractor in yt-dlp is broken — resolve via api.reddit.com first.
            let effectiveURL = (Platform.detect(from: url) == .reddit)
                ? await RedditResolver.resolveDirectMediaURL(url) ?? url
                : url
            metadata = try await ytdlp.fetchMetadata(url: effectiveURL)
        } catch {
            analysisError = error.localizedDescription
            metadata = nil
        }
    }

    func reset() {
        urlText = ""
        metadata = nil
        analysisError = nil
        targetSizeMB = nil
        customSizeText = ""
        clipEnabled = false
        clipRange = ClipRange(startSeconds: nil, endSeconds: nil)
    }

    /// Builds a queue-ready item from current UI state.
    func makeDownloadItem() -> DownloadItem? {
        guard let url = detectedURL else { return nil }
        let size = Int(customSizeText).flatMap { $0 > 0 ? $0 : nil } ?? targetSizeMB
        let range = clipEnabled ? clipRange : nil
        return DownloadItem(
            url: url,
            metadata: metadata,
            format: selectedFormat,
            resolution: selectedResolution,
            targetSizeMB: size,
            clipRange: range
        )
    }
}
