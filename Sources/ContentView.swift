import SwiftUI

/// Set by the screenshot tool: off-screen rendering can't draw scroll views.
enum Snapshotting {
    static var active = false
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var tools: Tools
    @StateObject private var preview = Preview()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(compact: model.info != nil || !model.jobs.isEmpty)
            ToolPrompts()
            if Snapshotting.active {
                mainContent
                Spacer(minLength: 0)
            } else {
                ScrollView { mainContent }
            }
        }
        .background(Theme.soot.ignoresSafeArea())
        .foregroundStyle(Theme.bone)
        .preferredColorScheme(.dark)
        .tint(Theme.butter)
        .onChange(of: model.info?.id) { _, _ in preview.load(model.info) }
        .sheet(isPresented: $model.showBatch) { BatchView() }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.info == nil && !model.loading && model.loadError == nil && model.jobs.isEmpty {
                welcome
            } else {
                linkRow
                if model.loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking up link…").foregroundStyle(Theme.muted)
                    }
                    .padding(.top, 18)
                }
                if let err = model.loadError { NoteBox(text: err, style: .warning).padding(.top, 18) }
                if let info = model.info {
                    mediaCard(info)
                    if let note = model.loadNote { NoteBox(text: note, style: .info).padding(.bottom, 18) }
                    ModeTabs(selection: $model.mode).padding(.bottom, 18)
                    if model.canClip { trimSection }
                    modeOptions
                    footer
                }
                if !model.jobs.isEmpty { DownloadsList().padding(.top, 30) }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 6)
        .padding(.bottom, 28)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            Wordmark(height: 88).padding(.bottom, 18)
            Text("Save just the part you need: a clip, the audio, a transcript, or a whole post.")
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .padding(.bottom, 26)
            HStack(spacing: 8) {
                PaperField(placeholder: "Paste a YouTube, TikTok or Instagram link", text: $model.link) { load() }
                Button("Load") { load() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.link.isEmpty || !tools.ready)
            }
            .frame(maxWidth: 620)
            HStack(spacing: 18) {
                Button("Paste a link") { pasteAndLoad() }
                Button("Paste several links…") { model.showBatch = true }
            }
            .buttonStyle(QuietButtonStyle())
            .padding(.top, 12)
            HStack(spacing: 26) {
                ForEach([(Mode.video, "Clips"), (.audio, "Audio"), (.transcript, "Transcripts"), (.post, "Whole posts")], id: \.1) { mode, title in
                    HStack(spacing: 7) { ModeDot(mode: mode); Text(title).labelStyle() }
                }
            }
            .padding(.top, 34)
            Text("Tip: a YouTube “Share at 1:23” link starts the clip at 1:23.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted.opacity(0.8))
                .padding(.top, 22)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 50)
        .padding(.bottom, 30)
    }

    // MARK: Link

    private var linkRow: some View {
        HStack(spacing: 8) {
            PaperField(placeholder: "Paste a YouTube, TikTok or Instagram link", text: $model.link) { load() }
            Button("Paste several…") { model.showBatch = true }
                .buttonStyle(SecondaryButtonStyle())
            Button("Load") { load() }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.link.isEmpty || model.loading || !tools.ready)
        }
    }

    private func load() { Task { await model.load() } }

    private func pasteAndLoad() {
        if let s = NSPasteboard.general.string(forType: .string) {
            model.link = s.trimmingCharacters(in: .whitespacesAndNewlines)
            load()
        }
    }

    // MARK: Media

    private func mediaCard(_ info: MediaInfo) -> some View {
        HStack(alignment: .top, spacing: 20) {
            ZStack {
                if info.isPlaceholder {
                    VStack(spacing: 8) {
                        Image(systemName: "square.stack.fill").font(.system(size: 38))
                        Text("\(info.site) post").font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Theme.muted)
                } else if let player = preview.player, !preview.unavailable {
                    PlayerView(player: player)
                } else {
                    AsyncImage(url: info.thumbnail) { img in
                        img.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Theme.raised
                    }
                    if preview.unavailable {
                        Text("No preview for this site. You can still type start and end times.")
                            .font(.system(size: 11))
                            .padding(6)
                            .background(Theme.soot.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                            .padding(8)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .frame(width: 420, height: 236)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.bone.opacity(0.08)))

            VStack(alignment: .leading, spacing: 6) {
                Text(info.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.boneBright)
                    .lineLimit(4)
                    .textSelection(.enabled)
                Text(mediaSubtitle(info)).font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 22)
    }

    private func mediaSubtitle(_ info: MediaInfo) -> String {
        var parts: [String] = []
        if let u = info.uploader { parts.append(u) }
        if !info.site.isEmpty { parts.append(info.isYouTube ? "YouTube" : info.site) }
        if let d = info.duration { parts.append(TimeFormat.format(d, tenths: false)) }
        if info.entryCount > 1 { parts.append("\(info.entryCount) slides") }
        if info.isYouTube && info.captionTrack(language: nil) != nil { parts.append("has captions") }
        return parts.joined(separator: " · ")
    }

    // MARK: Trim

    private var trimSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Segmented(options: [(true, "Clip"), (false, model.mode == .transcript ? "Whole video" : "Full video")], selection: $model.clipMode)
                Spacer()
                if model.clipMode {
                    Button(model.zoom == nil ? "⊕ Zoom in" : "⊖ Show whole video") { model.toggleZoom() }
                        .buttonStyle(QuietButtonStyle())
                        .help("Zoom the timeline around your clip for fine adjustments")
                }
            }
            if model.clipMode {
                RangeBar(start: $model.start, end: $model.end, duration: model.duration, playhead: preview.time, visible: model.zoom) { t in
                    preview.seek(t)
                }
                .padding(.top, 10)
                HStack {
                    Text(TimeFormat.format(model.zoom?.lowerBound ?? 0, tenths: false))
                    Spacer()
                    Text(TimeFormat.format(model.zoom?.upperBound ?? model.duration, tenths: false))
                }
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
                HStack(spacing: 10) {
                    Text("In").labelStyle()
                    TimeField(value: $model.start, limit: model.duration)
                    Spacer()
                    Group {
                        if model.clipValid {
                            Text(TimeFormat.format(model.end - model.start)).foregroundColor(Theme.bone) + Text(" clip").foregroundColor(Theme.muted)
                        } else {
                            Text("End must be after start").foregroundColor(Theme.alert)
                        }
                    }
                    .font(Theme.mono(13))
                    Spacer()
                    Text("Out").labelStyle()
                    TimeField(value: $model.end, limit: model.duration)
                }
                .padding(.top, 14)
                // ⌘[ and ⌘] set the in and out points from the playhead.
                HStack {
                    Button("") { model.start = min(preview.time, model.end - 0.5) }.keyboardShortcut("[", modifiers: .command)
                    Button("") { model.end = max(preview.time, model.start + 0.5) }.keyboardShortcut("]", modifiers: .command)
                }
                .frame(width: 0, height: 0).opacity(0).disabled(preview.player == nil)
            }
        }
        .padding(.bottom, 18)
    }

    // MARK: Per-mode options

    @ViewBuilder
    private var modeOptions: some View {
        HStack(spacing: 22) {
            if model.usingClip && model.mode != .post && model.mode != .transcript {
                Button("▶  Play clip") { preview.play(from: model.start, to: model.end) }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(preview.player == nil || !model.clipValid)
            }
            switch model.mode {
            case .video:
                Menu {
                    ForEach(Quality.allCases) { q in Button(q.rawValue) { model.quality = q } }
                } label: {
                    (Text("Quality ").foregroundColor(Theme.muted) + Text(model.quality.rawValue).foregroundColor(Theme.bone)).font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Toggle("Also save transcript", isOn: $model.alsoTranscript).toggleStyle(CheckboxStyle())
                if model.usingClip {
                    Toggle("Exact cut", isOn: $model.preciseCut).toggleStyle(CheckboxStyle())
                        .help("Re-encodes the clip so it starts and ends exactly where you set. Turn off for a faster download that may start a second or two early.")
                }
            case .audio:
                Segmented(options: AudioFormat.allCases.map { ($0, $0.rawValue) }, selection: $model.audioFormat)
                Toggle("Also save transcript", isOn: $model.alsoTranscript).toggleStyle(CheckboxStyle())
            case .transcript:
                (Text("Saves a ") + Text(".txt").foregroundColor(Theme.bone) + Text(" to read and quote and an ") + Text(".srt").foregroundColor(Theme.bone) + Text(" subtitle file. No video is downloaded."))
                    .font(.system(size: 13)).foregroundColor(Theme.muted)
            case .post:
                Text("Saves every photo and video in slide order, in a folder named after the post.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                if tools.galleryDL == nil {
                    Button("Install gallery-dl (60 MB, once)") { Task { await tools.installGalleryDL() } }
                        .buttonStyle(SecondaryButtonStyle(small: true))
                        .disabled(tools.isBusy)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Footer: one line of settings, and the action

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1).padding(.top, 24)
            HStack(spacing: 14) {
                Button { model.showOptions.toggle() } label: { optionLine }
                    .buttonStyle(.plain)
                    .popover(isPresented: $model.showOptions, arrowEdge: .bottom) { OptionsPopover() }
                Spacer()
                Button(downloadTitle) { model.download() }
                    .buttonStyle(PrimaryButtonStyle(big: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canDownload)
            }
            .padding(.top, 18)
        }
    }

    private var optionLine: some View {
        var parts: [Text] = [
            model.browser == .none ? Text("No").foregroundColor(Theme.bone) + Text(" login") : Text(model.browser.rawValue).foregroundColor(Theme.bone) + Text(" login"),
            Text(model.folder.lastPathComponent).foregroundColor(Theme.bone) + Text(" folder"),
        ]
        if model.showsLanguage {
            parts.append(Text(model.language.isEmpty ? "Auto" : Languages.name(model.language)).foregroundColor(Theme.bone) + Text(" language"))
        }
        parts.append(Text("Change").underline(pattern: .dot).foregroundColor(Theme.bone))
        return parts.dropFirst().reduce(parts[0]) { $0 + Text("  ·  ").foregroundColor(Theme.muted.opacity(0.6)) + $1 }
            .font(.system(size: 13))
            .foregroundColor(Theme.muted)
    }

    private var downloadTitle: String {
        switch model.mode {
        case .video: return model.usingClip ? "Download clip" : "Download video"
        case .audio: return model.usingClip ? "Download audio clip" : "Download audio"
        case .transcript: return model.usingClip ? "Get transcript of clip" : "Get transcript"
        case .post: return model.info.map { $0.entryCount > 1 ? "Save \($0.entryCount) slides" : "Save whole post" } ?? "Save whole post"
        }
    }

    private var canDownload: Bool {
        guard model.clipValid else { return false }
        switch model.mode {
        case .post: return tools.galleryDL != nil
        case .transcript: return tools.ready && tools.ffmpeg != nil
        default: return tools.ready && (!model.usingClip || tools.ffmpeg != nil)
        }
    }
}

// MARK: - Top bar

/// Sits where the title bar would be: the wordmark, the yt-dlp status and Settings.
struct TopBar: View {
    @EnvironmentObject var tools: Tools
    @EnvironmentObject var updates: AppUpdates
    var compact: Bool

    var body: some View {
        HStack(spacing: 10) {
            if compact { Wordmark(height: 22) }
            Spacer()
            if let release = updates.available {
                Button("JAGBA \(release.version) is available") { updates.openRelease() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.butter, in: Capsule())
                    .help("Opens the download page for the new version")
                    .padding(.trailing, 6)
            }
            if let activity = tools.activity {
                ProgressView().controlSize(.mini)
                Text(activity).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            } else if let v = tools.ytdlpVersion {
                Circle().fill(Theme.brass).frame(width: 6, height: 6)
                Text("yt-dlp \(v)").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                Button("Update") { Task { await tools.updateYtdlp() } }
                    .buttonStyle(QuietButtonStyle())
                    .font(.system(size: 11))
                    .help(tools.message ?? "Check for a newer yt-dlp")
            }
            SettingsLink {
                Image(systemName: "gearshape").foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
        }
        .padding(.leading, 84)   // room for the window buttons
        .padding(.trailing, 16)
        .frame(height: 38)
    }
}

/// Quiet one-line prompts when a helper tool is missing.
struct ToolPrompts: View {
    @EnvironmentObject var tools: Tools

    var body: some View {
        VStack(spacing: 6) {
            if !tools.ready && tools.activity == nil {
                prompt("yt-dlp isn't installed yet.", button: "Install") { await tools.installYtdlp() }
            }
            if tools.ffmpeg == nil && tools.activity == nil {
                prompt("ffmpeg is needed to cut clips, make transcripts and merge audio with video.", button: "Install ffmpeg") { await tools.installFFmpeg() }
            }
            if tools.jsRuntime == nil && tools.activity == nil && tools.ready {
                prompt("YouTube needs a small helper (Deno) to get every quality.", button: "Install Deno") { await tools.installDeno() }
            }
        }
        .padding(.horizontal, 28)
    }

    private func prompt(_ text: String, button: String, action: @escaping () async -> Void) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.butter).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.muted)
            Spacer()
            Button(button) { Task { await action() } }.buttonStyle(SecondaryButtonStyle(small: true))
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Options popover

/// The rarely changed settings, behind the "Change" link.
struct OptionsPopover: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(title: "Use login from", detail: "Only if a site asks") {
                Picker("", selection: $model.browser) {
                    ForEach(Browser.allCases.filter { $0.isInstalled || $0 == model.browser }) { b in
                        Text(browserLabel(b)).tag(b)
                    }
                }
                .labelsHidden().fixedSize()
            }
            let profiles = model.browser.profiles()
            if !profiles.isEmpty {
                divider
                row(title: "Profile", detail: "e.g. one logged in to a research account") {
                    Picker("", selection: $model.browserProfile) {
                        Text("Default").tag("")
                        ForEach(profiles, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if let note = accessNote {
                Text(note.text).font(.system(size: 11)).foregroundStyle(Theme.butter)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.bottom, 6)
                if note.blocked {
                    Button("Open Full Disk Access settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    .buttonStyle(SecondaryButtonStyle(small: true))
                    .padding(.horizontal, 10).padding(.bottom, 8)
                }
            } else if model.browser != .none {
                Text("If macOS asks about “\(model.browser.rawValue) Safe Storage”, choose Allow, not Always Allow.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
            divider
            row(title: "Save to", detail: model.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                Button("Change…", action: chooseFolder).buttonStyle(SecondaryButtonStyle(small: true))
            }
            divider
            row(title: "Spoken language", detail: "For transcripts") {
                Picker("", selection: $model.language) {
                    Text("Detect automatically").tag(Languages.auto)
                    Divider()
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                .labelsHidden().fixedSize()
            }
        }
        .padding(8)
        .frame(width: 380)
        .background(Color(hex: 0x2A2724))
        .preferredColorScheme(.dark)
    }

    private var divider: some View { Rectangle().fill(Theme.line).frame(height: 1) }

    private func row<C: View>(title: String, detail: String, @ViewBuilder control: () -> C) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.bone)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(10)
    }

    private var accessNote: (text: String, blocked: Bool)? {
        switch model.browser.access() {
        case .blocked:
            return ("macOS is blocking JAGBA from reading \(model.browser.rawValue)'s logins. Pick another browser you're logged in with, or allow JAGBA under Full Disk Access. That lets JAGBA and the tools it runs read all your files.", true)
        case .noLogins:
            return ("No saved logins found in \(model.browser.rawValue). Log in to the site there first, or pick another browser.", false)
        default:
            return nil
        }
    }

    private func browserLabel(_ b: Browser) -> String {
        switch b.access() {
        case .blocked: return "\(b.rawValue) (blocked by macOS)"
        case .noLogins: return "\(b.rawValue) (no logins found)"
        case .notInstalled: return "\(b.rawValue) (not installed)"
        case .ready: return b == .none ? "None" : b.rawValue
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.folder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { model.folder = url }
    }
}

// MARK: - Batch

struct BatchView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var tools: Tools
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Download several links").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.boneBright)
            Text("Paste anything: messy text is fine, JAGBA picks out the links.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
                .padding(.top, 4).padding(.bottom, 14)
            TextEditor(text: $model.batchText)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 150)
                .background(Theme.bone, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                let n = model.batchLinks.count
                Text(n == 0 ? "No links yet" : "\(n) link\(n == 1 ? "" : "s") found").font(Theme.mono(12)).foregroundStyle(Theme.butter)
                Spacer()
                Button("Paste") {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        model.batchText += (model.batchText.isEmpty ? "" : "\n") + s
                    }
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
            }
            .padding(.vertical, 10)
            ModeTabs(selection: $model.mode).padding(.top, 6)
            HStack(spacing: 10) {
                Text("Each link is saved in full. Two run at a time.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(batchTitle) { model.downloadBatch() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.batchLinks.isEmpty || !tools.ready || (model.mode == .post && tools.galleryDL == nil))
            }
            .padding(.top, 18)
        }
        .padding(24)
        .frame(width: 600)
        .background(Color(hex: 0x24211E))
        .preferredColorScheme(.dark)
    }

    private var batchTitle: String {
        let n = model.batchLinks.count
        let what: String
        switch model.mode {
        case .video: what = "video"
        case .audio: what = "audio file"
        case .transcript: what = "transcript"
        case .post: what = "post"
        }
        return n == 0 ? "Download" : "Get \(n) \(what)\(n == 1 ? "" : "s")"
    }
}

// MARK: - Pieces

struct NoteBox: View {
    enum Style { case warning, info }
    let text: String
    var style: Style = .warning

    var body: some View {
        // The stripe is attached to the text so it's exactly as tall as it.
        Text(text).font(.system(size: 13)).foregroundStyle(Theme.bone)
            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle().fill(style == .warning ? Theme.alert : Theme.butter).frame(width: 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DownloadsList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads").labelStyle()
                let waiting = model.jobs.filter { $0.state == .queued }.count
                if waiting > 0 { Text("· \(waiting) waiting").font(Theme.mono(11)).foregroundStyle(Theme.muted) }
                Spacer()
                Button("Clear finished") { model.clearFinished() }
                    .buttonStyle(QuietButtonStyle())
                    .font(.system(size: 12))
                    .disabled(!model.jobs.contains { !$0.isActive })
            }
            .padding(.bottom, 6)
            ForEach(model.jobs) { job in JobRow(job: job) }
        }
    }
}

struct JobRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(alignment: .center, spacing: 12) {
                ModeDot(mode: job.spec.mode)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.title).font(.system(size: 13.5)).foregroundStyle(Theme.boneBright).lineLimit(1).truncationMode(.tail)
                    statusLine
                    if job.state == .running {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.bone.opacity(0.1))
                                Capsule().fill(Theme.brass).frame(width: geo.size.width * (job.progress ?? 0.04))
                            }
                        }
                        .frame(height: 3)
                        .padding(.top, 4)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    switch job.state {
                    case .queued, .running:
                        Button("Cancel") { job.cancel() }
                    case .done:
                        if !job.files.isEmpty {
                            Button("Open") { job.open() }
                            Button("Show in Finder") { job.reveal() }
                        }
                    case .failed, .cancelled:
                        Button("Retry") { model.retry(job) }
                    }
                }
                .buttonStyle(SecondaryButtonStyle(small: true))
            }
            .padding(.vertical, 12)
            if job.state == .done, job.files.count > 1 {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(job.files.prefix(6), id: \.self) { f in
                        Text(f.lastPathComponent).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                    if job.files.count > 6 { Text("…and \(job.files.count - 6) more").font(Theme.mono(11)).foregroundStyle(Theme.muted) }
                }
                .padding(.leading, 20).padding(.bottom, 10)
            }
            if job.showLog {
                ScrollView {
                    Text(job.log.joined(separator: "\n"))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
                .padding(8)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
                .padding(.leading, 20).padding(.bottom, 12)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 0) {
            Group {
                switch job.state {
                case .failed(let message):
                    Text(message.components(separatedBy: "\n\n").first ?? message).foregroundColor(Theme.alert)
                case .done:
                    Text(job.status).foregroundColor(Theme.butter) + Text(" · " + job.spec.summary).foregroundColor(Theme.muted)
                case .running:
                    Text(job.spec.summary + " · " + job.status + (job.progress.map { " \(Int($0 * 100))%" } ?? "")).foregroundColor(Theme.muted)
                default:
                    Text(job.spec.summary + " · " + job.status.lowercased()).foregroundColor(Theme.muted)
                }
            }
            .font(.system(size: 12))
            .lineLimit(2)
            Button(job.showLog ? "  Hide details" : "  Details") { job.showLog.toggle() }
                .buttonStyle(QuietButtonStyle())
                .font(.system(size: 12))
        }
        if let note = job.note, job.state == .done {
            Text(note).font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }
}
