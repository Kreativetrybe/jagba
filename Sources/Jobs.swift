import AppKit
import Foundation

/// Everything needed to carry out one download, captured when it's queued so
/// later changes in the window don't affect it.
struct JobSpec {
    var link: String
    var mode: Mode
    var quality: Quality = .best
    var audioFormat: AudioFormat = .mp3
    var clip: (start: Double, end: Double)?
    var preciseCut = true
    var alsoTranscript = false
    var language = Languages.auto
    var folder: URL
    var login: Login
    var info: MediaInfo?

    var summary: String {
        var parts: [String] = []
        switch mode {
        case .video: parts.append("Video · \(quality.rawValue)")
        case .audio: parts.append("Audio · \(audioFormat.rawValue)")
        case .transcript: parts.append("Transcript")
        case .post: parts.append("Whole post (photos + videos)")
        }
        if alsoTranscript && (mode == .video || mode == .audio) { parts.append("+ transcript") }
        if let clip { parts.append("Clip \(TimeFormat.format(clip.start, tenths: false))–\(TimeFormat.format(clip.end, tenths: false))") }
        return parts.joined(separator: " · ")
    }
}

struct JobFailure: LocalizedError {
    var message: String
    /// The site refused because it wants a login; worth one retry with it.
    var loginRequired = false
    var errorDescription: String? { message }

    init(message: String, loginRequired: Bool = false) {
        self.message = message
        self.loginRequired = loginRequired
    }

    /// From a tool's error output.
    init(output: String) {
        self.init(message: AppModel.explain(output), loginRequired: AppModel.looksLikeLoginWall(output))
    }
}

@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    enum State: Equatable {
        case queued, running, done, failed(String), cancelled
    }

    private static var counter = 0

    let id = UUID()
    let order: Int
    let spec: JobSpec

    @Published var title: String
    @Published var state: State = .queued
    @Published var progress: Double?
    @Published var status = "Waiting…"
    @Published var files: [URL] = []
    @Published var note: String?
    @Published var log: [String] = []
    @Published var showLog = false

    /// Length of the media being processed, for turning ffmpeg's "time="
    /// output into a percentage.
    var progressLength: Double?
    /// Whether to borrow the browser login. Starts off for every site (public
    /// posts need no login); turned on for one retry if the site asks.
    var useLogin = false
    private var process: Process?

    init(spec: JobSpec) {
        Self.counter += 1
        order = Self.counter
        self.spec = spec
        title = spec.info?.title ?? Links.shortName(spec.link)
    }

    var isActive: Bool { state == .queued || state == .running }

    func cancel() {
        guard isActive else { return }
        process?.terminate()
        state = .cancelled
        status = "Cancelled"
    }

    func reveal() {
        if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
    }

    func open() {
        if let first = files.first { NSWorkspace.shared.open(first) }
    }

    func checkCancelled() throws {
        if state == .cancelled { throw CancellationError() }
    }

    /// Runs a tool with its output streamed into this job's log and progress.
    func run(_ executable: String, _ args: [String]) async throws -> Shell.Result {
        try checkCancelled()
        let result = await Shell.run(executable, args, onLine: { line in
            Task { @MainActor in self.consume(line) }
        }, started: { p in
            Task { @MainActor in
                self.process = p
                if self.state == .cancelled { p.terminate() }
            }
        })
        process = nil
        await Task.yield()
        try checkCancelled()
        return result
    }

    func run(_ command: Command, _ args: [String]) async throws -> Shell.Result {
        try await run(command.executable, command.prefix + args)
    }

    /// Reads progress out of tool output: yt-dlp's "[download]  42.0%",
    /// ffmpeg's "time=00:00:12.34" (clips) and Whisper's " 42%|".
    private func consume(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }

        if let r = line.range(of: #"\[download\]\s+([\d.]+)%"#, options: .regularExpression) {
            let pct = line[r].components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()
            if let v = Double(pct) { progress = v / 100 }
        } else if let len = progressLength, len > 0,
                  let r = line.range(of: #"time=\d+:\d+:[\d.]+"#, options: .regularExpression),
                  let t = TimeFormat.parse(String(line[r].dropFirst(5))) {
            progress = min(1, t / len)
        } else if let r = line.range(of: #"^\s*\d{1,3}%\|"#, options: .regularExpression) {
            let pct = line[r].filter(\.isNumber)
            if let v = Double(pct) { progress = v / 100 }
        } else if line.hasPrefix("[Merger]") || line.hasPrefix("[VideoConvertor]") {
            status = "Merging audio and video…"
        } else if line.hasPrefix("[ExtractAudio]") {
            status = "Converting audio…"
        }
    }
}

// MARK: - Carrying out a job

extension AppModel {
    /// Arguments for every yt-dlp run. The browser login is only passed when
    /// `useLogin` is set, so most downloads never touch your cookies.
    func commonArgs(_ login: Login, useLogin: Bool) -> [String] {
        var a = ["--no-playlist", "--newline", "--no-colors"]
        if let ff = tools.ffmpeg { a += ["--ffmpeg-location", ff] }
        if useLogin, let arg = login.ytdlpArg { a += ["--cookies-from-browser", arg] }
        a += tools.jsArgs
        return a
    }

    func perform(_ job: DownloadJob) async throws {
        let spec = job.spec
        if spec.mode == .post {
            try await savePost(job)
            return
        }
        guard let ytdlp = tools.ytdlp else { throw JobFailure(message: "yt-dlp isn't installed yet.") }

        // Batch links arrive without details; look them up for the title,
        // duration and captions.
        var info = spec.info
        if info == nil {
            job.status = "Looking up…"
            let r = try await job.run(ytdlp, commonArgs(spec.login, useLogin: job.useLogin) + ["-J", spec.link])
            if r.ok, let parsed = MediaInfo(json: Data(r.out.utf8), fallbackURL: spec.link) {
                info = parsed
                job.title = parsed.title
            } else {
                throw JobFailure(output: r.err)
            }
        }

        switch spec.mode {
        case .video:
            let file = try await downloadMedia(job, info: info, formatArgs: spec.quality.args, cutExactly: spec.preciseCut)
            if spec.alsoTranscript { try await transcribe(job, info: info, source: file) }
        case .audio:
            let file = try await downloadMedia(job, info: info, formatArgs: spec.audioFormat.args, cutExactly: true)
            if spec.alsoTranscript { try await transcribe(job, info: info, source: file) }
        case .transcript:
            try await transcribe(job, info: info, source: nil)
        case .post:
            break
        }
    }

    /// Downloads with yt-dlp into `folder` (or the save folder) and returns the file.
    @discardableResult
    func downloadMedia(_ job: DownloadJob, info: MediaInfo?, formatArgs: [String], cutExactly: Bool, folder: URL? = nil, name: String? = nil) async throws -> URL? {
        guard let ytdlp = tools.ytdlp else { throw JobFailure(message: "yt-dlp isn't installed yet.") }
        let spec = job.spec
        var args = commonArgs(spec.login, useLogin: job.useLogin) + formatArgs
        var template = "%(title).80B [%(id)s].%(ext)s"
        job.progressLength = nil
        if let clip = spec.clip {
            args += ["--download-sections", String(format: "*%.2f-%.2f", clip.start, clip.end)]
            // Audio is always cut exactly: otherwise the converted file gets
            // padded with silence (a 15s clip came out 25s long).
            if cutExactly { args.append("--force-keyframes-at-cuts") }
            template = "%(title).80B [%(id)s] \(TimeFormat.label(clip.start))-\(TimeFormat.label(clip.end)).%(ext)s"
            job.progressLength = clip.end - clip.start
        }
        if let name { template = name }

        let pathFile = FileManager.default.temporaryDirectory.appendingPathComponent("jagba-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: pathFile) }
        args += ["-P", (folder ?? spec.folder).path, "-o", template, "--print-to-file", "after_move:filepath", pathFile.path]
        args.append(info?.pageURL ?? spec.link)

        job.status = "Downloading…"
        job.progress = nil
        let r = try await job.run(ytdlp, args)
        guard r.ok else { throw JobFailure(output: r.err) }
        let printed = (try? String(contentsOf: pathFile, encoding: .utf8))?.split(separator: "\n").last.map(String.init)
        guard let printed else { return nil }
        let url = URL(fileURLWithPath: printed)
        if folder == nil { job.files.append(url) }
        return url
    }

    // MARK: Transcripts

    /// Saves "<name>.txt" and "<name>.srt". Uses YouTube's captions when there
    /// are some; otherwise transcribes the audio on this Mac. `source` is an
    /// already-downloaded (and already-clipped) file to transcribe.
    func transcribe(_ job: DownloadJob, info: MediaInfo?, source: URL?) async throws {
        let spec = job.spec
        guard let ffmpeg = tools.ffmpeg else { throw JobFailure(message: "ffmpeg is needed for transcripts. Use “Install ffmpeg” at the top of the window.") }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("jagba-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let title = info?.title ?? job.title
        let base: URL
        if let source {
            base = source.deletingPathExtension()
        } else {
            var name = "\(title) [\(info?.id ?? "video")]"
            if let clip = spec.clip { name += " \(TimeFormat.label(clip.start))-\(TimeFormat.label(clip.end))" }
            base = spec.folder.appendingPathComponent(safeFileName(name, limit: 120))
        }
        let chosenLanguage = spec.language.isEmpty ? nil : spec.language
        var header = "\(title)\n\(info?.pageURL ?? spec.link)"
        if let clip = spec.clip {
            header += "\nClip \(TimeFormat.format(clip.start, tenths: false))–\(TimeFormat.format(clip.end, tenths: false)) (times in the .srt start at 0:00)"
        }

        // 1. YouTube captions: instant, and often written by a person.
        if tools.useCaptions, let info, info.isYouTube, let track = info.captionTrack(language: chosenLanguage), let ytdlp = tools.ytdlp {
            job.status = "Getting captions…"
            let r = try await job.run(ytdlp, commonArgs(spec.login, useLogin: job.useLogin) + [
                "--skip-download", track.automatic ? "--write-auto-subs" : "--write-subs",
                "--sub-langs", track.key, "--sub-format", "json3",
                "-P", tmp.path, "-o", "subs", info.pageURL,
            ])
            let file = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil))?.first { $0.pathExtension == "json3" }
            if r.ok, let file, let data = try? Data(contentsOf: file) {
                var segments = Transcript.parseJSON3(data)
                if let clip = spec.clip { segments = Transcript.trim(segments, to: clip) }
                if !segments.isEmpty {
                    let kind = track.automatic ? "YouTube automatic captions" : "YouTube captions"
                    job.files += try Transcript.save(segments, to: base, header: header + "\nTranscript: \(kind) (\(track.key))")
                    job.note = "Transcript from \(kind)."
                    return
                }
            }
        }

        // 2. Transcribe the audio on this Mac.
        var audio = source
        if audio == nil {
            job.status = "Downloading audio…"
            audio = try await downloadMedia(job, info: info, formatArgs: AudioFormat.m4a.args, cutExactly: true, folder: tmp, name: "audio.%(ext)s")
        }
        guard let audio else { throw JobFailure(message: "Couldn't get the audio to transcribe.") }
        job.status = "Preparing audio…"
        let wav = try await Transcript.makeWav(from: audio, ffmpeg: ffmpeg)
        defer { try? fm.removeItem(at: wav) }

        // The language: chosen by the person or stated by the site. If still
        // unknown, Whisper (when installed) detects it from the audio;
        // otherwise Apple uses the Mac's own language.
        let language = chosenLanguage ?? Transcript.statedLanguage(info)
        let length = spec.clip.map { $0.end - $0.start } ?? info?.duration ?? 0
        job.progress = nil
        job.progressLength = nil

        var segments: [Segment] = []
        var engineName = ""
        var useWhisper = tools.whisper != nil && (tools.engine == .whisper || language == nil)

        if !useWhisper {
            if #available(macOS 26, *) {
                if let locale = await AppleSpeech.locale(for: language) {
                    job.status = "Transcribing (\(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier))…"
                    segments = try await AppleSpeech.transcribe(wav, locale: locale, duration: length) { p in
                        Task { @MainActor in job.progress = p }
                    }
                    engineName = "Apple speech recognition, \(locale.identifier)"
                } else if tools.whisper != nil {
                    useWhisper = true
                } else {
                    throw TranscriptError.unsupportedLanguage(Languages.name(language ?? "this language"))
                }
            } else {
                job.status = "Transcribing…"
                segments = try await LegacySpeech.transcribe(wav, languageCode: language)
                engineName = "Apple speech recognition"
            }
        }

        if useWhisper, let whisper = tools.whisper {
            job.status = "Transcribing with Whisper (first use downloads the model)…"
            var args = [wav.path, "--model", tools.whisperModel, "--output_format", "json", "--output_dir", tmp.path, "--verbose", "False", "--fp16", "False"]
            if let language { args += ["--language", language] }
            let r = try await job.run(whisper, args)
            let json = tmp.appendingPathComponent(wav.deletingPathExtension().lastPathComponent + ".json")
            guard r.ok, let data = try? Data(contentsOf: json) else {
                throw JobFailure(message: "Whisper failed: " + (r.err.split(separator: "\n").last.map(String.init) ?? "unknown error"))
            }
            segments = Transcript.parseWhisperJSON(data)
            engineName = "Whisper \(tools.whisperModel)" + (language.map { ", \($0)" } ?? ", language auto-detected")
        }

        try job.checkCancelled()
        if length > 0 {
            segments = segments.filter { $0.start < length }.map { Segment(start: $0.start, end: min($0.end, length), text: $0.text) }
        }
        guard !segments.isEmpty else { throw TranscriptError.noSpeech }
        job.files += try Transcript.save(segments, to: base, header: header + "\nTranscript: \(engineName)")
        job.note = "Transcribed with \(engineName)." + (language == nil && !useWhisper
            ? " If that's not the spoken language, choose it under “Spoken language” and try again." : "")
    }

    // MARK: Whole posts (carousels, photo slideshows)

    func savePost(_ job: DownloadJob) async throws {
        let spec = job.spec
        guard let gallery = tools.galleryDL else {
            throw JobFailure(message: "Saving whole posts needs gallery-dl. Click “Install gallery-dl” at the top of the window, then Retry.")
        }
        let folder = spec.folder.appendingPathComponent(safeFileName(Links.shortName(spec.link)), isDirectory: true)
        var args: [String] = []
        // gallery-dl loads only the post's own site cookies, not all of them.
        if job.useLogin, let arg = spec.login.galleryArg(for: spec.link) { args += ["--cookies-from-browser", arg] }
        args += ["-D", folder.path, "-f", "{num:?slide /-/>02}{filename}.{extension}", spec.link]

        job.status = "Saving every photo and video…"
        let r = try await job.run(gallery, args)
        // gallery-dl prints each saved file; "# " marks ones that already existed.
        let files = r.out.split(separator: "\n").map { $0.hasPrefix("# ") ? String($0.dropFirst(2)) : String($0) }
            .filter { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        job.files += files
        guard r.ok, !files.isEmpty else {
            throw JobFailure(output: r.err.isEmpty ? r.out : r.err)
        }
        job.note = "Saved \(files.count) item\(files.count == 1 ? "" : "s") into the folder “\(folder.lastPathComponent)”."
    }

    /// Whether a site refused because it wants you logged in.
    nonisolated static func looksLikeLoginWall(_ output: String) -> Bool {
        let lower = output.lowercased()
        let signs = ["login required", "log in", "login", "sign in", "--cookies", "use cookies", "private video",
                     "age-restricted", "confirm your age", "not a bot", "empty media response", "401",
                     "registered users", "members-only", "requires authentication"]
        return signs.contains { lower.contains($0) }
    }

    /// Turns tool error output into something a person can act on.
    nonisolated static func explain(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map(String.init)
        let raw = lines.last { $0.hasPrefix("ERROR:") || $0.contains("[error]") }
            .map { $0.replacingOccurrences(of: "ERROR: ", with: "") }
            ?? lines.last ?? "Unknown error"
        let lower = stderr.lowercased()
        let pickBrowser = "Choose the browser you're logged in with under “Use login from”, then try again."
        if lower.contains("could not find") && lower.contains("cookies database") {
            return "JAGBA couldn't read that browser's logins. macOS may be blocking access (Chrome and Safari need Full Disk Access for JAGBA), or you're not logged in to that browser. Pick a browser marked as ready under “Use login from”, then try again.\n\n" + raw
        }
        if lower.contains("could not copy") && lower.contains("cookie") || lower.contains("operation not permitted") && lower.contains("cookies") {
            return "Couldn't read that browser's login. Quit the browser and try again, or pick a different browser. Safari needs Full Disk Access for JAGBA in System Settings › Privacy & Security.\n\n" + raw
        }
        if lower.contains("instagram") && (lower.contains("cookies") || lower.contains("login") || lower.contains("empty media") || lower.contains("401") || lower.contains("redirect")) {
            return "Instagram wants you to be logged in. \(pickBrowser)\n\n" + raw
        }
        if lower.contains("confirm your age") || lower.contains("age-restricted") {
            return "This video is age-restricted, so the site wants you to be logged in. \(pickBrowser)\n\n" + raw
        }
        if lower.contains("not a bot") {
            return "YouTube is asking to confirm you're not a bot. \(pickBrowser)\n\n" + raw
        }
        if looksLikeLoginWall(stderr) {
            return "This site wants you to be logged in. \(pickBrowser)\n\n" + raw
        }
        if lower.contains("403") || lower.contains("unable to extract") || lower.contains("please report this issue") {
            return "The site may have changed. Try “Update yt-dlp” (or switch to the nightly channel in Settings), then try again.\n\n" + raw
        }
        if lower.contains("ffmpeg") && lower.contains("not found") {
            return "ffmpeg is missing. Use “Install ffmpeg” at the top of the window.\n\n" + raw
        }
        return raw
    }
}
