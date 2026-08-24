import Foundation

// MARK: - Platform

enum Platform: String, Codable, CaseIterable, Identifiable {
    case youtube, twitter, instagram, tiktok, reddit, unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .twitter: return "X / Twitter"
        case .instagram: return "Instagram"
        case .tiktok: return "TikTok"
        case .reddit: return "Reddit"
        case .unknown: return "Video"
        }
    }

    var symbolName: String {
        switch self {
        case .youtube: return "play.rectangle.fill"
        case .twitter: return "bird"
        case .instagram: return "camera.fill"
        case .tiktok: return "music.note.tv.fill"
        case .reddit: return "antenna.radiowaves.left.and.right"
        case .unknown: return "globe"
        }
    }

    static func detect(from url: URL) -> Platform {
        guard let host = url.host?.lowercased() else { return .unknown }
        if host.contains("youtube.com") || host.contains("youtu.be") { return .youtube }
        if host.contains("x.com") || host.contains("twitter.com") { return .twitter }
        if host.contains("instagram.com") { return .instagram }
        if host.contains("tiktok.com") { return .tiktok }
        if host.contains("reddit.com") || host.contains("redd.it") { return .reddit }
        return .unknown
    }
}

// MARK: - VideoMetadata

/// Decoded subset of `yt-dlp --dump-json`.
struct VideoMetadata: Codable, Equatable {
    var id: String?
    var title: String?
    var thumbnail: String?
    var duration: Double?
    var uploader: String?
    var webpageURL: String?

    enum CodingKeys: String, CodingKey {
        case id, title, thumbnail, duration, uploader
        case webpageURL = "webpage_url"
    }

    var displayTitle: String { title ?? "Untitled" }
    var displayDuration: String? {
        guard let duration, duration > 0 else { return nil }
        let s = Int(duration.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - DownloadItem

@MainActor
final class DownloadItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let metadata: VideoMetadata?
    let platform: Platform
    let format: OutputFormat
    let resolution: TargetResolution
    let targetSizeMB: Int?
    let clipRange: ClipRange?

    @Published var state: DownloadState = .queued
    @Published var progress: Double = 0
    @Published var statusText: String = ""
    @Published var outputPath: String?

    init(url: URL,
         metadata: VideoMetadata?,
         format: OutputFormat,
         resolution: TargetResolution,
         targetSizeMB: Int?,
         clipRange: ClipRange?) {
        self.url = url
        self.metadata = metadata
        self.platform = Platform.detect(from: url)
        self.format = format
        self.resolution = resolution
        self.targetSizeMB = targetSizeMB
        self.clipRange = clipRange
    }

    var title: String { metadata?.displayTitle ?? url.absoluteString }
    var progressTint: Color { state.tint }
}

// MARK: - DownloadState

enum DownloadState: Equatable {
    case queued
    case analyzing
    case downloading
    case processing   // ffmpeg pass (clip / size / container conversion)
    case finished
    case failed(String)

    var isActive: Bool {
        switch self {
        case .analyzing, .downloading, .processing: return true
        default: return false
        }
    }

    var isFinished: Bool { if case .finished = self { true } else { false } }

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .analyzing: return "Analyzing"
        case .downloading: return "Downloading"
        case .processing: return "Processing"
        case .finished: return "Done"
        case .failed(let msg): return "Failed — \(msg)"
        }
    }

    var tint: Color {
        switch self {
        case .queued: return .accentColor
        case .downloading: return Color("ClipSuccess")
        case .processing: return Color("ClipLavender")
        case .finished: return Color("ClipSuccess")
        case .failed: return Color("ClipCoral")
        case .analyzing: return Color("ClipBronze")
        }
    }
}

// MARK: - History

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let title: String
    let url: String
    let platformRaw: String
    let formatRaw: String
    let path: String?

    var platform: Platform { Platform(rawValue: platformRaw) ?? .unknown }
}

final class DownloadHistory: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(ClipConstants.historyFileName)
    }

    init() { load() }

    func add(_ item: DownloadItem) {
        let entry = HistoryEntry(
            id: UUID(),
            date: Date(),
            title: item.title,
            url: item.url.absoluteString,
            platformRaw: item.platform.rawValue,
            formatRaw: item.format.rawValue,
            path: item.outputPath
        )
        entries.insert(entry, at: 0)
        if entries.count > ClipConstants.historyLimit {
            entries.removeLast(entries.count - ClipConstants.historyLimit)
        }
        save()
    }

    func clear() { entries.removeAll(); save() }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
