import AVFoundation
import Foundation
import Speech

/// One caption line: a few seconds of speech with its text.
struct Segment {
    var start: Double
    var end: Double
    var text: String
}

enum TranscriptEngine: String, CaseIterable, Identifiable {
    case apple = "Apple (built in)"
    case whisper = "Whisper"
    var id: String { rawValue }
}

enum TranscriptError: LocalizedError {
    case unsupportedLanguage(String)
    case noSpeech
    case speechUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage(let name):
            return "Apple's speech recognition can't transcribe \(name). Install Whisper (see Settings › Transcripts) to transcribe this language."
        case .noSpeech:
            return "No speech was found in this audio."
        case .speechUnavailable(let why):
            return "Speech recognition isn't available: \(why)"
        }
    }
}

enum Transcript {
    /// The spoken language as stated by the site (YouTube usually says).
    /// Guessing from the title isn't reliable: text detection doesn't know
    /// many languages (Yoruba text with tone marks reads as Vietnamese).
    static func statedLanguage(_ info: MediaInfo?) -> String? {
        guard let lang = info?.language, !lang.isEmpty else { return nil }
        return String(lang.prefix { $0 != "-" && $0 != "_" }).lowercased()
    }

    /// Converts any audio or video file to 16 kHz mono WAV, which every
    /// speech engine reads. Optionally keeps just a time range.
    static func makeWav(from input: URL, ffmpeg: String, range: (Double, Double)? = nil) async throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("jagba-\(UUID().uuidString).wav")
        var args = ["-nostdin", "-y", "-v", "error"]
        if let range { args += ["-ss", String(range.0), "-to", String(range.1)] }
        args += ["-i", input.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", out.path]
        let r = await Shell.run(ffmpeg, args)
        guard r.ok else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Couldn't read the audio: \(r.err)"]) }
        return out
    }

    // MARK: Grouping words into caption lines

    struct Word {
        var text: String
        var start: Double
        var end: Double
    }

    /// Groups timed words into readable lines: a new line starts after a
    /// sentence ends, after a pause, or when a line gets too long.
    static func group(_ words: [Word]) -> [Segment] {
        var segments: [Segment] = []
        var current: [Word] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(Segment(start: first.start, end: last.end, text: text)) }
            current.removeAll()
        }

        for word in words {
            if let last = current.last {
                let count = current.count
                let endsSentence = last.text.trimmingCharacters(in: .whitespaces).last.map { ".?!。？！".contains($0) } ?? false
                if count >= 14
                    || word.end - current[0].start > 7
                    || word.start - last.end > 1.2
                    || (endsSentence && count >= 4) {
                    flush()
                }
            }
            current.append(word)
        }
        flush()
        return segments
    }

    // MARK: Writing files

    /// Plain text: paragraphs split at long pauses, with a header that says
    /// where the words came from (handy when quoting).
    static func plainText(_ segments: [Segment], header: String) -> String {
        var paragraphs: [String] = []
        var current = ""
        var lastEnd: Double?
        for seg in segments {
            if let lastEnd, seg.start - lastEnd > 2.5 || current.count > 600, !current.isEmpty {
                paragraphs.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + seg.text
            lastEnd = seg.end
        }
        if !current.isEmpty { paragraphs.append(current) }
        return header + "\n\n" + paragraphs.joined(separator: "\n\n") + "\n"
    }

    static func srt(_ segments: [Segment]) -> String {
        segments.enumerated().map { i, s in
            "\(i + 1)\n\(TimeFormat.srt(s.start)) --> \(TimeFormat.srt(max(s.end, s.start + 0.3)))\n\(s.text)\n"
        }.joined(separator: "\n")
    }

    /// Writes "<base>.txt" and "<base>.srt" and returns both URLs.
    static func save(_ segments: [Segment], to base: URL, header: String) throws -> [URL] {
        let txt = base.appendingPathExtension("txt")
        let srt = base.appendingPathExtension("srt")
        try plainText(segments, header: header).write(to: txt, atomically: true, encoding: .utf8)
        try self.srt(segments).write(to: srt, atomically: true, encoding: .utf8)
        return [txt, srt]
    }

    /// Keeps the segments inside a clip and shifts them so the clip starts at 0.
    static func trim(_ segments: [Segment], to range: (Double, Double)) -> [Segment] {
        segments.compactMap { s in
            guard s.end > range.0, s.start < range.1 else { return nil }
            return Segment(start: max(0, s.start - range.0), end: min(range.1, s.end) - range.0, text: s.text)
        }
    }

    // MARK: YouTube captions

    /// Parses YouTube's json3 caption format, which (unlike its VTT) doesn't
    /// repeat each line several times in automatic captions.
    static func parseJSON3(_ data: Data) -> [Segment] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = obj["events"] as? [[String: Any]] else { return [] }
        var words: [Word] = []
        for e in events {
            guard let segs = e["segs"] as? [[String: Any]] else { continue }
            let start = ((e["tStartMs"] as? NSNumber)?.doubleValue ?? 0) / 1000
            let dur = ((e["dDurationMs"] as? NSNumber)?.doubleValue ?? 0) / 1000
            for (i, seg) in segs.enumerated() {
                guard var text = seg["utf8"] as? String, text != "\n" else { continue }
                text = text.replacingOccurrences(of: "\n", with: " ")
                let offset = ((seg["tOffsetMs"] as? NSNumber)?.doubleValue ?? 0) / 1000
                let nextOffset = i + 1 < segs.count ? ((segs[i + 1]["tOffsetMs"] as? NSNumber)?.doubleValue ?? 0) / 1000 : dur
                // Make sure words are separated by a space.
                if let last = words.last, !last.text.hasSuffix(" "), !text.hasPrefix(" ") { text = " " + text }
                words.append(Word(text: text, start: start + offset, end: start + max(offset, nextOffset)))
            }
        }
        // An event's last word otherwise lasts until the line leaves the
        // screen, which makes caption lines overlap.
        for i in words.indices.dropLast() where words[i + 1].start > words[i].start {
            words[i].end = min(words[i].end, words[i + 1].start)
        }
        return group(words)
    }

    // MARK: Whisper output

    static func parseWhisperJSON(_ data: Data) -> [Segment] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segs = obj["segments"] as? [[String: Any]] else { return [] }
        return segs.compactMap { s in
            guard let text = (s["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return Segment(start: (s["start"] as? NSNumber)?.doubleValue ?? 0, end: (s["end"] as? NSNumber)?.doubleValue ?? 0, text: text)
        }
    }
}

// MARK: - Apple speech recognition (macOS 26+)

@available(macOS 26, *)
enum AppleSpeech {
    /// The closest supported locale for a language code (nil = the Mac's language).
    /// Prefers the Mac's own region (e.g. English as set up on this Mac),
    /// then the most common variant of the language.
    static func locale(for code: String?) async -> Locale? {
        let lang = code ?? Locale.current.language.languageCode?.identifier ?? "en"
        let matches = await SpeechTranscriber.supportedLocales.filter { $0.language.languageCode?.identifier == lang }
        if let region = Locale.current.region?.identifier, let m = matches.first(where: { $0.region?.identifier == region }) {
            return m
        }
        let usual = ["en": "US", "fr": "FR", "es": "ES", "pt": "BR", "de": "DE", "it": "IT", "zh": "CN", "ja": "JP",
                     "ko": "KR", "ar": "SA", "hi": "IN", "nl": "NL", "ru": "RU", "tr": "TR"]
        if let region = usual[lang], let m = matches.first(where: { $0.region?.identifier == region }) { return m }
        return matches.first
    }

    static func transcribe(_ wav: URL, locale: Locale, duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> [Segment] {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        // The first time a language is used, macOS downloads its model.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: wav)
        let collector = Task { () throws -> [Transcript.Word] in
            var words: [Transcript.Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters)
                    if let range = run.audioTimeRange {
                        words.append(Transcript.Word(text: text, start: range.start.seconds, end: range.end.seconds))
                    } else if !words.isEmpty {
                        words[words.count - 1].text += text
                    }
                }
                if duration > 0 { progress(min(1, result.range.end.seconds / duration)) }
            }
            return words
        }
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
        let words = try await collector.value
        _ = analyzer  // keep the analyzer alive until every result has arrived
        return Transcript.group(words)
    }
}

// MARK: - Older Macs (macOS 14–15)

enum LegacySpeech {
    static func transcribe(_ wav: URL, languageCode: String?) async throws -> [Segment] {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw TranscriptError.speechUnavailable("allow JAGBA under System Settings › Privacy & Security › Speech Recognition.")
        }
        let locale = languageCode.map { Locale(identifier: $0) } ?? Locale.current
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptError.unsupportedLanguage(Languages.name(languageCode ?? locale.language.languageCode?.identifier ?? "this language"))
        }
        guard recognizer.isAvailable else { throw TranscriptError.speechUnavailable("the recognizer is busy or offline.") }

        let request = SFSpeechURLRecognitionRequest(url: wav)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        return try await withCheckedThrowingContinuation { cont in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    cont.resume(throwing: error)
                } else if let result, result.isFinal {
                    finished = true
                    let words = result.bestTranscription.segments.map {
                        Transcript.Word(text: " " + $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    }
                    cont.resume(returning: Transcript.group(words))
                }
            }
        }
    }
}
