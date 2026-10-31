import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var tools: Tools
    @EnvironmentObject var updates: AppUpdates

    var body: some View {
        Form {
            Section("JAGBA") {
                LabeledContent("Version", value: updates.currentVersion)
                HStack {
                    Button("Check for updates") { Task { await updates.check() } }
                    if updates.available != nil {
                        Button("Download \(updates.available!.version)") { updates.openRelease() }
                    }
                }
                if let result = updates.lastResult {
                    Text(result).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("yt-dlp") {
                LabeledContent("Version", value: tools.ytdlpVersion ?? "Not installed")
                Picker("Update channel", selection: Binding(get: { tools.channel }, set: { tools.channel = $0 })) {
                    Text("Stable").tag("stable")
                    Text("Nightly (newest fixes, less tested)").tag("nightly")
                }
                Toggle("Check for updates every day", isOn: Binding(get: { tools.autoUpdate }, set: { tools.autoUpdate = $0 }))
                HStack {
                    Button("Update now") { Task { await tools.updateYtdlp() } }
                        .disabled(tools.isBusy)
                    if tools.isBusy { ProgressView().controlSize(.small) }
                }
                if let msg = tools.message {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Transcripts") {
                Toggle("Use YouTube captions when available", isOn: Binding(get: { tools.useCaptions }, set: { tools.useCaptions = $0 }))
                Picker("Transcribe with", selection: Binding(get: { tools.engine }, set: { tools.engine = $0 })) {
                    ForEach(TranscriptEngine.allCases) { Text($0.rawValue).tag($0) }
                }
                if tools.engine == .whisper {
                    Picker("Whisper model", selection: Binding(get: { tools.whisperModel }, set: { tools.whisperModel = $0 })) {
                        Text("Turbo (fast, accurate)").tag("turbo")
                        Text("Small (fastest)").tag("small")
                        Text("Medium").tag("medium")
                        Text("Large (most accurate, slow)").tag("large")
                    }
                }
                LabeledContent("Whisper", value: tools.whisper?.display ?? "Not installed")
                if tools.whisper == nil {
                    Button("Install Whisper (about 1 GB)") { Task { await tools.installWhisper() } }
                        .disabled(tools.isBusy)
                }
                Text("Apple's built-in recognition is fast and needs no setup. Whisper handles more languages (for example Yoruba, Hausa and Igbo) and strong accents, and is used automatically when Apple doesn't support a language.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Whole posts") {
                LabeledContent("gallery-dl", value: tools.galleryDL?.display ?? "Not installed")
                Button(tools.galleryDL == nil ? "Install gallery-dl" : "Update gallery-dl") {
                    Task { tools.galleryDL == nil ? await tools.installGalleryDL() : await tools.updateGalleryDL() }
                }
                .disabled(tools.isBusy)
            }
            Section("Helpers") {
                LabeledContent("ffmpeg", value: tools.ffmpeg ?? "Not found")
                LabeledContent("JavaScript runtime", value: tools.jsRuntime ?? "Not found")
                Button("Show tools folder") {
                    NSWorkspace.shared.open(Paths.bin)
                }
            }
        }
        .formStyle(.grouped)
        .buttonStyle(SecondaryButtonStyle(small: true))
        .scrollContentBackground(.hidden)
        .background(Theme.soot)
        .tint(Theme.brass)
        .preferredColorScheme(.dark)
        .frame(width: 560, height: 860)
    }
}
