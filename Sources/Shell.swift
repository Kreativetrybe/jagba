import Foundation

/// Splits streamed process output into lines. yt-dlp and ffmpeg use both
/// "\n" and "\r" (progress updates), so either one ends a line.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private var all = Data()
    private let lock = NSLock()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        lock.lock()
        all.append(data)
        buffer.append(data)
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if let s = String(data: lineData, encoding: .utf8), !s.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(s)
            }
        }
        lock.unlock()
        if let onLine { lines.forEach(onLine) }
    }

    func finish() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let onLine, let s = String(data: buffer, encoding: .utf8), !s.isEmpty { onLine(s) }
        buffer.removeAll()
        return String(data: all, encoding: .utf8) ?? ""
    }
}

enum Shell {
    struct Result {
        var status: Int32
        var out: String
        var err: String
        var ok: Bool { status == 0 }
    }

    /// GUI apps don't get the shell's PATH, so add the usual Homebrew and
    /// system locations. yt-dlp looks for deno/node here for YouTube.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = [Paths.bin.path,"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = (extra + [env["PATH"] ?? ""]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    /// Runs a program and returns its output. `onLine` receives every line of
    /// stdout and stderr as it arrives; `started` hands back the Process so
    /// the caller can cancel it.
    static func run(
        _ executable: String,
        _ args: [String],
        onLine: (@Sendable (String) -> Void)? = nil,
        started: ((Process) -> Void)? = nil
    ) async -> Result {
        await withCheckedContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            process.environment = environment

            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice

            let out = LineSplitter(onLine: onLine)
            let err = LineSplitter(onLine: onLine)
            outPipe.fileHandleForReading.readabilityHandler = { h in out.append(h.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { h in err.append(h.availableData) }

            process.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: Result(status: p.terminationStatus, out: out.finish(), err: err.finish()))
            }

            do {
                try process.run()
                started?(process)
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: Result(status: -1, out: "", err: error.localizedDescription))
            }
        }
    }
}
