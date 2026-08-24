import Foundation

// MARK: - UpdateService

@MainActor
final class UpdateService: ObservableObject {
    @Published var updateAvailable: Bool = false
    @Published var latestVersion: String?

    private var timer: Timer?

    func startPeriodicChecks() {
        guard timer == nil else { return }
        checkNow()
        timer = Timer.scheduledTimer(
            withTimeInterval: ClipConstants.updateCheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkNow() }
        }
    }

    func checkNow() {
        Task {
            guard let url = URL(string: ClipConstants.releasesURLString + "/download/latest/appcast.xml") else { return }
            // Minimal check: GitHub releases "latest" redirect → compare tag.
            var request = URLRequest(url: URL(string: ClipConstants.releasesURLString)!)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 10
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  let finalURLString = http.value(forHTTPHeaderField: "Location") ?? http.url?.absoluteString else { return }

            let tag = finalURLString.split(separator: "/").last.map(String.init)
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

            await MainActor.run {
                if let tag, let current, tag.hasPrefix("v"), !tag.dropFirst().hasPrefix(current) {
                    latestVersion = String(tag.dropFirst())
                    updateAvailable = true
                }
            }
        }
    }
}
