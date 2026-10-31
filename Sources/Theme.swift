import CoreText
import SwiftUI

/// The Colorways palette and type: charcoal and bone, with red only for the
/// main action and the clip, and brass for progress.
enum Theme {
    static let red = Color(hex: 0xA8392A)
    static let bone = Color(hex: 0xD9CBB8)
    static let boneBright = Color(hex: 0xEDE2D3)
    static let butter = Color(hex: 0xD2B48C)
    static let brass = Color(hex: 0x8A6633)
    static let soot = Color(hex: 0x1E1C1A)
    static let raised = Color(hex: 0x262320)
    static let muted = Color(hex: 0x8F8373)
    static let ink = Color(hex: 0x221E1A)
    static let alert = Color(hex: 0xD2604F)
    static let line = bone.opacity(0.11)

    /// Courier Prime: for small labels, times and tool versions only.
    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "CourierPrime-Bold" : "CourierPrime-Regular", size: size)
    }

    /// Registers the bundled fonts (Resources/Fonts). Falls back to the
    /// project folder so the screenshot tool finds them too.
    static func registerFonts() {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Fonts")]
        guard let dir = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// Small uppercase typewriter label, e.g. "DOWNLOADS".
    func labelStyle() -> some View {
        self.font(Theme.mono(11)).tracking(1.5).textCase(.uppercase).foregroundStyle(Theme.muted)
    }
}

// MARK: - Wordmark

/// The JaGBa wordmark, drawn from the generated letter outlines. A stroke in
/// the background colour keeps an even cut where letters meet.
struct Wordmark: View {
    var height: CGFloat
    var ink: Color = Theme.bone
    var cut: Color = Theme.soot

    private static let shapes: [Path] = WordmarkPaths.letters.map(Self.parse)

    var body: some View {
        let scale = height / WordmarkPaths.size.height
        Canvas { ctx, _ in
            ctx.scaleBy(x: scale, y: scale)
            for path in Self.shapes {
                ctx.stroke(path, with: .color(cut), style: StrokeStyle(lineWidth: 9, lineJoin: .round))
                ctx.fill(path, with: .color(ink))
            }
        }
        .frame(width: WordmarkPaths.size.width * scale, height: height)
        .accessibilityLabel("JAGBA")
    }

    /// Parses the generated "M x y L x y … Z" path data.
    private static func parse(_ d: String) -> Path {
        var path = Path()
        var numbers: [CGFloat] = []
        var command: Character = "M"
        func flush() {
            var i = 0
            while i + 1 < numbers.count {
                let p = CGPoint(x: numbers[i], y: numbers[i + 1])
                if command == "M" { path.move(to: p); command = "L" } else { path.addLine(to: p) }
                i += 2
            }
            numbers.removeAll()
        }
        var token = ""
        for ch in d {
            if ch == "M" || ch == "L" || ch == "Z" {
                if !token.isEmpty { numbers.append(CGFloat(Double(token) ?? 0)); token = "" }
                flush()
                if ch == "Z" { path.closeSubpath() } else { command = ch }
            } else if ch == " " {
                if !token.isEmpty { numbers.append(CGFloat(Double(token) ?? 0)); token = "" }
            } else {
                token.append(ch)
            }
        }
        return path
    }
}

// MARK: - Controls

struct PrimaryButtonStyle: ButtonStyle {
    var big = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: big ? 14 : 13, weight: .semibold))
            .foregroundStyle(Color(hex: 0xF6E9DA))
            .padding(.horizontal, big ? 22 : 16).padding(.vertical, big ? 11 : 8)
            .background(Theme.red.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            .opacity(enabled ? 1 : 0.4)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var small = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 12 : 13, weight: .medium))
            .foregroundStyle(Theme.bone)
            .padding(.horizontal, small ? 10 : 14).padding(.vertical, small ? 5 : 8)
            .background(Theme.bone.opacity(configuration.isPressed ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.bone.opacity(0.14)))
            .opacity(enabled ? 1 : 0.4)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted.opacity(configuration.isPressed ? 0.6 : 1))
    }
}

/// A strip of bone paper for the link.
struct PaperField: View {
    var placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Color(hex: 0x8B7E6C)))
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 13).padding(.vertical, 10)
            // The shadow goes on the paper only, never on the text.
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bone).shadow(color: .black.opacity(0.3), radius: 1, y: 1))
            .onSubmit(onSubmit)
    }
}

/// Text tabs with an underline: Video · Audio · Transcript · Whole post.
struct ModeTabs: View {
    @Binding var selection: Mode

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(Mode.allCases) { mode in
                    Button { selection = mode } label: {
                        VStack(spacing: 9) {
                            Text(mode.rawValue)
                                .font(.system(size: 14, weight: selection == mode ? .semibold : .regular))
                                .foregroundStyle(selection == mode ? Theme.boneBright : Theme.muted)
                            Rectangle().fill(selection == mode ? Theme.bone : .clear).frame(height: 2)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

/// A small two-way switch, e.g. Clip / Full video.
struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    Text(title)
                        .font(.system(size: 12, weight: selection == value ? .medium : .regular))
                        .foregroundStyle(selection == value ? Theme.bone : Theme.muted)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(selection == value ? Theme.bone.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.bone.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A buttercream checkbox.
struct CheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(configuration.isOn ? Theme.butter : .clear)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(configuration.isOn ? .clear : Theme.bone.opacity(0.35)))
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.ink)
                    }
                }
                .frame(width: 14, height: 14)
                configuration.label.font(.system(size: 13)).foregroundStyle(Theme.bone)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A small coloured dot that marks a download's mode.
struct ModeDot: View {
    let mode: Mode
    var body: some View {
        Group {
            switch mode {
            case .video: Circle().fill(Theme.bone)
            case .audio: Circle().fill(Theme.brass)
            case .transcript: Circle().fill(Theme.butter)
            case .post: Circle().strokeBorder(Theme.bone, lineWidth: 1.5)
            }
        }
        .frame(width: 8, height: 8)
    }
}
