import AppKit
import Foundation

/// Tells people when a newer JAGBA is out. Checks the GitHub repository named
/// in Info.plist (JAGBARepository, set by build.sh) at most twice a day and
/// links to the release; it never downloads or installs anything itself.
@MainActor
final class AppUpdates: ObservableObject {
    struct Release: Equatable {
        var version: String
        var page: URL
    }

    @Published var available: Release?
    @Published var lastResult: String?

    private let defaults = UserDefaults.standard

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// "owner/name"; JAGBA_REPO overrides it for testing.
    var repository: String? {
        let repo = ProcessInfo.processInfo.environment["JAGBA_REPO"]
            ?? Bundle.main.object(forInfoDictionaryKey: "JAGBARepository") as? String
        return (repo?.contains("/") ?? false) ? repo : nil
    }

    /// Called at launch: checks if the last check was more than 12 hours ago.
    func checkIfDue() async {
        let last = defaults.object(forKey: "lastAppUpdateCheck") as? Date
        guard last.map({ Date().timeIntervalSince($0) > 12 * 3600 }) ?? true else { return }
        await check()
    }

    func check() async {
        guard let repository else { lastResult = "Update checks aren't set up for this build."; return }
        do {
            let release = try await Self.latestRelease(repository: repository)
            defaults.set(Date(), forKey: "lastAppUpdateCheck")
            if Self.isNewer(release.version, than: currentVersion) {
                available = release
                lastResult = "JAGBA \(release.version) is available."
            } else {
                available = nil
                lastResult = "You have the latest version (\(currentVersion))."
            }
        } catch {
            lastResult = "Couldn't check for updates: \(error.localizedDescription)"
        }
    }

    func openRelease() {
        if let page = available?.page { NSWorkspace.shared.open(page) }
    }

    static func latestRelease(repository: String) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) else {
            throw URLError(.cannotParseResponse)
        }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page)
    }

    /// "2.10" is newer than "2.9"; compares number by number.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }
}
