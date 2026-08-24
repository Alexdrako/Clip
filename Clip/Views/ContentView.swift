import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject private var mainVM: MainViewModel
    @EnvironmentObject private var downloadVM: DownloadViewModel
    @State private var updateService = UpdateService()

    var body: some View {
        ZStack {
            TranslucentWindowBackground()
            LinearGradient(
                colors: [ClipTheme.lavender.opacity(0.10),
                         ClipTheme.rosewood.opacity(0.06),
                         ClipTheme.bronze.opacity(0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    if updateService.updateAvailable { UpdateBanner(service: updateService) }
                    URLInput()
                    if mainVM.isAnalyzing { StatusBar(text: "Analyzing…") }
                    if let error = mainVM.analysisError {
                        StatusBar(text: error, tint: ClipTheme.coral)
                    }
                    if mainVM.metadata != nil { VideoPreview() }
                    FormatPicker()
                    if mainVM.clipEnabled { ClipRange() }
                    DownloadSection()
                    SegmentedLists()
                }
                .padding(20)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipPasteRequested)) { _ in
            mainVM.pasteFromClipboard()
            Task { await mainVM.analyze() }
        }
        .task { updateService.startPeriodicChecks() }
    }
}

// MARK: - URLInput

struct URLInput: View {
    @EnvironmentObject private var mainVM: MainViewModel

    var body: some View {
        GlassCard {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(ClipTheme.secondary)
                TextField("Paste a video link…", text: $mainVM.urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit { Task { await mainVM.analyze() } }

                Button {
                    mainVM.pasteFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.doc")
                }
                .buttonStyle(GhostPillButtonStyle())

                Button {
                    Task { await mainVM.analyze() }
                } label: {
                    Label("Analyze", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(GlassPillButtonStyle(filled: true))
                .disabled(!mainVM.canAnalyze)
            }
            .padding(12)
        }
        .onDrop(of: [.url, .text], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { text, _ in
            if let text {
                DispatchQueue.main.async { mainVM.urlText = text as String }
            }
        }
        return true
    }
}

// MARK: - VideoPreview

struct VideoPreview: View {
    @EnvironmentObject private var mainVM: MainViewModel

    private var platform: Platform? {
        mainVM.detectedURL.map { Platform.detect(from: $0) }
    }

    var body: some View {
        if let metadata = mainVM.metadata {
            GlassCard {
                HStack(spacing: 14) {
                    AsyncImage(url: URL(string: metadata.thumbnail ?? "")) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color.primary.opacity(0.05))
                    }
                    .frame(width: 160, height: ClipConstants.thumbnailHeight)
                    .clipShape(RoundedRectangle(cornerRadius: ClipConstants.smallCornerRadius, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(metadata.displayTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(2)
                        if let uploader = metadata.uploader {
                            Text(uploader)
                                .font(.system(size: 12))
                                .foregroundStyle(ClipTheme.secondary)
                        }
                        if let platform {
                            PlatformBadge(platform: platform,
                                          duration: metadata.displayDuration)
                        }
                    }
                    Spacer()
                }
                .padding(12)
            }
        }
    }
}

struct PlatformBadge: View {
    let platform: Platform
    var duration: String?

    var body: some View {
        HStack(spacing: 6) {
            Label(platform.displayName, systemImage: platform.symbolName)
                .font(.system(size: 11, weight: .medium))
            if let duration {
                Text("· \(duration)")
                    .font(.system(size: 11))
                    .foregroundStyle(ClipTheme.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(ClipTheme.platformTint(platform).opacity(0.15)))
        .foregroundStyle(ClipTheme.platformTint(platform))
    }
}

// MARK: - UpdateBanner

struct UpdateBanner: View {
    @ObservedObject var service: UpdateService

    var body: some View {
        GlassCard {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(ClipTheme.success)
                Text("Version \(service.latestVersion ?? "") is available")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Link("Download", destination: URL(string: ClipConstants.releasesURLString)!)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(10)
        }
    }
}

// MARK: - StatusBar (inline info/error strip)

struct StatusBar: View {
    let text: String
    var tint: Color = ClipTheme.bronze

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}
