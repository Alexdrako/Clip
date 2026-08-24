import Foundation
import SwiftUI

@MainActor
final class DownloadViewModel: ObservableObject {
    @Published var items: [DownloadItem] = []
    @Published private(set) var activeCount = 0

    /// "downloads" | "history" segmented tab.
    @Published var selectedTab = "downloads"

    private let history = DownloadHistory()
    private let runner = DownloadRunner()

    var historyEntries: [HistoryEntry] { history.entries }

    func enqueue(_ item: DownloadItem) {
        withAnimation(.easeInOut(duration: 0.2)) {
            items.insert(item, at: 0)
        }
        startNextQueued()
    }

    func cancel(_ item: DownloadItem) {
        guard item.state.isActive || item.state == .queued else { return }
        // Critical pattern #5: flag first, then terminate the process.
        item.state = .failed("Cancelled")
        runner.cancel(item.id)
        startNextQueued()
    }

    func remove(_ item: DownloadItem) {
        guard !item.state.isActive else { return }
        items.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        items.removeAll { !$0.state.isActive && $0.state != .queued }
    }

    func clearHistory() { history.clear() }

    /// Critical pattern #6: called after every completion/failure/cancel.
    private func startNextQueued() {
        activeCount = items.filter { $0.state.isActive }.count
        guard activeCount < ClipConstants.maxConcurrentDownloads else { return }

        let slots = ClipConstants.maxConcurrentDownloads - activeCount
        let queued = items.filter { $0.state == .queued }.suffix(slots)
        for item in queued {
            Task { await run(item) }
        }
    }

    private func run(_ item: DownloadItem) async {
        item.state = .analyzing
        do {
            let path = try await runner.run(item) { [weak item] progress, status in
                Task { @MainActor in
                    item?.progress = progress
                    item?.statusText = status
                    switch item?.state {
                    case .some(.downloading): break
                    default: item?.state = .downloading
                    }
                }
            }
            item.state = .finished
            item.outputPath = path
            item.progress = 1
            history.add(item)
        } catch {
            if !item.state.isCancelledByUser {
                item.state = .failed(error.localizedDescription)
            }
        }
        startNextQueued()
    }
}

private extension DownloadState {
    /// True when user pressed Cancel (we pre-set .failed("Cancelled")).
    var isCancelledByUser: Bool {
        if case .failed(let msg) = self { return msg == "Cancelled" }
        return false
    }
}
