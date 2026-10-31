import Foundation

@MainActor
final class AppModel: ObservableObject {
    let tools: Tools

    @Published var link = ""
    @Published var info: MediaInfo?
    @Published var loading = false
    @Published var loadError: String?
    @Published var loadNote: String?
    @Published var jobs: [DownloadJob] = []

    @Published var mode: Mode = .video
    @Published var clipMode = true
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var zoom: ClosedRange<Double>?
    @Published var quality: Quality = .best
    @Published var audioFormat: AudioFormat = .mp3
    @Published var preciseCut = true
    @Published var alsoTranscript = false
    @Published var language = Languages.auto

    @Published var showBatch = false
    @Published var showOptions = false
    @Published var batchText = ""

    @Published var browser: Browser {
        didSet {
            UserDefaults.standard.set(browser.rawValue, forKey: "browser")
            if browser != oldValue { browserProfile = "" }
        }
    }
    @Published var browserProfile: String {
        didSet { UserDefaults.standard.set(browserProfile, forKey: "browserProfile") }
    }
    var login: Login { Login(browser: browser, profile: browserProfile) }
    @Published var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: "folder") }
    }

    /// How many downloads run at the same time; the rest wait in the queue.
    private let maxConcurrent = 2

    init(tools: Tools) {
        self.tools = tools
        let d = UserDefaults.standard
        browser = d.string(forKey: "browser").flatMap(Browser.init(rawValue:)) ?? .none
        browserProfile = d.string(forKey: "browserProfile") ?? ""
        folder = d.string(forKey: "folder").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    var duration: Double { info?.duration ?? 0 }

    /// Zooms the timeline to the clip with some room either side, or back out.
    func toggleZoom() {
        if zoom != nil { zoom = nil; return }
        let span = min(duration, max(60, (end - start) * 3))
        let lo = max(0, min((start + end) / 2 - span / 2, duration - span))
        zoom = lo...(lo + span)
    }
    var canClip: Bool { mode != .post && duration > 0 }
    var usingClip: Bool { canClip && clipMode }
    var clipValid: Bool { !usingClip || (end > start && start < duration) }
    var showsLanguage: Bool { mode == .transcript || (alsoTranscript && (mode == .video || mode == .audio)) }

    // MARK: Loading a link

    func load() async {
        let url = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, let ytdlp = tools.ytdlp else { return }

        // Several links pasted at once go to the batch window.
        let links = Links.all(in: url)
        if links.count > 1 {
            batchText = links.joined(separator: "\n")
            showBatch = true
            link = ""
            return
        }

        loading = true
        loadError = nil
        loadNote = nil
        info = nil
        zoom = nil
        defer { loading = false }

        // Look the link up without your login; if the site asks for one, try
        // once more with it.
        var result = await Shell.run(ytdlp, commonArgs(login, useLogin: false) + ["-J", url])
        if !result.ok, login.isSet, Self.looksLikeLoginWall(result.err) {
            result = await Shell.run(ytdlp, commonArgs(login, useLogin: true) + ["-J", url])
        }
        if result.ok, let parsed = MediaInfo(json: Data(result.out.utf8), fallbackURL: url) {
            info = parsed
            let linkStart = TimeFormat.startTime(inLink: url) ?? 0
            start = min(linkStart, max(0, parsed.duration ?? linkStart))
            end = parsed.duration.map { min($0, start + 30) } ?? start + 30
            clipMode = linkStart > 0
            if parsed.entryCount > 1 && Links.isPost(url) {
                mode = .post
                loadNote = "This post has \(parsed.entryCount) slides. “Whole post” saves every one of them, photos included. Switch to Video to save just the first video."
            } else if mode == .post {
                mode = .video
            }
        } else if Links.isPost(url) {
            // Photo-only posts have no video for yt-dlp to read, but
            // gallery-dl can still save them.
            info = MediaInfo(placeholderFor: url)
            mode = .post
            let why = Self.explain(result.err)
            loadNote = "JAGBA can't preview this post. It may contain only photos. “Whole post” will save every slide.\n\n" + why
        } else {
            loadError = Self.explain(result.err)
        }
    }

    // MARK: Queueing downloads

    private func currentSpec(link: String, info: MediaInfo?) -> JobSpec {
        var spec = JobSpec(link: link, mode: mode, folder: folder, login: login, info: info)
        spec.quality = quality
        spec.audioFormat = audioFormat
        spec.preciseCut = preciseCut
        spec.alsoTranscript = alsoTranscript
        spec.language = language
        if usingClip { spec.clip = (start, end) }
        return spec
    }

    /// Queues what's set up in the main window.
    func download() {
        guard let info else { return }
        enqueue([currentSpec(link: info.pageURL, info: info.isPlaceholder ? nil : info)])
    }

    /// Queues every link in the batch box with the current settings
    /// (whole videos, no clipping).
    func downloadBatch() {
        let links = Links.all(in: batchText)
        guard !links.isEmpty else { return }
        enqueue(links.map { link in
            var spec = currentSpec(link: link, info: nil)
            spec.clip = nil
            return spec
        })
        batchText = ""
        showBatch = false
    }

    var batchLinks: [String] { Links.all(in: batchText) }

    private func enqueue(_ specs: [JobSpec]) {
        jobs.insert(contentsOf: specs.map(DownloadJob.init(spec:)), at: 0)
        pump()
    }

    func retry(_ job: DownloadJob) {
        let copy = DownloadJob(spec: job.spec)
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = copy } else { jobs.insert(copy, at: 0) }
        pump()
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    /// Starts queued jobs, oldest first, until the concurrency limit is reached.
    private func pump() {
        while jobs.filter({ $0.state == .running }).count < maxConcurrent,
              let next = jobs.filter({ $0.state == .queued }).min(by: { $0.order < $1.order }) {
            next.state = .running
            next.status = "Starting…"
            Task {
                await execute(next)
                pump()
            }
        }
    }

    private func execute(_ job: DownloadJob) async {
        do {
            do {
                try await perform(job)
            } catch let failure as JobFailure where failure.loginRequired && !job.useLogin && job.spec.login.isSet {
                // The site wants a login: retry once with the browser login.
                job.useLogin = true
                job.files = []
                job.status = "Retrying with your \(job.spec.login.browser.rawValue) login…"
                try await perform(job)
            }
            guard job.state == .running else { return }
            job.state = .done
            job.progress = 1
            job.status = job.files.count == 1 ? "Saved \(job.files[0].lastPathComponent)" : "Saved \(job.files.count) files"
        } catch is CancellationError {
            // Already marked cancelled.
        } catch {
            guard job.state != .cancelled else { return }
            job.state = .failed(error.localizedDescription)
            job.status = "Failed"
        }
    }
}
