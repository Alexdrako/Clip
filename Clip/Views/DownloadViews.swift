import SwiftUI

// MARK: - DownloadSection

struct DownloadSection: View {
    @EnvironmentObject private var mainVM: MainViewModel
    @EnvironmentObject private var downloadVM: DownloadViewModel

    var body: some View {
        Button {
            if let item = mainVM.makeDownloadItem() {
                downloadVM.enqueue(item)
                withAnimation(.easeInOut(duration: 0.2)) { mainVM.reset() }
            }
        } label: {
            Label("Download", systemImage: "arrow.down.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(GlassPillButtonStyle(filled: true))
        .disabled(mainVM.detectedURL == nil)
    }
}

// MARK: - Segmented lists (Downloads / History)

struct SegmentedLists: View {
    @EnvironmentObject private var downloadVM: DownloadViewModel

    var body: some View {
        GlassCard {
            VStack(spacing: 12) {
                // Glass segmented tabs
                HStack(spacing: 4) {
                    segmentButton("Downloads", tag: "downloads")
                    segmentButton("History", tag: "history")
                }
                .padding(3)
                .background(Capsule().fill(Color.primary.opacity(0.05)))

                switch downloadVM.selectedTab {
                case "downloads": DownloadList().transition(.opacity)
                default: HistoryView().transition(.opacity)
                }
            }
            .padding(10)
            .animation(.easeInOut(duration: 0.2), value: downloadVM.selectedTab)
        }
    }

    private func segmentButton(_ title: String, tag: String) -> some View {
        let selected = downloadVM.selectedTab == tag
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { downloadVM.selectedTab = tag }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
                        .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 3, x: 0, y: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - DownloadList

struct DownloadList: View {
    @EnvironmentObject private var downloadVM: DownloadViewModel

    var body: some View {
        VStack(spacing: 8) {
            if downloadVM.items.isEmpty {
                Text("No downloads yet")
                    .font(.system(size: 13))
                    .foregroundStyle(ClipTheme.secondary)
                    .padding(.vertical, 18)
            } else {
                ForEach(downloadVM.items) { item in
                    DownloadRow(item: item)
                }
                if downloadVM.items.contains(where: { !$0.state.isActive }) {
                    Button("Clear finished") {
                        withAnimation { downloadVM.clearFinished() }
                    }
                    .buttonStyle(GhostPillButtonStyle())
                }
            }
        }
    }
}

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    @EnvironmentObject private var downloadVM: DownloadViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.platform.symbolName)
                .foregroundStyle(ClipTheme.platformTint(item.platform))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                GlassProgressBar(fraction: item.progress, tint: item.progressTint)
                HStack(spacing: 6) {
                    Text(item.state.label)
                        .font(.system(size: 11))
                        .foregroundStyle(item.state.isFinished ? ClipTheme.success : ClipTheme.secondary)
                        .lineLimit(1)
                    if !item.statusText.isEmpty && item.state.isActive {
                        Text("· \(item.statusText)")
                            .font(.system(size: 11))
                            .foregroundStyle(ClipTheme.secondary)
                    }
                }
            }

            Spacer()

            if item.state.isActive || item.state == .queued {
                Button {
                    downloadVM.cancel(item)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(ClipTheme.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel")
            } else if item.state.isFinished, let path = item.outputPath,
                      let url = URL(string: path) ?? URL(fileURLWithPath: path).fileURLIfExist {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "folder")
                        .foregroundStyle(ClipTheme.accent)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            } else if case .failed = item.state {
                Button {
                    downloadVM.remove(item)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(ClipTheme.coral)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: ClipConstants.smallCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }
}

// MARK: - HistoryView

struct HistoryView: View {
    @EnvironmentObject private var downloadVM: DownloadViewModel

    var body: some View {
        VStack(spacing: 8) {
            if downloadVM.historyEntries.isEmpty {
                Text("History is empty")
                    .font(.system(size: 13))
                    .foregroundStyle(ClipTheme.secondary)
                    .padding(.vertical, 18)
            } else {
                ForEach(downloadVM.historyEntries) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.platform.symbolName)
                            .foregroundStyle(ClipTheme.platformTint(entry.platform))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text(entry.date, style: .date)
                                .font(.system(size: 11))
                                .foregroundStyle(ClipTheme.secondary)
                        }
                        Spacer()
                        Text(entry.formatRaw.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ClipTheme.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Button("Clear history") { downloadVM.clearHistory() }
                    .buttonStyle(GhostPillButtonStyle())
            }
        }
    }
}

// MARK: - SaveLocation (settings footer info)

struct SaveLocation: View {
    var body: some View {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.gearshape")
                .foregroundStyle(ClipTheme.secondary)
            Text("Saves to \(downloads.path)")
                .font(.system(size: 11))
                .foregroundStyle(ClipTheme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private extension URL {
    /// Convenience so `URL(string:) ?? …` compiles for file paths with spaces.
    var fileURLIfExist: URL? {
        FileManager.default.fileExists(atPath: path) ? self : nil
    }
}
