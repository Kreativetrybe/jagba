import AppKit
import Foundation

enum TimeFormat {
    /// Accepts "83", "1:23", "01:01:23", "1:23.5".
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }

    /// 83.4 -> "1:23.4", 3723 -> "1:02:03.0"
    static func format(_ t: Double, tenths: Bool = true) -> String {
        let t = max(0, t)
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60
        let s = t - Double(h * 3600 + m * 60)
        let sec = tenths ? String(format: "%04.1f", s) : String(format: "%02d", Int(s))
        return h > 0 ? String(format: "%d:%02d:", h, m) + sec : "\(m):" + sec
    }

    /// Safe for filenames: 83 -> "1m23s", 3723 -> "1h02m03s"
    static func label(_ t: Double) -> String {
        let t = Int(t.rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%dh%02dm%02ds", h, m, s) : String(format: "%dm%02ds", m, s)
    }

    /// 83.456 -> "00:01:23,456"
    static func srt(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    /// The start time in a shared link, e.g. youtube.com/watch?v=x&t=95 or t=1m35s.
    static func startTime(inLink link: String) -> Double? {
        guard let comps = URLComponents(string: link) else { return nil }
        let raw = comps.queryItems?.first { $0.name == "t" || $0.name == "start" }?.value
            ?? comps.fragment.flatMap { $0.hasPrefix("t=") ? String($0.dropFirst(2)) : nil }
        guard let raw, !raw.isEmpty else { return nil }
        if let v = Double(raw.replacingOccurrences(of: "s", with: "")) { return v }
        var total = 0.0, number = ""
        for ch in raw {
            if ch.isNumber { number.append(ch); continue }
            guard let v = Double(number) else { return nil }
            switch ch {
            case "h": total += v * 3600
            case "m": total += v * 60
            case "s": total += v
            default: return nil
            }
            number = ""
        }
        return total + (Double(number) ?? 0)
    }
}

enum Links {
    /// Every http(s) link in a block of pasted text, in order, without duplicates.
    static func all(in text: String) -> [String] {
        let pattern = #"https?://[^\s<>"'\)\]]+"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;")) }
        .filter { seen.insert($0).inserted }
    }

    /// Instagram posts (which may be carousels) and TikTok photo slideshows.
    static func isPost(_ link: String) -> Bool {
        let l = link.lowercased()
        return (l.contains("instagram.com/") && (l.contains("/p/") || l.contains("/reel/") || l.contains("/tv/")))
            || (l.contains("tiktok.com/") && l.contains("/photo/"))
    }

    /// A short readable name for a link, used before its real title is known.
    static func shortName(_ link: String) -> String {
        guard let url = URL(string: link), let host = url.host else { return link }
        let site = host.replacingOccurrences(of: "www.", with: "").components(separatedBy: ".").first?.capitalized ?? host
        let last = url.pathComponents.last { $0 != "/" } ?? ""
        return last.isEmpty ? site : "\(site) \(last)"
    }
}

/// Makes a string safe to use as a file name on macOS.
func safeFileName(_ s: String, limit: Int = 80) -> String {
    let cleaned = s.replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    return cleaned.isEmpty ? "untitled" : String(cleaned.prefix(limit))
}

struct MediaInfo {
    var id: String
    var title: String
    var description: String?
    var uploader: String?
    var site: String
    var duration: Double?
    var thumbnail: URL?
    var pageURL: String
    var language: String?
    var manualSubs: [String] = []
    var autoSubs: [String] = []
    var entryCount = 1
    var previewURL: URL?
    var previewHeaders: [String: String] = [:]
    var isPlaceholder = false

    var isYouTube: Bool { site.lowercased().hasPrefix("youtube") }

    /// Stand-in for posts yt-dlp can't read (e.g. photo-only Instagram posts),
    /// which can still be saved with "Whole post".
    init(placeholderFor link: String) {
        id = URL(string: link)?.pathComponents.last { $0 != "/" } ?? "post"
        title = Links.shortName(link)
        site = link.lowercased().contains("tiktok") ? "TikTok" : "Instagram"
        pageURL = link
        isPlaceholder = true
    }

    /// Builds from `yt-dlp -J` output. For a post with several videos
    /// (e.g. an Instagram carousel) the first video is used for previewing.
    init?(json: Data, fallbackURL: String) {
        guard var obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        let top = obj
        if let entries = obj["entries"] as? [[String: Any]], !entries.isEmpty {
            entryCount = entries.count
            obj = entries.first(where: { $0["duration"] != nil }) ?? entries[0]
        }
        id = top["id"] as? String ?? obj["id"] as? String ?? "video"
        title = obj["title"] as? String ?? obj["fulltitle"] as? String ?? top["title"] as? String ?? "Untitled"
        description = obj["description"] as? String ?? top["description"] as? String
        uploader = obj["uploader"] as? String ?? obj["channel"] as? String
        site = obj["extractor_key"] as? String ?? obj["extractor"] as? String ?? ""
        duration = (obj["duration"] as? NSNumber)?.doubleValue
        thumbnail = (obj["thumbnail"] as? String).flatMap(URL.init(string:))
        pageURL = top["webpage_url"] as? String ?? fallbackURL
        language = obj["language"] as? String
        manualSubs = (obj["subtitles"] as? [String: Any]).map { Array($0.keys).filter { $0 != "live_chat" } } ?? []
        autoSubs = (obj["automatic_captions"] as? [String: Any]).map { Array($0.keys) } ?? []

        // Pick a format with both audio and video that AVPlayer can stream,
        // preferring something light (≤720p) for previewing.
        let formats = obj["formats"] as? [[String: Any]] ?? []
        func has(_ f: [String: Any], _ key: String) -> Bool {
            guard let v = f[key] as? String else { return false }
            return v != "none"
        }
        let playable = formats.filter { f in
            let proto = f["protocol"] as? String ?? ""
            let ext = f["ext"] as? String ?? ""
            let muxed = has(f, "vcodec") && has(f, "acodec")
            let okProto = proto.hasPrefix("m3u8") || proto == "https" || proto == "http"
            let okExt = proto.hasPrefix("m3u8") || ext == "mp4" || ext == "mov" || ext == "m4v"
            return muxed && okProto && okExt && f["url"] is String
        }
        let height = { (f: [String: Any]) in (f["height"] as? NSNumber)?.intValue ?? 0 }
        let choice = playable.filter { height($0) <= 720 }.max { height($0) < height($1) }
            ?? playable.min { height($0) < height($1) }
            ?? ((obj["url"] as? String) != nil ? obj : nil)
        previewURL = (choice?["url"] as? String).flatMap(URL.init(string:))
        previewHeaders = choice?["http_headers"] as? [String: String] ?? [:]
    }

    /// The caption track to use as a transcript: one in the spoken language,
    /// preferring human-made subtitles over YouTube's automatic ones.
    func captionTrack(language wanted: String?) -> (key: String, automatic: Bool)? {
        let lang = (wanted ?? language)?.lowercased()
        func matches(_ key: String) -> Bool {
            guard let lang else { return false }
            let k = key.lowercased()
            return k == lang || k.hasPrefix(lang + "-")
        }
        if let k = manualSubs.first(where: matches) { return (k, false) }
        if lang == nil, manualSubs.count == 1 { return (manualSubs[0], false) }
        if wanted == nil, let k = autoSubs.first(where: { $0.hasSuffix("-orig") }) { return (k, true) }
        if let lang, let k = autoSubs.first(where: { $0.lowercased() == lang + "-orig" }) ?? autoSubs.first(where: { $0.lowercased() == lang }) {
            return (k, true)
        }
        return nil
    }
}

enum Mode: String, CaseIterable, Identifiable {
    case video = "Video"
    case audio = "Audio"
    case transcript = "Transcript"
    case post = "Whole post"

    var id: String { rawValue }
}

enum Quality: String, CaseIterable, Identifiable {
    case best = "Best (MP4)"
    case p1080 = "1080p"
    case p720 = "720p"
    case p480 = "480p"

    var id: String { rawValue }

    /// H.264/AAC is preferred so files open in QuickTime, Keynote, Premiere, etc.
    var args: [String] {
        let sort: String
        switch self {
        case .best: sort = "vcodec:h264,res,acodec:m4a"
        case .p1080: sort = "res:1080,vcodec:h264,acodec:m4a"
        case .p720: sort = "res:720,vcodec:h264,acodec:m4a"
        case .p480: sort = "res:480,vcodec:h264,acodec:m4a"
        }
        return ["-S", sort, "--merge-output-format", "mp4"]
    }
}

enum AudioFormat: String, CaseIterable, Identifiable {
    case mp3 = "MP3"
    case m4a = "M4A"

    var id: String { rawValue }

    var args: [String] {
        switch self {
        case .mp3: return ["-f", "ba[ext=m4a]/ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "0"]
        case .m4a: return ["-f", "ba[ext=m4a]/ba/b", "-x", "--audio-format", "m4a"]
        }
    }
}

enum Browser: String, CaseIterable, Identifiable {
    case none = "Don't use"
    case chrome = "Chrome"
    case safari = "Safari"
    case firefox = "Firefox"
    case brave = "Brave"
    case edge = "Edge"
    case opera = "Opera"
    case vivaldi = "Vivaldi"

    var id: String { rawValue }
    var ytdlpName: String? { self == .none ? nil : rawValue.lowercased() }

    var bundleID: String? {
        switch self {
        case .none: return nil
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        case .firefox: return "org.mozilla.firefox"
        case .brave: return "com.brave.Browser"
        case .edge: return "com.microsoft.edgemac"
        case .opera: return "com.operasoftware.Opera"
        case .vivaldi: return "com.vivaldi.Vivaldi"
        }
    }

    var isInstalled: Bool {
        bundleID.map { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } ?? true
    }

    enum Access {
        case ready, blocked, noLogins, notInstalled
    }

    /// Whether JAGBA can read this browser's saved logins. macOS protects
    /// some browsers' data (Chrome's, Safari's) unless JAGBA has Full Disk
    /// Access; yt-dlp then just says it "could not find" the cookies.
    /// Only folder and file names are checked, never their contents.
    func access() -> Access {
        guard self != .none else { return .ready }
        guard isInstalled else { return .notInstalled }
        let fm = FileManager.default
        guard let (root, cookieFiles) = loginStore else { return .noLogins }
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: root.path)
        } catch {
            let ns = error as NSError
            let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
            if ns.code == NSFileReadNoPermissionError || posix == Int(EPERM) || posix == Int(EACCES) { return .blocked }
            return .noLogins
        }
        // Profiles are subfolders (Default, Profile 1, xyz.default-release…);
        // some browsers keep cookies at the top level too.
        for dir in [""] + entries {
            for file in cookieFiles where fm.fileExists(atPath: root.appendingPathComponent(dir).appendingPathComponent(file).path) {
                return .ready
            }
        }
        return .noLogins
    }

    /// The folder holding the browser's saved logins, and the cookie file
    /// names to look for in it (or in its profile subfolders).
    var loginStore: (folder: URL, files: [String])? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support")
        switch self {
        case .none: return nil
        case .safari: return (home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies"), ["Cookies.binarycookies"])
        case .firefox: return (support.appendingPathComponent("Firefox/Profiles"), ["cookies.sqlite"])
        case .opera: return (support.appendingPathComponent("com.operasoftware.Opera"), ["Cookies", "Network/Cookies"])
        default: return chromiumFolder.map { (support.appendingPathComponent($0), ["Cookies", "Network/Cookies"]) }
        }
    }

    /// Where Chromium-based browsers keep their settings, which list profiles.
    private var chromiumFolder: String? {
        switch self {
        case .chrome: return "Google/Chrome"
        case .brave: return "BraveSoftware/Brave-Browser"
        case .edge: return "Microsoft Edge"
        case .vivaldi: return "Vivaldi"
        default: return nil
        }
    }

    /// The browser's profiles (folder name and display name), e.g. a separate
    /// profile for a research account. Empty when there's only one.
    func profiles() -> [(id: String, name: String)] {
        guard let folder = chromiumFolder else { return [] }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(folder)/Local State")
        guard let data = try? Data(contentsOf: file) else { return [] }
        return Self.parseProfiles(data)
    }

    static func parseProfiles(_ localState: Data) -> [(id: String, name: String)] {
        guard let obj = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
              let cache = (obj["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] else { return [] }
        let list = cache.map { (id: $0.key, name: $0.value["name"] as? String ?? $0.key) }
            .sorted { $0.id == "Default" || ($1.id != "Default" && $0.id.localizedStandardCompare($1.id) == .orderedAscending) }
        return list.count > 1 ? list : []
    }
}

/// Which browser login to borrow, if any. Only used for sites that need it.
struct Login: Equatable {
    var browser: Browser = .none
    var profile = ""

    var isSet: Bool { browser != .none }

    /// yt-dlp's form: "chrome" or "chrome:Profile 2".
    var ytdlpArg: String? {
        guard let name = browser.ytdlpName else { return nil }
        return profile.isEmpty ? name : "\(name):\(profile)"
    }

    /// gallery-dl can limit which cookies it loads to one site:
    /// "chrome/.instagram.com:Profile 2".
    func galleryArg(for link: String) -> String? {
        guard let name = browser.ytdlpName else { return nil }
        var arg = name
        if let host = URL(string: link)?.host {
            let parts = host.split(separator: ".")
            if parts.count >= 2 { arg += "/." + parts.suffix(2).joined(separator: ".") }
        }
        if !profile.isEmpty { arg += ":" + profile }
        return arg
    }
}

/// Languages offered for transcripts. "Auto" guesses from the video's
/// metadata and caption text; the rest are ISO 639-1 codes.
enum Languages {
    static let auto = ""
    static let all: [(code: String, name: String)] = [
        ("en", "English"), ("fr", "French"), ("es", "Spanish"), ("pt", "Portuguese"), ("de", "German"),
        ("it", "Italian"), ("nl", "Dutch"), ("ar", "Arabic"), ("hi", "Hindi"), ("zh", "Chinese"),
        ("ja", "Japanese"), ("ko", "Korean"), ("ru", "Russian"), ("tr", "Turkish"), ("sw", "Swahili"),
        ("yo", "Yoruba"), ("ha", "Hausa"), ("ig", "Igbo"), ("am", "Amharic"), ("zu", "Zulu"),
    ]

    static func name(_ code: String) -> String {
        all.first { $0.code == code }?.name ?? Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
