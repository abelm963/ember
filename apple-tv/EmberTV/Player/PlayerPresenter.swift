import AVFoundation
import AVKit
import UIKit
import EmberKit

/// Plays videos full screen with Apple TV's own player, so the Siri Remote, Dolby Vision,
/// HDR10, Dolby Atmos and "Match Content" all work as they do in Apple's apps.
@MainActor
final class PlayerPresenter: NSObject, AVPlayerViewControllerDelegate {
    static let shared = PlayerPresenter()
    private var session: PlaybackSession?

    func play(_ item: JFItem, app: AppModel, fromStart: Bool, isTrailer: Bool = false) {
        guard let jf = app.jf else { return }
        let s = PlaybackSession(app: app, jf: jf, isTrailer: isTrailer)
        present(s)
        s.start(item, from: fromStart ? nil : item.resumeSeconds)
    }

    /// Plays a plain address (trailers streamed by the server's trailer service).
    func playURL(_ url: URL, title: String) {
        let s = PlaybackSession(app: nil, jf: nil, isTrailer: true)
        present(s)
        s.startURL(url, title: title)
    }

    private func present(_ s: PlaybackSession) {
        session?.finish(dismiss: true)
        session = s
        s.controller.delegate = self
        s.onFinish = { [weak self, weak s] in
            if self?.session === s { self?.session = nil }
        }
        topController()?.present(s.controller, animated: true)
    }

    private func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    // Menu on the remote closes the player.
    nonisolated func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
        Task { @MainActor in
            if self.session?.controller === playerViewController { self.session?.finish(dismiss: false) }
        }
    }
}

/// One playback: the player, its item, and everything Ember does around it.
@MainActor
final class PlaybackSession {
    let controller = AVPlayerViewController()
    let player = AVPlayer()
    var onFinish: (() -> Void)?

    private weak var app: AppModel?
    private let jf: JellyfinClient?
    private let isTrailer: Bool

    private var item: JFItem?
    private var source: PlaybackSource?
    private var segments: [MediaSegment] = []
    private var next: JFItem?
    private var pendingSeek: Double?
    private var lastReport = Date.distantPast
    private var autoSkipped = Set<Double>()
    private var countdown: Int?
    private var countdownTask: Task<Void, Never>?
    private var creditsDismissed = false
    private var finished = false
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    init(app: AppModel?, jf: JellyfinClient?, isTrailer: Bool) {
        self.app = app
        self.jf = jf
        self.isTrailer = isTrailer
        controller.player = player
        controller.appliesPreferredDisplayCriteriaAutomatically = true  // HDR / Dolby Vision / frame rate
        controller.allowsPictureInPicturePlayback = false
        player.appliesMediaSelectionCriteriaAutomatically = true

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) {
            [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.ended()
            }
        }
    }

    // MARK: Starting

    func start(_ item: JFItem, from seconds: Double?, audio: Int? = nil, subtitle: Int? = nil) {
        guard let jf, let app else { return }
        self.item = item
        Task {
            do {
                let src = try await jf.playbackSource(item.id, maxBitrate: isTrailer ? nil : app.qualityOption.bitrate,
                                                      audioStreamIndex: audio, subtitleStreamIndex: subtitle)
                guard !finished else { return }
                source = src
                load(jf.authorized(src.url), title: title(item), subtitle: subtitleText(item), overview: item.overview,
                     artwork: jf.backdropImage(item, maxWidth: 1280), at: seconds)
                updateMenus()
                if !isTrailer {
                    await jf.reportStart(src, itemId: item.id, position: seconds ?? 0)
                    segments = await jf.mediaSegments(item.id)
                    next = item.isEpisode ? try? await jf.nextEpisode(after: item) : nil
                }
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func startURL(_ url: URL, title: String) {
        load(url, title: title, subtitle: nil, overview: nil, artwork: nil, at: nil)
    }

    private func load(_ url: URL, title: String, subtitle: String?, overview: String?, artwork: URL?, at seconds: Double?) {
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        var meta: [AVMetadataItem] = [metadata(.commonIdentifierTitle, title)]
        if let subtitle { meta.append(metadata(.iTunesMetadataTrackSubTitle, subtitle)) }
        if let overview { meta.append(metadata(.commonIdentifierDescription, overview)) }
        playerItem.externalMetadata = meta
        if let artwork {
            Task {
                if let img = await ImageStore.shared.image(artwork), let data = img.jpegData(compressionQuality: 0.85) {
                    let art = AVMutableMetadataItem()
                    art.identifier = .commonIdentifierArtwork
                    art.value = data as NSData
                    art.dataType = kCMMetadataBaseDataType_JPEG as String
                    art.extendedLanguageTag = "und"
                    playerItem.externalMetadata.append(art)
                }
            }
        }
        pendingSeek = (seconds ?? 0) > 1 ? seconds : nil
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] it, _ in
            Task { @MainActor in self?.statusChanged(it) }
        }
        player.replaceCurrentItem(with: playerItem)
        player.play()
    }

    private func statusChanged(_ it: AVPlayerItem) {
        switch it.status {
        case .readyToPlay:
            if let s = pendingSeek {
                pendingSeek = nil
                player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        case .failed:
            showError(it.error?.localizedDescription ?? "This video couldn't be played.")
        default:
            break
        }
    }

    private func metadata(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = id
        m.value = value as NSString
        m.extendedLanguageTag = "und"
        return m
    }

    private func title(_ item: JFItem) -> String { item.isEpisode ? (item.seriesName ?? item.name) : item.name }

    private func subtitleText(_ item: JFItem) -> String? {
        item.isEpisode ? "\(item.episodeLabel) · \(item.name)" : item.year.map(String.init)
    }

    // MARK: While playing

    private var position: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? t : 0
    }

    private var duration: Double {
        let d = player.currentItem?.duration.seconds ?? 0
        return d.isFinite ? d : 0
    }

    private func tick() {
        guard !finished, let item, let source, let jf, let app else { return }
        let pos = position

        // Skip Intro, in the bottom-right corner like the big streaming apps.
        var actions: [UIAction] = []
        if let intro = segments.first(where: { ($0.type == "Intro" || $0.type == "Recap") && $0.contains(pos) }) {
            if app.autoSkipIntro, !autoSkipped.contains(intro.start) {
                autoSkipped.insert(intro.start)
                seek(to: intro.end)
            } else {
                actions.append(UIAction(title: intro.type == "Recap" ? "Skip Recap" : "Skip Intro",
                                        image: UIImage(systemName: "forward.end.fill")) { [weak self] _ in
                    self?.seek(to: intro.end)
                })
            }
        }

        // Next Episode once the credits start (or in the last 25 seconds).
        if next != nil, !creditsDismissed, duration > 0, inCredits(pos) {
            if countdown == nil && app.autoplayNext { startCountdown() }
            let label = countdown.map { "Next Episode in \($0)" } ?? "Next Episode"
            actions.append(UIAction(title: label, image: UIImage(systemName: "forward.fill")) { [weak self] _ in
                self?.playNext()
            })
            if countdown != nil {
                actions.append(UIAction(title: "Watch Credits") { [weak self] _ in
                    self?.creditsDismissed = true
                    self?.countdownTask?.cancel()
                    self?.countdown = nil
                    self?.controller.contextualActions = []
                })
            }
        } else if !inCredits(pos) {
            creditsDismissed = false
        }
        if controller.contextualActions.map(\.title) != actions.map(\.title) { controller.contextualActions = actions }

        if Date().timeIntervalSince(lastReport) >= 10 {
            lastReport = Date()
            let paused = player.timeControlStatus == .paused
            Task { await jf.reportProgress(source, itemId: item.id, position: pos, paused: paused) }
        }
    }

    private func inCredits(_ pos: Double) -> Bool {
        if let outro = segments.first(where: { $0.type == "Outro" }) { return pos >= outro.start }
        return duration - pos <= 25
    }

    private func startCountdown() {
        countdown = 10
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while let self, let c = self.countdown, c > 1, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self.countdown = c - 1
                self.tick()
            }
            if !Task.isCancelled { self?.playNext() }
        }
    }

    private func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    private func playNext() {
        guard let next, let item, let source, let jf else { return }
        countdownTask?.cancel()
        countdown = nil
        creditsDismissed = false
        autoSkipped = []
        segments = []
        self.next = nil
        controller.contextualActions = []
        let pos = position
        Task { await jf.reportStopped(source, itemId: item.id, position: pos) }
        start(next, from: next.resumeSeconds)
    }

    private func ended() {
        if next != nil, app?.autoplayNext == true, !creditsDismissed {
            playNext()
        } else {
            finish(dismiss: true)
        }
    }

    // MARK: Audio and subtitles (server streams)

    /// For streams the server prepares (HLS), audio and subtitle choices are made by the server,
    /// so Ember adds its own menus. Original files use the player's built-in menus.
    private func updateMenus() {
        guard let source, source.playMethod == "Transcode", let item else {
            controller.transportBarCustomMenuItems = []
            return
        }
        var menus: [UIMenuElement] = []
        let audio = source.audioStreams
        if audio.count > 1 {
            let current = source.defaultAudioIndex
            menus.append(UIMenu(title: "Audio", image: UIImage(systemName: "speaker.wave.2"), children: audio.map { s in
                let index = s["Index"].int ?? 0
                return UIAction(title: Labels.streamLabel(s), state: index == current ? .on : .off) { [weak self] _ in
                    self?.restart(item, audio: index, subtitle: source.defaultSubtitleIndex)
                }
            }))
        }
        let subs = source.subtitleStreams
        if !subs.isEmpty {
            let current = source.defaultSubtitleIndex ?? -1
            var children: [UIMenuElement] = [UIAction(title: "Off", state: current < 0 ? .on : .off) { [weak self] _ in
                self?.restart(item, audio: source.defaultAudioIndex, subtitle: -1)
            }]
            children += subs.map { s in
                let index = s["Index"].int ?? 0
                return UIAction(title: Labels.streamLabel(s), state: index == current ? .on : .off) { [weak self] _ in
                    self?.restart(item, audio: source.defaultAudioIndex, subtitle: index)
                }
            }
            menus.append(UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), children: children))
        }
        controller.transportBarCustomMenuItems = menus
    }

    private func restart(_ item: JFItem, audio: Int?, subtitle: Int?) {
        let pos = position
        if let source, let jf { Task { await jf.reportStopped(source, itemId: item.id, position: pos) } }
        start(item, from: pos, audio: audio, subtitle: subtitle)
    }

    // MARK: Ending

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Can't play this", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.finish(dismiss: true) })
        controller.present(alert, animated: true)
    }

    func finish(dismiss: Bool) {
        guard !finished else { return }
        finished = true
        countdownTask?.cancel()
        let pos = position
        if let item, let source, let jf, !isTrailer {
            Task { await jf.reportStopped(source, itemId: item.id, position: pos) }
        }
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation = nil
        if dismiss { controller.dismiss(animated: true) }
        player.replaceCurrentItem(with: nil)
        if !isTrailer { app?.libraryChanged() }
        onFinish?()
    }
}
