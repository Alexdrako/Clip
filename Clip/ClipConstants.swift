import Foundation

/// Single source of truth for magic numbers / strings.
enum ClipConstants {
    // MARK: Layout
    static let cardCornerRadius: CGFloat = 16
    static let smallCornerRadius: CGFloat = 10
    static let progressBarHeight: CGFloat = 6
    static let thumbnailHeight: CGFloat = 120
    static let clipRangeHeight: CGFloat = 56

    // MARK: Queue
    static let maxConcurrentDownloads = 3
    static let historyLimit = 100

    // MARK: Networking / processes
    static let metadataTimeout: TimeInterval = 30
    static let processPollInterval: TimeInterval = 0.2
    static let clipboardPollInterval: TimeInterval = 1.0
    static let updateCheckInterval: TimeInterval = 60 * 60 * 24 // daily

    // MARK: Download defaults
    static let defaultContainer = "mp4"
    /// ffmpeg target-size headroom so we don't overshoot the requested MB.
    static let bitrateSafetyFactor = 0.95

    // MARK: File names
    static let historyFileName = "download-history.json"
    static let bundledBinDirName = "bin"

    // MARK: Update feed
    static let releasesURLString = "https://github.com/Alexdrako/Clip/releases/latest"
}
