import AVFoundation
import AVKit
import Flutter
import UIKit

/// Full-screen playback with Apple's own player (`ember/player`).
///
/// Flutter draws video through a texture, which is always shown as SDR. Apple's
/// AVPlayerViewController hands the picture straight to the TV, so HDR10, Dolby Vision and
/// Dolby Atmos come through, the TV switches to the right mode ("Match Content"), and the
/// Siri Remote, the Info panel and Enhance Dialogue work as in Apple's apps.
///
/// Dart decides what to play (`open`, `load`) and reports progress to Jellyfin; this class
/// shows the player and tells Dart what happened (`progress`, `next`, `track`, `closed`).
final class NativePlayer: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
  static let shared = NativePlayer()

  private var channel: FlutterMethodChannel?
  private var controller: AVPlayerViewController?
  private let player = AVPlayer()
  private let spinner = UIActivityIndicatorView(style: .large)

  private var opts: [String: Any] = [:]
  private var segments: [(type: String, start: Double, end: Double)] = []
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var selectionObserver: NSObjectProtocol?
  private var statusObservation: NSKeyValueObservation?
  private var pauseObservation: NSKeyValueObservation?
  private var pendingSeek: Double?
  private var lastReport = Date.distantPast
  private var lastTick: (position: Double, at: Date)?
  private var ownSeekUntil = Date.distantPast
  private var ownChangeUntil = Date.distantPast
  private var autoSkipped = Set<Double>()
  private var countdown: Int?
  private var countdownTimer: Timer?
  private var creditsDismissed = false
  private var closed = true
  private var joinToken: UUID?
  /// A trailer that hasn't started within a few seconds is reported as failed, so Dart can
  /// try the same trailer another way.
  private var trailerWatchdog: DispatchWorkItem?

  // "Are you still watching?": episodes that ended and moved on with no remote input at all.
  private var interacted = false
  private var unattended = 0
  private var asking = false

  func register(messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "ember/player", binaryMessenger: messenger)
    ch.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    channel = ch
    NativePlayer.configureAudio()
  }

  /// Film and TV audio: lets tvOS send multichannel and Dolby Atmos to the TV or receiver, and
  /// offer Enhance Dialogue where the Apple TV and speakers support it.
  static func configureAudio() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback, options: [])
    if #available(tvOS 15.0, *) { try? session.setSupportsMultichannelContent(true) }
    try? session.setActive(true)
  }

  private func handle(_ call: FlutterMethodCall, _ result: FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "open":
      present(args)
      result(nil)
    case "load":
      if controller == nil { present(args) } else { apply(args) }
      result(nil)
    case "close":
      finish(dismiss: true)
      result(nil)
    case "failed":
      showError(args["message"] as? String ?? "This video couldn't be played.")
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func send(_ method: String, _ args: [String: Any] = [:]) {
    channel?.invokeMethod(method, arguments: args)
  }

  // MARK: Presenting

  private func present(_ args: [String: Any]) {
    if controller != nil { finish(dismiss: true) }
    let vc = AVPlayerViewController()
    vc.player = player
    vc.delegate = self
    // Switches the TV to HDR / Dolby Vision and the film's frame rate when Match Content is on.
    vc.appliesPreferredDisplayCriteriaAutomatically = true
    vc.allowsPictureInPicturePlayback = false
    player.appliesMediaSelectionCriteriaAutomatically = true

    spinner.color = .white
    spinner.translatesAutoresizingMaskIntoConstraints = false
    vc.view.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
    ])
    watchRemote(on: vc.view)

    controller = vc
    closed = false
    interacted = false
    unattended = 0
    observePlayer()
    topViewController()?.present(vc, animated: true)
    apply(args)
  }

  /// Plays a new address in the same player: the first episode, the next one, or the same one
  /// again with another audio track or subtitles.
  private func apply(_ args: [String: Any]) {
    let sameItem = (args["itemId"] as? String) != nil && (args["itemId"] as? String) == (opts["itemId"] as? String)
    opts = args
    segments = (args["segments"] as? [[String: Any]] ?? []).compactMap { s in
      guard let t = s["type"] as? String, let a = s["start"] as? Double, let b = s["end"] as? Double else { return nil }
      return (t, a, b)
    }
    if !sameItem {
      autoSkipped = []
      creditsDismissed = false
      interacted = false
    }
    cancelCountdown()
    controller?.contextualActions = []
    updateMenus()

    guard let address = args["url"] as? String, let url = URL(string: address) else {
      // Dart is still asking the server; show that something is happening.
      spinner.startAnimating()
      return
    }
    spinner.startAnimating()
    let headers = args["headers"] as? [String: String] ?? [:]
    if args["isTrailer"] as? Bool == true { startTrailerWatchdog() }
    if let audio = (args["audioUrl"] as? String).flatMap(URL.init(string:)) {
      // Picture and sound arrive as two files (some YouTube trailers): join them first.
      let token = UUID()
      joinToken = token
      Task { @MainActor in
        let joined = try? await NativePlayer.joined(video: url, audio: audio, headers: headers)
        guard self.joinToken == token, !self.closed else { return }
        guard let joined else {
          // Picture without sound isn't worth playing: let Dart find another way.
          self.trailerFailed()
          return
        }
        self.play(joined, args)
      }
      return
    }
    joinToken = nil
    play(AVPlayerItem(asset: NativePlayer.asset(url, headers)), args)
  }

  private static func asset(_ url: URL, _ headers: [String: String]) -> AVURLAsset {
    headers.isEmpty ? AVURLAsset(url: url) : AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
  }

  private func startTrailerWatchdog() {
    trailerWatchdog?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.trailerFailed() }
    trailerWatchdog = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
  }

  /// The trailer won't open or start: Dart loads the next way to get it, or closes the player.
  private func trailerFailed() {
    trailerWatchdog?.cancel()
    trailerWatchdog = nil
    guard !closed else { return }
    joinToken = nil
    player.replaceCurrentItem(with: nil)
    spinner.startAnimating()
    send("failed", ["message": "trailer"])
  }

  /// One item from a picture-only file and a sound-only file, played together.
  private static func joined(video: URL, audio: URL, headers: [String: String]) async throws -> AVPlayerItem {
    let v = asset(video, headers)
    let a = asset(audio, headers)
    async let vTracks = v.loadTracks(withMediaType: .video)
    async let aTracks = a.loadTracks(withMediaType: .audio)
    async let vLength = v.load(.duration)
    async let aLength = a.load(.duration)
    let (pictures, sounds, vd, ad) = try await (vTracks, aTracks, vLength, aLength)
    guard let picture = pictures.first, let sound = sounds.first else { throw URLError(.cannotDecodeContentData) }
    let length = CMTimeMinimum(vd, ad)
    let range = CMTimeRange(start: .zero, duration: length)
    let mix = AVMutableComposition()
    try mix.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
      .insertTimeRange(range, of: picture, at: .zero)
    try mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
      .insertTimeRange(range, of: sound, at: .zero)
    return AVPlayerItem(asset: mix)
  }

  private func play(_ item: AVPlayerItem, _ args: [String: Any]) {
    item.externalMetadata = metadata()
    addArtwork(to: item)
    let start = args["start"] as? Double ?? 0
    pendingSeek = start > 1 ? start : nil
    // A trailer plays its own soundtrack, not one of YouTube's machine dubs.
    let language = args["isTrailer"] as? Bool == true ? args["audioLanguage"] as? String : nil
    player.setMediaSelectionCriteria(
      language.map { AVPlayerMediaSelectionCriteria(preferredLanguages: [$0], preferredMediaCharacteristics: nil) },
      forMediaCharacteristic: .audible)
    statusObservation = item.observe(\.status, options: [.new]) { [weak self] it, _ in
      DispatchQueue.main.async { self?.statusChanged(it) }
    }
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) {
      [weak self] _ in self?.ended()
    }
    if #available(tvOS 16.0, *) {
      if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
      selectionObserver = NotificationCenter.default.addObserver(
        forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
      ) { [weak self] _ in
        // Audio or subtitles changed in the player's own menu.
        guard let self, Date() > self.ownChangeUntil else { return }
        self.noteInteraction()
      }
    }
    lastTick = nil
    player.replaceCurrentItem(with: item)
    player.play()
  }

  private func metadata() -> [AVMetadataItem] {
    func item(_ id: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
      guard let value, !value.isEmpty else { return nil }
      let m = AVMutableMetadataItem()
      m.identifier = id
      m.value = value as NSString
      m.extendedLanguageTag = "und"
      return m
    }
    let list = [
      item(.commonIdentifierTitle, opts["title"] as? String),
      item(.iTunesMetadataTrackSubTitle, opts["subtitle"] as? String),
      item(.commonIdentifierDescription, opts["overview"] as? String),
    ].compactMap { $0 }
    return list
  }

  /// The title's artwork for the Info panel, downloaded in the background.
  private func addArtwork(to item: AVPlayerItem) {
    guard let art = opts["artwork"] as? String, let url = URL(string: art) else { return }
    URLSession.shared.dataTask(with: url) { data, _, _ in
      guard let data, !data.isEmpty else { return }
      DispatchQueue.main.async {
        let m = AVMutableMetadataItem()
        m.identifier = .commonIdentifierArtwork
        m.value = data as NSData
        m.dataType = kCMMetadataBaseDataType_JPEG as String
        m.extendedLanguageTag = "und"
        item.externalMetadata.append(m)
      }
    }.resume()
  }

  private func statusChanged(_ it: AVPlayerItem) {
    guard it === player.currentItem else { return }
    switch it.status {
    case .readyToPlay:
      spinner.stopAnimating()
      if let s = pendingSeek {
        pendingSeek = nil
        seek(to: s)
      }
      if opts["showSubtitles"] as? Bool == true { selectServerSubtitles(it) }
    case .failed where opts["isTrailer"] as? Bool == true:
      trailerFailed()
    case .failed:
      spinner.stopAnimating()
      let message = it.error?.localizedDescription ?? "This video couldn't be played."
      send("failed", ["message": message])
      showError(message)
    default:
      break
    }
  }

  /// Subtitles the server added to its stream: switch them on.
  private func selectServerSubtitles(_ it: AVPlayerItem) {
    Task { @MainActor in
      guard let group = try? await it.asset.loadMediaSelectionGroup(for: .legible) else { return }
      let options = group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
      guard let first = options.first ?? group.options.first else { return }
      self.ownChangeUntil = Date().addingTimeInterval(3)
      it.select(first, in: group)
    }
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

  private var isTrailer: Bool { opts["isTrailer"] as? Bool ?? false }
  private var hasNext: Bool { opts["hasNext"] as? Bool ?? false }

  private func observePlayer() {
    if timeObserver == nil {
      timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) {
        [weak self] _ in self?.tick()
      }
    }
    pauseObservation = player.observe(\.timeControlStatus, options: [.old, .new]) { [weak self] p, change in
      DispatchQueue.main.async {
        guard let self, !self.asking, p.currentItem?.status == .readyToPlay else { return }
        // Paused or resumed by the viewer (not the player waiting for data).
        if change.oldValue == .playing && change.newValue == .paused && self.duration - self.position > 2 {
          self.noteInteraction()
          self.report(paused: true)
        } else if change.oldValue == .paused && change.newValue == .playing {
          self.noteInteraction()
          self.report(paused: false)
        }
      }
    }
  }

  private func tick() {
    guard !closed, player.currentItem?.status == .readyToPlay else { return }
    let pos = position
    // The trailer is really playing: no need to watch for it starting any more.
    if pos > 0.5, let dog = trailerWatchdog {
      dog.cancel()
      trailerWatchdog = nil
    }

    // A jump the player didn't make itself means the viewer scrubbed or skipped.
    if let last = lastTick, Date() > ownSeekUntil {
      let expected = last.position + Date().timeIntervalSince(last.at) * Double(player.rate)
      if abs(pos - expected) > 4 { noteInteraction() }
    }
    lastTick = (pos, Date())

    guard !isTrailer else { return }
    var actions: [UIAction] = []

    // Skip Intro / Skip Recap, bottom right, like the big streaming apps.
    if let intro = segments.first(where: { ($0.type == "Intro" || $0.type == "Recap") && pos >= $0.start && pos < $0.end - 1 }) {
      if opts["autoSkipIntro"] as? Bool == true, !autoSkipped.contains(intro.start) {
        autoSkipped.insert(intro.start)
        seek(to: intro.end)
      } else {
        actions.append(UIAction(title: intro.type == "Recap" ? "Skip Recap" : "Skip Intro",
                                image: UIImage(systemName: "forward.end.fill")) { [weak self] _ in
          self?.noteInteraction()
          self?.seek(to: intro.end)
        })
      }
    }

    // Next Episode once the credits start (or in the last 25 seconds).
    if hasNext, !creditsDismissed, duration > 0, inCredits(pos) {
      if countdown == nil, opts["autoplayNext"] as? Bool ?? true { startCountdown() }
      let label = countdown.map { "Next Episode in \($0)" } ?? "Next Episode"
      actions.append(UIAction(title: label, image: UIImage(systemName: "forward.fill")) { [weak self] _ in
        self?.noteInteraction()
        self?.goNext(automatic: false)
      })
      if countdown != nil {
        actions.append(UIAction(title: "Watch Credits") { [weak self] _ in
          guard let self else { return }
          self.noteInteraction()
          self.creditsDismissed = true
          self.cancelCountdown()
          self.controller?.contextualActions = []
        })
      }
    } else if !inCredits(pos) {
      creditsDismissed = false
    }
    if controller?.contextualActions.map(\.title) != actions.map(\.title) { controller?.contextualActions = actions }

    if Date().timeIntervalSince(lastReport) >= 10 { report(paused: player.timeControlStatus == .paused) }
  }

  private func report(paused: Bool) {
    guard !isTrailer else { return }
    lastReport = Date()
    send("progress", ["position": position, "paused": paused])
  }

  private func inCredits(_ pos: Double) -> Bool {
    if let outro = segments.first(where: { $0.type == "Outro" }) { return pos >= outro.start }
    return duration - pos <= 25
  }

  private func seek(to seconds: Double) {
    ownSeekUntil = Date().addingTimeInterval(3)
    player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
  }

  private func startCountdown() {
    countdown = 10
    countdownTimer?.invalidate()
    countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
      guard let self, let c = self.countdown else {
        t.invalidate()
        return
      }
      if c <= 1 {
        t.invalidate()
        self.goNext(automatic: true)
      } else {
        self.countdown = c - 1
        self.tick()
      }
    }
  }

  private func cancelCountdown() {
    countdownTimer?.invalidate()
    countdownTimer = nil
    countdown = nil
  }

  private func ended() {
    if hasNext, opts["autoplayNext"] as? Bool ?? true, !creditsDismissed {
      goNext(automatic: true)
    } else {
      finish(dismiss: true)
    }
  }

  /// Moves on to the next episode, first asking "Are you still watching?" when that many
  /// episodes have played one after another without anyone touching the remote.
  private func goNext(automatic: Bool) {
    guard hasNext, !asking else { return }
    cancelCountdown()
    controller?.contextualActions = []
    if automatic {
      unattended = interacted ? 0 : unattended + 1
      let enabled = opts["stillWatching"] as? Bool ?? true
      let after = max(1, opts["stillWatchingAfter"] as? Int ?? 3)
      if enabled && unattended >= after {
        askStillWatching()
        return
      }
    } else {
      unattended = 0
    }
    requestNext()
  }

  private func requestNext() {
    spinner.startAnimating()
    send("next", ["position": position])
  }

  private func askStillWatching() {
    guard let vc = controller else { return }
    asking = true
    player.pause()
    let show = opts["seriesName"] as? String
    let alert = UIAlertController(
      title: "Are you still watching?",
      message: show.map { "The next episode of \($0) is ready." },
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Continue Watching", style: .default) { [weak self] _ in
      guard let self else { return }
      self.asking = false
      self.unattended = 0
      self.requestNext()
    })
    alert.addAction(UIAlertAction(title: "Back to Ember", style: .cancel) { [weak self] _ in
      self?.asking = false
      self?.finish(dismiss: true)
    })
    vc.present(alert, animated: true)
  }

  // MARK: The viewer is here

  /// Any press or swipe on the Siri Remote while the player is up. The recognisers only watch:
  /// the player still gets every press as usual.
  private func watchRemote(on view: UIView) {
    let presses: [UIPress.PressType] = [.select, .playPause, .upArrow, .downArrow, .leftArrow, .rightArrow]
    for type in presses {
      let tap = UITapGestureRecognizer(target: self, action: #selector(remoteUsed))
      tap.allowedPressTypes = [NSNumber(value: type.rawValue)]
      tap.cancelsTouchesInView = false
      tap.delaysTouchesBegan = false
      tap.delegate = self
      view.addGestureRecognizer(tap)
    }
    let swipe = UIPanGestureRecognizer(target: self, action: #selector(remoteUsed))
    swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
    swipe.cancelsTouchesInView = false
    swipe.delegate = self
    view.addGestureRecognizer(swipe)
  }

  @objc private func remoteUsed() { noteInteraction() }

  func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

  private func noteInteraction() {
    interacted = true
    unattended = 0
  }

  // MARK: Audio and subtitles

  /// Audio and subtitle choices from the server's list of streams. Picking one asks Dart to
  /// reopen the stream with it (the server repackages it), at the same point.
  private func updateMenus() {
    guard let vc = controller, !isTrailer else {
      controller?.transportBarCustomMenuItems = []
      return
    }
    var menus: [UIMenuElement] = []
    let audio = opts["audio"] as? [[String: Any]] ?? []
    if opts["serverTracks"] as? Bool == true, audio.count > 1 {
      menus.append(UIMenu(title: "Audio", image: UIImage(systemName: "speaker.wave.2"), children: audio.map { t in
        UIAction(title: t["label"] as? String ?? "Track", state: t["selected"] as? Bool == true ? .on : .off) { [weak self] _ in
          self?.pickTrack("audio", t["index"] as? Int ?? -1)
        }
      }))
    }
    let subs = opts["subtitles"] as? [[String: Any]] ?? []
    if !subs.isEmpty {
      let anyOn = subs.contains { $0["selected"] as? Bool == true }
      var children: [UIMenuElement] = [UIAction(title: "Off", state: anyOn ? .off : .on) { [weak self] _ in
        self?.pickTrack("subtitle", -1)
      }]
      children += subs.map { t in
        UIAction(title: t["label"] as? String ?? "Subtitles", state: t["selected"] as? Bool == true ? .on : .off) { [weak self] _ in
          self?.pickTrack("subtitle", t["index"] as? Int ?? -1)
        }
      }
      menus.append(UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), children: children))
    }
    vc.transportBarCustomMenuItems = menus
  }

  private func pickTrack(_ kind: String, _ index: Int) {
    noteInteraction()
    spinner.startAnimating()
    send("track", ["kind": kind, "index": index, "position": position])
  }

  // MARK: Ending

  private func showError(_ message: String) {
    spinner.stopAnimating()
    guard let vc = controller else { return }
    let alert = UIAlertController(title: "Can't play this", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.finish(dismiss: true) })
    vc.present(alert, animated: true)
  }

  func playerViewControllerDidEndDismissalTransition(_ playerViewController: AVPlayerViewController) {
    if playerViewController === controller { finish(dismiss: false) }
  }

  private func finish(dismiss: Bool) {
    guard !closed else { return }
    closed = true
    trailerWatchdog?.cancel()
    trailerWatchdog = nil
    cancelCountdown()
    asking = false
    let pos = position
    let atEnd = duration > 0 && duration - pos < 2
    player.pause()
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    timeObserver = nil
    pauseObservation = nil
    statusObservation = nil
    for o in [endObserver, selectionObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(o) }
    endObserver = nil
    selectionObserver = nil
    spinner.stopAnimating()
    spinner.removeFromSuperview()
    let vc = controller
    controller = nil
    if dismiss { vc?.presentingViewController?.dismiss(animated: true) }
    player.replaceCurrentItem(with: nil)
    send("closed", ["position": pos, "finished": atEnd])
  }

  private func topViewController() -> UIViewController? {
    let window = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }
      .first
    var top = window?.rootViewController
    while let next = top?.presentedViewController { top = next }
    return top
  }
}
