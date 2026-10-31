import SwiftUI

@main
struct JagbaApp: App {
    @StateObject private var tools: Tools
    @StateObject private var model: AppModel
    @StateObject private var updates = AppUpdates()

    init() {
        Self.carryOverSettingsFromExcerpt()
        Theme.registerFonts()
        let tools = Tools()
        _tools = StateObject(wrappedValue: tools)
        _model = StateObject(wrappedValue: AppModel(tools: tools))
    }

    var body: some Scene {
        WindowGroup("JAGBA") {
            ContentView()
                .environmentObject(model)
                .environmentObject(tools)
                .environmentObject(updates)
                .frame(minWidth: 780, minHeight: 640)
                .task {
                    await tools.bootstrap()
                    await updates.checkIfDue()
                    // For testing: JAGBA_LOAD=<link> loads a link at launch.
                    if let link = ProcessInfo.processInfo.environment["JAGBA_LOAD"] {
                        model.link = link
                        await model.load()
                        FileHandle.standardError.write(Data("JAGBA_LOAD: \(model.info?.title ?? "failed") \(model.loadError ?? "") \(model.loadNote ?? "")\n".utf8))
                    }
                    // For testing: JAGBA_DIAG=1 reports, per browser, whether
                    // JAGBA and the tools it runs can see its login folder
                    // (folder names only), then quits.
                    if ProcessInfo.processInfo.environment["JAGBA_DIAG"] != nil {
                        var report = "JAGBA_DIAG\n"
                        for b in Browser.allCases where b != .none && b.isInstalled {
                            let child = await Shell.run("/bin/ls", [b.loginStore?.folder.path ?? "/nonexistent"])
                            report += "\(b.rawValue): app sees \(b.access()), helper tools \(child.ok ? "can read" : "blocked: \(child.err.trimmingCharacters(in: .whitespacesAndNewlines))")\n"
                        }
                        FileHandle.standardError.write(Data(report.utf8))
                        exit(0)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 880, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(tools)
                .environmentObject(updates)
        }
    }
}

extension JagbaApp {
    /// The app used to be called Excerpt; copy its saved choices once.
    static func carryOverSettingsFromExcerpt() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "carriedOverFromExcerpt"), let old = UserDefaults(suiteName: "app.excerpt.Excerpt") else { return }
        for key in ["browser", "browserProfile", "folder", "ytdlpChannel", "autoUpdate", "engine", "useCaptions", "whisperModel", "lastUpdateCheck"] {
            if let value = old.object(forKey: key), d.object(forKey: key) == nil { d.set(value, forKey: key) }
        }
        d.set(true, forKey: "carriedOverFromExcerpt")
    }
}
