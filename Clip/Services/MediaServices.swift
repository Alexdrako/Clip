import Foundation
import AppKit

// MARK: - URLDetector

enum URLDetector {
    /// First http(s) URL inside arbitrary pasted text.
    static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, range: range)
            .lazy
            .compactMap(\.url)
            .first { $0.scheme == "http" || $0.scheme == "https" }
    }
}

// MARK: - ClipboardMonitor

final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    var onVideoURL: ((URL) -> Void)?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(
            withTimeInterval: ClipConstants.clipboardPollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        guard let text = pb.string(forType: .string),
              let url = URLDetector.firstURL(in: text),
              Platform.detect(from: url) != .unknown || url.pathExtension.isEmpty else { return }

        // Only known video platforms trigger the auto-paste affordance.
        if Platform.detect(from: url) != .unknown {
            onVideoURL?(url)
        }
    }
}

// MARK: - RedditResolver (critical pattern #3)

enum RedditResolver {
    /// yt-dlp's Reddit extractor is broken; hit api.reddit.com ourselves and
    /// pull the direct media URL out of the post JSON.
    static func resolveDirectMediaURL(_ postURL: URL) async -> URL? {
        // Normalize: https://reddit.com/r/x/comments/abc12/… → …/comments/abc12.json
        var components = URLComponents(url: postURL, resolvingAgainstBaseURL: false)
        components?.host = "api.reddit.com"
        var path = components?.path ?? ""
        if path.hasSuffix("/") { path.removeLast() }
        components?.path = path + ".json"

        guard let apiURL = components?.url else { return nil }
        var request = URLRequest(url: apiURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        request.setValue("macOS:Clip:1.0 (by /u/Alexdrako)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let first = json.first as? [String: Any],
              let listing = first["data"] as? [String: Any],
              let children = listing["children"] as? [[String: Any]],
              let child = children.first,
              let postData = child["data"] as? [String: Any] else { return nil }

        // Crosspost fallback chain: media → crosspost_parent → secure_media.
        let candidates: [[String: Any]] = {
            var all = [postData]
            if let parents = postData["crosspost_parent_list"] as? [[String: Any]] {
                all.append(contentsOf: parents)
            }
            return all
        }()

        for candidate in candidates {
            if let redditVideo = candidate["media"] as? [String: Any],
               let rv = redditVideo["reddit_video"] as? [String: Any],
               let fallback = rv["fallback_url"] as? String,
               let url = URL(string: fallback) {
                return url
            }
            if let secure = candidate["secure_media"] as? [String: Any],
               let rv = secure["reddit_video"] as? [String: Any],
               let fallback = rv["fallback_url"] as? String,
               let url = URL(string: fallback) {
                return url
            }
        }
        return nil
    }
}
