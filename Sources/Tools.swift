import CryptoKit
import Foundation

enum Paths {
    /// ~/Library/Application Support/JAGBA/bin — where the app keeps its own
    /// copies of yt-dlp, ffmpeg, deno and a private Python for gallery-dl.
    static let bin: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The app used to be called Excerpt: keep the tools it already downloaded.
        let old = base.appendingPathComponent("Excerpt"), new = base.appendingPathComponent("JAGBA")
        if fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
            try? fm.moveItem(at: old, to: new)
        }
        let dir = new.appendingPathComponent("bin", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var managedYtdlp: URL { bin.appendingPathComponent("yt-dlp_macos") }
    static var python: URL { bin.appendingPathComponent("python/bin/python3") }
}

/// A command-line tool, possibly run through Python ("python3 -m gallery_dl").
struct Command {
    var executable: String
    var prefix: [String] = []
    var display: String { ([executable] + prefix).joined(separator: " ") }
}

/// Finds, installs and updates the command-line tools the app depends on.
/// yt-dlp and gallery-dl are the pieces that break when sites change, so the
/// app keeps its own copies and updates them automatically.
@MainActor
final class Tools: ObservableObject {
    @Published var ytdlp: String?
    @Published var ytdlpVersion: String?
    @Published var ytdlpIsManaged = false
    @Published var ffmpeg: String?
    @Published var jsRuntime: String?
    @Published var galleryDL: Command?
    @Published var whisper: Command?
    @Published var activity: String?
    @Published var message: String?

    private let defaults = UserDefaults.standard

    var channel: String {
        get { defaults.string(forKey: "ytdlpChannel") ?? "stable" }
        set { defaults.set(newValue, forKey: "ytdlpChannel"); objectWillChange.send() }
    }

    var autoUpdate: Bool {
        get { defaults.object(forKey: "autoUpdate") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoUpdate"); objectWillChange.send() }
    }

    var engine: TranscriptEngine {
        get { defaults.string(forKey: "engine").flatMap(TranscriptEngine.init(rawValue:)) ?? .apple }
        set { defaults.set(newValue.rawValue, forKey: "engine"); objectWillChange.send() }
    }

    var useCaptions: Bool {
        get { defaults.object(forKey: "useCaptions") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "useCaptions"); objectWillChange.send() }
    }

    var whisperModel: String {
        get { defaults.string(forKey: "whisperModel") ?? "turbo" }
        set { defaults.set(newValue, forKey: "whisperModel"); objectWillChange.send() }
    }

    private var lastUpdateCheck: Date? {
        get { defaults.object(forKey: "lastUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastUpdateCheck") }
    }

    var isBusy: Bool { activity != nil }
    var ready: Bool { ytdlp != nil }
    var hasManagedPython: Bool { FileManager.default.isExecutableFile(atPath: Paths.python.path) }

    /// Extra yt-dlp arguments for the JavaScript runtime YouTube needs.
    /// yt-dlp finds deno on its own; other runtimes must be named.
    var jsArgs: [String] {
        guard let js = jsRuntime else { return [] }
        let name = URL(fileURLWithPath: js).lastPathComponent
        return name == "deno" ? [] : ["--js-runtimes", "\(name):\(js)"]
    }

    func bootstrap() async {
        findFFmpeg()
        findJSRuntime()
        await findPythonTools()

        if let override = ProcessInfo.processInfo.environment["JAGBA_YTDLP"] {
            ytdlp = override
            ytdlpIsManaged = false
            await readVersion()
            return
        }

        if FileManager.default.isExecutableFile(atPath: Paths.managedYtdlp.path) {
            ytdlp = Paths.managedYtdlp.path
            ytdlpIsManaged = true
            await readVersion()
            let stale = lastUpdateCheck.map { Date().timeIntervalSince($0) > 24 * 3600 } ?? true
            if autoUpdate && stale {
                await updateYtdlp()
                if hasManagedPython && galleryDL != nil { await updateGalleryDL(quiet: true) }
            }
        } else {
            await installYtdlp()
        }
    }

    // MARK: yt-dlp

    func installYtdlp() async {
        activity = "Downloading yt-dlp…"
        defer { activity = nil }
        do {
            let asset = try await Verified.githubAsset("yt-dlp/yt-dlp") { $0 == "yt-dlp_macos" }
            try await Verified.download(asset.url, sha256: asset.sha256, to: Paths.managedYtdlp, name: "yt-dlp")
            ytdlp = Paths.managedYtdlp.path
            ytdlpIsManaged = true
            lastUpdateCheck = Date()
            activity = "Preparing yt-dlp (first run is slow)…"
            if channel != "stable" { _ = await Shell.run(Paths.managedYtdlp.path, ["--update-to", channel]) }
            await readVersion()
            message = "yt-dlp \(ytdlpVersion ?? "") installed."
        } catch {
            message = "Couldn't download yt-dlp: \(error.localizedDescription)"
            useSystemYtdlpIfPresent()
        }
    }

    func updateYtdlp() async {
        guard ytdlpIsManaged, let ytdlp else {
            await installYtdlp()
            return
        }
        activity = "Checking for yt-dlp updates…"
        defer { activity = nil }
        let before = ytdlpVersion
        let result = await Shell.run(ytdlp, ["--update-to", channel])
        lastUpdateCheck = Date()
        await readVersion()
        if result.ok {
            message = before == ytdlpVersion
                ? "yt-dlp is up to date (\(ytdlpVersion ?? "?"))."
                : "yt-dlp updated to \(ytdlpVersion ?? "?")."
        } else {
            let line = (result.err + result.out).split(separator: "\n").last.map(String.init) ?? ""
            message = "yt-dlp update failed. \(line)"
        }
    }

    private func useSystemYtdlpIfPresent() {
        for p in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"] where FileManager.default.isExecutableFile(atPath: p) {
            ytdlp = p
            ytdlpIsManaged = false
            Task { await readVersion() }
            return
        }
    }

    private func readVersion() async {
        guard let ytdlp else { return }
        let r = await Shell.run(ytdlp, ["--version"])
        ytdlpVersion = r.ok ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    // MARK: ffmpeg

    func findFFmpeg() {
        let candidates = [Paths.bin.appendingPathComponent("ffmpeg").path, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        ffmpeg = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func installFFmpeg() async {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        let url = URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(arch)/release/ffmpeg.zip")!
        activity = "Downloading ffmpeg…"
        defer { activity = nil }
        do {
            // The site publishes "<file>.sha256" next to each download.
            let final = try await Verified.resolve(url)
            let sums = try await Verified.text(final.appendingPathExtension("sha256"))
            guard let sha = sums.split(separator: " ").first.map(String.init), sha.count == 64 else { throw Verified.Failure(name: "ffmpeg") }
            try await downloadZip(final, sha256: sha, name: "ffmpeg", extracting: "ffmpeg")
            findFFmpeg()
            message = "ffmpeg installed."
        } catch {
            message = "Couldn't download ffmpeg: \(error.localizedDescription)"
        }
    }

    // MARK: JavaScript runtime (needed by yt-dlp for YouTube)

    func findJSRuntime() {
        let names = ["deno", "node", "bun"]
        let dirs = [Paths.bin.path, "/opt/homebrew/bin", "/usr/local/bin"]
        for name in names {
            for dir in dirs {
                let p = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: p) { jsRuntime = p; return }
            }
        }
        jsRuntime = nil
    }

    func installDeno() async {
        #if arch(arm64)
        let file = "deno-aarch64-apple-darwin.zip"
        #else
        let file = "deno-x86_64-apple-darwin.zip"
        #endif
        activity = "Downloading Deno…"
        defer { activity = nil }
        do {
            let asset = try await Verified.githubAsset("denoland/deno") { $0 == file }
            try await downloadZip(asset.url, sha256: asset.sha256, name: "Deno", extracting: "deno")
            findJSRuntime()
            message = "Deno installed."
        } catch {
            message = "Couldn't download Deno: \(error.localizedDescription)"
        }
    }

    // MARK: Python tools: gallery-dl (whole Instagram/TikTok posts) and Whisper

    /// Looks for gallery-dl and Whisper, preferring the app's own Python.
    func findPythonTools() async {
        let fm = FileManager.default
        galleryDL = nil
        whisper = nil
        if hasManagedPython {
            let py = Paths.python.path
            if (await Shell.run(py, ["-c", "import gallery_dl"])).ok { galleryDL = Command(executable: py, prefix: ["-m", "gallery_dl"]) }
            if (await Shell.run(py, ["-c", "import whisper"])).ok { whisper = Command(executable: py, prefix: ["-m", "whisper"]) }
        }
        let home = NSHomeDirectory()
        if galleryDL == nil {
            for p in ["/opt/homebrew/bin/gallery-dl", "/usr/local/bin/gallery-dl", "\(home)/.local/bin/gallery-dl"] where fm.isExecutableFile(atPath: p) {
                galleryDL = Command(executable: p)
                break
            }
        }
        if whisper == nil {
            for p in ["/opt/homebrew/bin/whisper", "/usr/local/bin/whisper", "\(home)/.local/bin/whisper"] where fm.isExecutableFile(atPath: p) {
                whisper = Command(executable: p)
                break
            }
        }
    }

    /// gallery-dl and yt-dlp come as prebuilt wheels, so nothing runs at
    /// install time. pip checks each file against PyPI's published hash.
    func installGalleryDL() async {
        await pipInstall(["--only-binary=:all:", "gallery-dl", "yt-dlp"], label: "gallery-dl")
    }

    func updateGalleryDL(quiet: Bool = false) async {
        guard hasManagedPython else { return }
        await pipInstall(["--only-binary=:all:", "gallery-dl", "yt-dlp"], label: "gallery-dl", quiet: quiet)
    }

    func installWhisper() async {
        await pipInstall(["openai-whisper"], label: "Whisper (about 1 GB)")
    }

    /// Installs Python packages into the app's private Python, setting that
    /// Python up first if needed. Nothing is installed system-wide.
    private func pipInstall(_ packages: [String], label: String, quiet: Bool = false) async {
        do {
            if !hasManagedPython {
                activity = "Downloading Python for \(label)…"
                try await installPython()
            }
            activity = "Installing \(label)…"
            let r = await Shell.run(Paths.python.path, ["-m", "pip", "install", "--upgrade", "--disable-pip-version-check", "--no-warn-script-location"] + packages)
            activity = nil
            await findPythonTools()
            if !quiet || !r.ok {
                message = r.ok ? "\(label) is installed and up to date." : "Couldn't install \(label): \(r.err.split(separator: "\n").last ?? "")"
            }
        } catch {
            activity = nil
            message = "Couldn't set up \(label): \(error.localizedDescription)"
        }
    }

    /// Downloads a self-contained Python build (python-build-standalone).
    private func installPython() async throws {
        #if arch(arm64)
        let arch = "aarch64"
        #else
        let arch = "x86_64"
        #endif
        let asset = try await Verified.githubAsset("astral-sh/python-build-standalone") {
            $0.hasPrefix("cpython-3.13.") && $0.hasSuffix("-\(arch)-apple-darwin-install_only.tar.gz")
        }

        let fm = FileManager.default
        let tarball = fm.temporaryDirectory.appendingPathComponent("python-\(UUID().uuidString).tar.gz")
        defer { try? fm.removeItem(at: tarball) }
        try await Verified.download(asset.url, sha256: asset.sha256, to: tarball, name: "Python")
        try? fm.removeItem(at: Paths.bin.appendingPathComponent("python"))
        let r = await Shell.run("/usr/bin/tar", ["-xzf", tarball.path, "-C", Paths.bin.path])
        guard r.ok, hasManagedPython else { throw CocoaError(.fileReadCorruptFile) }
    }

    // MARK: Downloading helpers

    /// Downloads a zip, checks it, unpacks it and moves the named executable into bin.
    private func downloadZip(_ url: URL, sha256: String, name label: String, extracting name: String) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let zip = work.appendingPathComponent("download.zip")
        try await Verified.download(url, sha256: sha256, to: zip, name: label)
        let unzip = await Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.appendingPathComponent("x").path])
        guard unzip.ok else { throw CocoaError(.fileReadCorruptFile) }

        let found = fm.enumerator(at: work.appendingPathComponent("x"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == name }
        guard let found else { throw CocoaError(.fileNoSuchFile) }

        let dest = Paths.bin.appendingPathComponent(name)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: found, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }
}

/// Downloads that are checked against a published SHA-256 fingerprint before
/// anything is installed. The fingerprints come from the same project, so
/// they catch corrupted or tampered downloads, not a hacked project.
enum Verified {
    struct Failure: LocalizedError {
        var name: String
        var errorDescription: String? {
            "The \(name) download didn't match its published checksum, so JAGBA didn't install it. Try again later."
        }
    }

    struct Asset {
        var url: URL
        var sha256: String
    }

    /// The newest release file whose name matches, with the SHA-256 that
    /// GitHub records for it.
    static func githubAsset(_ repo: String, matching match: (String) -> Bool) async throws -> Asset {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        let release = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let assets = release?["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: { match($0["name"] as? String ?? "") }),
              let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
              let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") else {
            throw URLError(.resourceUnavailable)
        }
        return Asset(url: url, sha256: String(digest.dropFirst(7)))
    }

    /// Downloads to a temporary file, checks the fingerprint, then moves it
    /// into place. A mismatch deletes the download.
    static func download(_ url: URL, sha256 expected: String, to dest: URL, name: String) async throws {
        let (tmp, response) = try await URLSession.shared.download(from: url)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: tmp) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        guard try sha256(of: tmp) == expected.lowercased() else { throw Failure(name: name) }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Follows redirects to the real file location. (Asks for one byte:
    /// some servers don't answer HEAD requests.)
    static func resolve(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: request)
        return response.url ?? url
    }

    static func text(_ url: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw URLError(.badServerResponse) }
        return String(decoding: data, as: UTF8.self)
    }
}
