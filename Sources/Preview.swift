import AVFoundation
import AVKit
import SwiftUI

/// Streams a low-res version of the video so you can find the moment you want
/// before downloading anything.
@MainActor
final class Preview: ObservableObject {
    @Published var player: AVPlayer?
    @Published var time: Double = 0
    @Published var unavailable = false

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var stopAt: Double?

    func load(_ info: MediaInfo?) {
        tearDown()
        guard let info, let url = info.previewURL else {
            unavailable = info != nil
            return
        }
        unavailable = false
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": info.previewHeaders])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor in if failed { self?.unavailable = true } }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
                if let stop = self.stopAt, self.time >= stop {
                    self.player?.pause()
                    self.stopAt = nil
                }
            }
        }
        self.player = player
    }

    func seek(_ t: Double) {
        time = t
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func play(from start: Double, to end: Double) {
        seek(start)
        stopAt = end
        player?.play()
    }

    func tearDown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation = nil
        stopAt = nil
        player?.pause()
        player = nil
        time = 0
    }
}

/// The standard Mac video player view. (SwiftUI's VideoPlayer crashes in
/// apps built with the command-line tools: "failed to demangle superclass
/// of VideoPlayerView", because AVKit's AVPlayerView never gets loaded.)
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Timeline with draggable start/end handles and the current playhead.
struct RangeBar: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    let playhead: Double
    /// The part of the video the bar shows; zooming in narrows it so short
    /// clips in long videos are easy to adjust.
    var visible: ClosedRange<Double>?
    var onScrub: (Double) -> Void

    private let minLength = 0.5

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let lo = visible?.lowerBound ?? 0
            let span = max((visible?.upperBound ?? duration) - lo, 0.001)
            let x = { (t: Double) in min(max(0, CGFloat((t - lo) / span) * w), w) }
            let t = { (px: CGFloat) in min(max(lo, lo + Double(px / w) * span), min(duration, lo + span)) }

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.bone.opacity(0.12)).frame(height: 4)
                Rectangle()
                    .fill(Theme.red)
                    .frame(width: max(0, x(end) - x(start)), height: 8)
                    .offset(x: x(start))
                Rectangle()
                    .fill(Theme.butter)
                    .frame(width: 2, height: 22)
                    .offset(x: x(playhead) - 1)
                    .opacity(playhead >= lo && playhead <= lo + span ? 1 : 0)
                    .allowsHitTesting(false)
                handle.offset(x: x(start) - 6)
                    .gesture(DragGesture(coordinateSpace: .named("bar")).onChanged { g in
                        start = min(t(g.location.x), end - minLength)
                        onScrub(start)
                    })
                handle.offset(x: x(end) - 6)
                    .gesture(DragGesture(coordinateSpace: .named("bar")).onChanged { g in
                        end = max(t(g.location.x), start + minLength)
                        onScrub(end)
                    })
            }
            .frame(height: 30)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .named("bar")) { p in onScrub(t(p.x)) }
            .coordinateSpace(name: "bar")
        }
        .frame(height: 30)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Theme.bone)
            .frame(width: 12, height: 28)
            .shadow(radius: 1)
            .contentShape(Rectangle().inset(by: -6))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

/// A text field for times like 1:23 or 1:02:03.5.
struct TimeField: View {
    @Binding var value: Double
    var limit: Double?
    @StateObject private var draft = Draft()
    @FocusState private var focused: Bool

    /// Holds the text being typed (stands in for @State, which needs a
    /// compiler plugin that only ships with full Xcode).
    final class Draft: ObservableObject {
        @Published var text = ""
    }

    private var text: String {
        get { draft.text }
        nonmutating set { draft.text = newValue }
    }

    var body: some View {
        TextField("0:00", text: $draft.text)
            .textFieldStyle(.plain)
            .font(Theme.mono(15))
            .foregroundStyle(Theme.boneBright)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(width: 112)
            .background(Theme.bone.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.bone.opacity(0.14)))
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, f in if !f { commit() } }
        .onAppear { text = TimeFormat.format(value) }
        .onChange(of: value) { _, v in if !focused { text = TimeFormat.format(v) } }
    }

    private func commit() {
        if var v = TimeFormat.parse(text) {
            if let limit, limit > 0 { v = min(v, limit) }
            value = v
        }
        text = TimeFormat.format(value)
    }
}
