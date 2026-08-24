import SwiftUI

// MARK: - MenuBarView (two-step popover flow)

struct MenuBarView: View {
    @StateObject private var mainVM = MainViewModel()
    @StateObject private var downloadVM = DownloadViewModel()

    let openMainWindow: () -> Void
    let pasteAndAnalyze: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Step 1 — paste
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(ClipTheme.secondary)
                TextField("Paste link…", text: $mainVM.urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                Button {
                    Task { await mainVM.analyze() }
                } label: {
                    Image(systemName: "sparkle.magnifyingglass")
                }
                .buttonStyle(GhostPillButtonStyle())
                .disabled(!mainVM.canAnalyze)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: ClipConstants.smallCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

        // Step 2 — configure after analyze
            if let metadata = mainVM.metadata {
                VStack(alignment: .leading, spacing: 8) {
                    Text(metadata.displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    FormatPicker()
                }
                .transition(.opacity)
            }

            if mainVM.isAnalyzing {
                StatusBar(text: "Analyzing…")
            }

            Spacer()

            DownloadSection()

            HStack {
                Button("Open Clip", action: openMainWindow)
                    .buttonStyle(GhostPillButtonStyle())
                Spacer()
                Text("⌘V to paste & analyze")
                    .font(.system(size: 10))
                    .foregroundStyle(ClipTheme.secondary)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity)
        .background(TranslucentWindowBackground())
        .onAppear(perform: pasteAndAnalyzeSync)
        .onReceive(NotificationCenter.default.publisher(for: .clipPasteRequested)) { _ in
            mainVM.pasteFromClipboard()
            Task { await mainVM.analyze() }
        }
    }

    private func pasteAndAnalyzeSync() { /* popover appears with empty field */ }
}

// MARK: - SettingsView

struct SettingsView: View {
    @AppStorage("autoClipboardDetect") private var autoClipboardDetect = true
    @AppStorage("checkUpdatesDaily") private var checkUpdatesDaily = true
    @AppStorage("maxConcurrent") private var maxConcurrent = ClipConstants.maxConcurrentDownloads

    var body: some View {
        Form {
            Section("General") {
                Toggle("Auto-detect video links in clipboard", isOn: $autoClipboardDetect)
                Toggle("Check for updates daily", isOn: $checkUpdatesDaily)
                Stepper("Concurrent downloads: \(maxConcurrent)", value: $maxConcurrent, in: 1...5)
            }
            Section("Storage") {
                SaveLocation()
            }
            Section("About") {
                LabeledContent("Version",
                               value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                LabeledContent("Engine", value: "yt-dlp + ffmpeg (bundled)")
            }
        }
        .formStyle(.grouped)
    }
}
