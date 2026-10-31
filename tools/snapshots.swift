// Renders every screen of JAGBA to PNGs with sample data, for design review.
// Build: see tools/snapshots.sh
import AppKit
import SwiftUI

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let thumb = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)

/// Draws controls as they look in the front window (blue default buttons).
final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@MainActor
func render<V: View>(_ name: String, width: CGFloat, height: CGFloat, dark: Bool = true, @ViewBuilder _ view: () -> V) {
    let host = NSHostingView(rootView: view().frame(width: width, height: height).environment(\.controlActiveState, .key))
    host.frame = CGRect(x: 0, y: 0, width: width, height: height)
    let window = KeyWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = host
    host.wantsLayer = true
    window.setFrameOrigin(NSPoint(x: -20000, y: -20000))  // keep it off screen
    window.orderBack(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))  // let images load
    host.layoutSubtreeIfNeeded()
    // Draw the view's layer tree (cacheDisplay misses SwiftUI's layers).
    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: scale, y: scale)
    ctx.setFillColor(CGColor(red: 0x1E / 255, green: 0x1C / 255, blue: 0x1A / 255, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if host.layer?.contentsAreFlipped() == true || host.isFlipped {
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
    }
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        host.layer!.render(in: ctx)
    }
    try! rep.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name + ".png"))
    window.orderOut(nil)
    print("rendered", name)
}

@MainActor
func readyTools() -> Tools {
    let t = Tools()
    t.ytdlp = "/x/yt-dlp"; t.ytdlpVersion = "2026.10.26"; t.ytdlpIsManaged = true
    t.ffmpeg = "/x/ffmpeg"; t.jsRuntime = "/x/deno"
    t.galleryDL = Command(executable: "/x/python3", prefix: ["-m", "gallery_dl"])
    t.whisper = Command(executable: "/opt/homebrew/bin/whisper")
    return t
}

@MainActor
func youtubeInfo() -> MediaInfo {
    var i = MediaInfo(placeholderFor: "https://www.youtube.com/watch?v=dQx7Lb2kZa4")
    i.isPlaceholder = false
    i.id = "dQx7Lb2kZa4"; i.title = "How archives remember: oral history in Lagos | Lecture 4"
    i.uploader = "Open History Lab"; i.site = "Youtube"; i.duration = 1119; i.thumbnail = thumb
    i.language = "en"; i.autoSubs = ["en-orig"]; i.pageURL = "https://www.youtube.com/watch?v=dQx7Lb2kZa4"
    return i
}

@MainActor
func job(_ model: AppModel, title: String, mode: Mode, clip: (Double, Double)? = nil, state: DownloadJob.State, progress: Double? = nil, status: String, files: [String] = [], note: String? = nil, transcript: Bool = false) -> DownloadJob {
    var spec = JobSpec(link: "https://example.com", mode: mode, folder: model.folder, login: Login(browser: .chrome))
    spec.clip = clip; spec.alsoTranscript = transcript
    let j = DownloadJob(spec: spec)
    j.title = title; j.state = state; j.progress = progress; j.status = status; j.note = note
    j.files = files.map { URL(fileURLWithPath: "/Users/you/Downloads/" + $0) }
    return j
}

MainActor.assumeIsolated {
    Snapshotting.active = true
    Theme.registerFonts()
    let updates = AppUpdates()
    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    @MainActor func model(_ t: Tools) -> AppModel { let m = AppModel(tools: t); m.folder = downloads; m.browser = .safari; return m }

    // 1. Welcome.
    do {
        let t = readyTools(); let m = model(t)
        render("1-welcome", width: 880, height: 640) { ContentView().environmentObject(m).environmentObject(t).environmentObject(updates) }
    }
    // 2. A YouTube video loaded, clipping, with downloads.
    do {
        let t = readyTools(); let m = model(t)
        m.link = "https://www.youtube.com/watch?v=dQx7Lb2kZa4&t=600"
        m.info = youtubeInfo(); m.mode = .video; m.clipMode = true; m.start = 600; m.end = 632.5
        m.alsoTranscript = true; m.toggleZoom()
        m.jobs = [
            job(m, title: "How archives remember: oral history in Lagos | Lecture 4", mode: .video, clip: (600, 632), state: .running, progress: 0.64, status: "Downloading…", transcript: true),
            job(m, title: "Inside the lab: how researchers film cells dividing", mode: .transcript, state: .queued, status: "Waiting…"),
            job(m, title: "Lagos street food tour", mode: .post, state: .done, progress: 1, status: "Saved 6 files",
                files: ["slide 01-3456.jpg", "slide 02-3457.jpg", "slide 03-3458.mp4", "slide 04-3459.jpg", "slide 05-3460.jpg", "slide 06-3461.mp4"]),
            job(m, title: "Instagram reel C9xY", mode: .audio, state: .failed("Instagram wants you to be logged in. Choose the browser you're logged in with under “Use login from”, then try again."), status: "Failed"),
        ]
        render("2-clip-video", width: 880, height: 1260) { ContentView().environmentObject(m).environmentObject(t).environmentObject(updates) }
    }
    // 3. The "Change" options.
    do {
        let t = readyTools(); let m = model(t); m.mode = .transcript
        render("3-change-options", width: 380, height: 300) { OptionsPopover().environmentObject(m) }
    }
    // 4. Transcript only.
    do {
        let t = readyTools(); let m = model(t)
        m.link = "https://www.youtube.com/watch?v=dQx7Lb2kZa4"
        m.info = youtubeInfo(); m.mode = .transcript; m.clipMode = false
        m.jobs = [job(m, title: "How archives remember: oral history in Lagos | Lecture 4", mode: .transcript, state: .done, progress: 1, status: "Saved 2 files",
                      files: ["How archives remember： oral history in Lagos [dQx7Lb2kZa4].txt", "How archives remember： oral history in Lagos [dQx7Lb2kZa4].srt"],
                      note: "Transcript from YouTube automatic captions.")]
        render("4-transcript", width: 880, height: 860) { ContentView().environmentObject(m).environmentObject(t).environmentObject(updates) }
    }
    // 5. Audio clip + transcript in Yoruba.
    do {
        let t = readyTools(); let m = model(t)
        m.link = "https://www.youtube.com/watch?v=dQx7Lb2kZa4"
        m.info = youtubeInfo(); m.mode = .audio; m.clipMode = true; m.start = 125; m.end = 170
        m.alsoTranscript = true; m.language = "yo"
        render("5-audio", width: 880, height: 760) { ContentView().environmentObject(m).environmentObject(t).environmentObject(updates) }
    }
    // 6. Instagram carousel.
    do {
        let t = readyTools(); let m = model(t)
        m.link = "https://www.instagram.com/p/DAbc123/"
        var info = MediaInfo(placeholderFor: m.link); info.entryCount = 6; info.title = "Lagos street food tour"; info.uploader = "lagoseats"
        m.info = info; m.mode = .post
        m.loadNote = "This post has 6 slides. “Whole post” saves every one of them, photos included."
        render("6-instagram", width: 880, height: 660) { ContentView().environmentObject(m).environmentObject(t).environmentObject(updates) }
    }
    // 7. Batch sheet.
    do {
        let t = readyTools(); let m = model(t); m.mode = .transcript
        m.batchText = """
        https://www.youtube.com/watch?v=dQx7Lb2kZa4
        https://www.tiktok.com/@scout2015/video/6718335390845095173
        Interview from last week: https://www.instagram.com/reel/C9xYzAbCdEf/
        https://youtu.be/IHZwWFHWa-w
        """
        render("7-batch", width: 600, height: 470) { BatchView().environmentObject(m).environmentObject(t).environmentObject(updates) }
    }
    // 8. Settings.
    do {
        let t = readyTools(); t.engine = .apple
        render("8-settings", width: 560, height: 860) { SettingsView().environmentObject(t).environmentObject(updates) }
    }
}
