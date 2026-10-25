import AVFoundation
import SwiftUI
import EmberKit

/// The muted trailer that fades in behind the billboard after a few seconds.
struct HeroPreview: View {
    @EnvironmentObject var app: AppModel
    let item: JFItem
    @State private var url: URL?
    @State private var visible = false

    var body: some View {
        ZStack {
            if let url {
                PreviewPlayer(url: url, visible: $visible)
                    .opacity(visible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.8), value: visible)
            }
        }
        .allowsHitTesting(false)
        .task(id: item.id) {
            url = nil
            visible = false
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let jf = app.jf else { return }
            if let local = await jf.localTrailers(item.id).first {
                url = jf.staticStreamURL(itemId: local.id)
            } else if app.trailerServiceOK, let key = await jf.trailerCheck(itemId: item.id).key {
                url = jf.trailerStreamURL(key)
            }
        }
    }
}

private struct PreviewPlayer: UIViewRepresentable {
    let url: URL
    @Binding var visible: Bool

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.onReady = { visible = true }
        v.onEnd = { visible = false }
        v.play(url)
        return v
    }

    func updateUIView(_ v: PlayerView, context: Context) {}

    static func dismantleUIView(_ v: PlayerView, coordinator: ()) { v.stop() }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        private let player = AVPlayer()
        private var readyObservation: NSKeyValueObservation?
        private var endObserver: NSObjectProtocol?
        var onReady: (() -> Void)?
        var onEnd: (() -> Void)?

        func play(_ url: URL) {
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            let item = AVPlayerItem(url: url)
            item.preferredPeakBitRate = 8_000_000  // a preview doesn't need the full-quality stream
            player.replaceCurrentItem(with: item)
            readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                if layer.isReadyForDisplay { DispatchQueue.main.async { self?.onReady?() } }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                                 queue: .main) { [weak self] _ in self?.onEnd?() }
            player.play()
        }

        func stop() {
            player.pause()
            player.replaceCurrentItem(with: nil)
            readyObservation = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        }
    }
}
