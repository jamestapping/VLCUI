import Combine

#if os(macOS)
import AppKit
#else
import UIKit
#endif

import VLCKit

#if !os(macOS)
// VLCKit 4.0's native Picture in Picture (landed in 4.0.0a8, see VLCDrawable.h)
// calls back onto whatever object is assigned as the media player's
// `.drawable`. That can't be `videoContentView` itself (a UIView): the
// protocol's `bounds()` requirement is a plain Objective-C method, which
// collides outright with UIView's own inherited `bounds` *property* getter
// — same selector, so Swift refuses to let a UIView subclass declare one
// ("method 'bounds()' ... conflicts with getter for 'bounds' from
// superclass 'UIView'"), while *not* declaring one leaves the protocol
// unsatisfied ("does not conform"). A plain NSObject adapter has no such
// inherited property to collide with, and just forwards both
// `addSubview:`/`bounds()` to the real view (`videoContentView`, still the
// exact view VLCKit draws its rendering content into and that the existing
// aspect-fill logic is keyed to — unchanged) and the playback-control calls
// to `owner`'s `currentMediaPlayer`.
private final class VLCDrawableAdapter: NSObject, VLCDrawable, VLCPictureInPictureDrawable, VLCPictureInPictureMediaControlling {
    weak var owner: UIVLCVideoPlayerView?
    weak var contentView: _PlatformView?

    // `VLCView` in the header is a C macro (`#define VLCView UIView`/`NSView`)
    // invisible to Swift — the generated interface sees the expanded type,
    // `_PlatformView` here.
    func addSubview(_ view: _PlatformView) {
        contentView?.addSubview(view)
    }

    func bounds() -> CGRect {
        contentView?.bounds ?? .zero
    }

    func mediaController() -> VLCPictureInPictureMediaControlling {
        self
    }

    func pictureInPictureReady() -> ((VLCPictureInPictureWindowControlling?) -> Void)? {
        { [weak self] controller in
            guard let controller else { return }
            self?.owner?.handlePictureInPictureReady(controller)
        }
    }

    func play() {
        owner?.currentMediaPlayer?.play()
    }

    func pause() {
        owner?.currentMediaPlayer?.pause()
    }

    func seek(by offset: Int64, completion: @escaping () -> Void) {
        guard let player = owner?.currentMediaPlayer else {
            completion()
            return
        }
        player.time = VLCTime(int: player.time.intValue + Int32(offset))
        completion()
    }

    func mediaLength() -> Int64 {
        Int64(owner?.currentMediaPlayer?.media?.length.intValue ?? 0)
    }

    func mediaTime() -> Int64 {
        Int64(owner?.currentMediaPlayer?.time.intValue ?? 0)
    }

    func isMediaSeekable() -> Bool {
        owner?.currentMediaPlayer?.isSeekable ?? false
    }

    func isMediaPlaying() -> Bool {
        owner?.currentMediaPlayer?.isPlaying ?? false
    }
}
#endif

public class UIVLCVideoPlayerView: _PlatformView {

    private lazy var videoContentView = makeVideoContentView()
    #if !os(macOS)
    private lazy var drawableAdapter: VLCDrawableAdapter = {
        let adapter = VLCDrawableAdapter()
        adapter.owner = self
        adapter.contentView = videoContentView
        return adapter
    }()
    #endif

    private var configuration: VLCVideoPlayer.Configuration
    private var proxy: VLCVideoPlayer.Proxy?
    private let onTicksUpdated: (Int, VLCVideoPlayer.PlaybackInformation) -> Void
    private let onStateUpdated: (VLCVideoPlayer.State, VLCVideoPlayer.PlaybackInformation) -> Void
    private let loggingInfo: (logger: VLCVideoPlayerLogger, level: VLCVideoPlayer.LoggingLevel)?
    // fileprivate, not private: VLCDrawableAdapter (top-level in this same
    // file, not nested) forwards its playback-control calls to this.
    fileprivate var currentMediaPlayer: VLCMediaPlayer?

    // Note: necessary as the configuration values have to be set
    //       after streams have been added and playback starts for
    //       at least one tick-changed report. This could cause a
    //       small, noticeable jump when playback starts.
    private var hasSetConfiguration: Bool = false
    private var lastAspectFill: Float = 0
    private var lastPlayerTicks: Int32 = 0
    private var lastPlayerState: VLCMediaPlayerState = .opening

    private var aspectFillScale: CGFloat {
        guard let currentMediaPlayer else { return 1 }
        let videoSize = currentMediaPlayer.videoSize
        let fillSize = CGSize.aspectFill(aspectRatio: videoSize, minimumSize: videoContentView.bounds.size)
        return fillSize.scale(other: videoContentView.bounds.size)
    }

    init(
        configuration: VLCVideoPlayer.Configuration,
        proxy: VLCVideoPlayer.Proxy?,
        onTicksUpdated: @escaping (Int, VLCVideoPlayer.PlaybackInformation) -> Void,
        onStateUpdated: @escaping (VLCVideoPlayer.State, VLCVideoPlayer.PlaybackInformation) -> Void,
        loggingInfo: (VLCVideoPlayerLogger, VLCVideoPlayer.LoggingLevel)?
    ) {
        self.configuration = configuration
        self.proxy = proxy
        self.onTicksUpdated = onTicksUpdated
        self.onStateUpdated = onStateUpdated
        self.loggingInfo = loggingInfo
        super.init(frame: .zero)

        proxy?.videoPlayerView = self

        #if os(macOS)
        layer?.backgroundColor = .clear
        #else
        backgroundColor = .clear
        #endif

        setupVideoContentView()
        setupVLCMediaPlayer(with: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupVideoContentView() {
        addSubview(videoContentView)

        NSLayoutConstraint.activate([
            videoContentView.topAnchor.constraint(equalTo: topAnchor),
            videoContentView.bottomAnchor.constraint(equalTo: bottomAnchor),
            videoContentView.leftAnchor.constraint(equalTo: leftAnchor),
            videoContentView.rightAnchor.constraint(equalTo: rightAnchor),
        ])
    }

    deinit {
        // Releasing the last strong reference to a VLCMediaPlayer synchronously
        // triggers -[VLCMediaPlayer dealloc] -> libvlc_media_player_destroy(),
        // which does a pthread_join waiting for libvlc's internal thread to exit.
        // If that thread is stuck on a stalled network read (e.g. the connection
        // went dead mid-stream), the join can block for a very long time. Since
        // this view's deinit normally runs synchronously on the main thread (as
        // part of SwiftUI/UIKit tearing the view down), that would freeze the
        // whole app. Handing the reference to a detached task defers the actual
        // release to a background thread instead.
        let playerToRelease = currentMediaPlayer
        Task.detached(priority: .userInitiated) {
            playerToRelease?.stop()
        }
    }

    func setupVLCMediaPlayer(with newConfiguration: VLCVideoPlayer.Configuration) {
        // Same reasoning as deinit above: don't let releasing the previous
        // player block this (main-thread) call if its network connection is
        // stalled — hand it off to release in the background instead.
        if let oldMediaPlayer = currentMediaPlayer {
            currentMediaPlayer = nil
            Task.detached(priority: .userInitiated) {
                oldMediaPlayer.stop()
            }
        }

        // The controller VLCKit handed back via `pictureInPictureReady` is
        // tied to the old `VLCMediaPlayer`/drawable pairing above — it does
        // not carry over. `pictureInPictureReady` fires again, with a fresh
        // controller, once the new player is ready for it.
        #if !os(macOS)
        proxy?.pictureInPictureController = nil
        #endif

        // VLCKit 4.0 made this initializer failable (`init?`); force-unwrap
        // since this function has no way to report failure to its caller
        // and a well-formed URL has never actually failed to construct a
        // VLCMedia in practice here.
        let media = VLCMedia(url: newConfiguration.url)!
        media.addOptions(newConfiguration.options)

        let newMediaPlayer = VLCMediaPlayer()
        newMediaPlayer.media = media
        #if os(macOS)
        newMediaPlayer.drawable = videoContentView
        #else
        newMediaPlayer.drawable = drawableAdapter
        #endif
        newMediaPlayer.delegate = self

        if let loggingInfo {
            // VLCKit 4.0 replaced the old debugLogging/debugLoggingLevel/
            // debugLoggingTarget trio (and the VLCLibraryLogReceiverProtocol
            // delegate it called back on) with a `loggers` array of
            // VLCLogging-conforming objects — VLCLogBridge below is that
            // object, forwarding to the exact same `loggingInfo.logger`
            // callback this always used.
            newMediaPlayer.libraryInstance.loggers = [VLCLogBridge(loggingInfo: loggingInfo)]
        }

        for child in newConfiguration.playbackChildren {
            newMediaPlayer.addPlaybackSlave(child.url, type: child.type.asVLCSlaveType, enforce: child.enforce)
        }

        hasSetConfiguration = false
        configuration = newConfiguration
        currentMediaPlayer = newMediaPlayer
        proxy?.mediaPlayer = newMediaPlayer
        lastPlayerTicks = 0
        lastPlayerState = .opening

        if newConfiguration.autoPlay {
            newMediaPlayer.play()
        }
    }

    func setAspectFill(with percentage: Float) {
        guard percentage >= 0, percentage <= 1 else { return }
        let scale = 1 + CGFloat(percentage) * (aspectFillScale - 1)
        videoContentView.scale(x: scale, y: scale)

        lastAspectFill = percentage
    }

    private func makeVideoContentView() -> _PlatformView {
        let view = _PlatformView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false

        #if os(macOS)
        view.layer?.backgroundColor = .black
        #else
        view.backgroundColor = .black
        #endif
        return view
    }

    #if !os(macOS)
    /// Called (by VLCKit, via `VLCDrawableContentView.pictureInPictureReady()`)
    /// exactly once PiP is actually usable for the current media player —
    /// not at `init`, since VLCKit needs to have set up its own PiP-capable
    /// rendering path first. Surfaced through `Proxy` rather than kept
    /// private here, since starting/stopping PiP is something the app's own
    /// UI (a PiP button, or a background-transition hook) needs to trigger.
    fileprivate func handlePictureInPictureReady(_ controller: VLCPictureInPictureWindowControlling) {
        proxy?.pictureInPictureController = controller
    }
    #endif

    #if !os(macOS)
    override public func layoutSubviews() {
        super.layoutSubviews()

        setAspectFill(with: lastAspectFill)
    }
    #endif
}

// MARK: constructPlaybackInformation

extension UIVLCVideoPlayerView {

    private func constructPlaybackInformation(player: VLCMediaPlayer, media: VLCMedia) -> VLCVideoPlayer.PlaybackInformation {

        // VLCKit 4.0's textTracks/audioTracks/videoTracks (VLCMediaPlayerTrack
        // objects) replace the old parallel videoSubTitlesIndexes/Names etc.
        // arrays — see VLCMediaPlayerExtensions.swift's comment on
        // subtitleTrackIndex(from:) for the full picture. MediaTrack.index
        // stays a position in these arrays, same convention as before.
        //
        // VLCKit 3.6's index arrays carried a literal -1 "disabled" member,
        // so an "Off" row came for free wherever the UI listed them.
        // VLCKit 4.0's track arrays only ever contain real tracks, so that
        // row has to be synthesized here — prepended, not appended, so it's
        // always the first/default-looking option regardless of how many
        // real tracks exist. selectSubtitleTrackIndex(-1)/selectAudioTrackIndex(-1)
        // already map this same sentinel to deselectAllTextTracks()/
        // deselectAllAudioTracks() correctly; this was purely a missing
        // list row, not a broken selector.
        let subtitleTracks = [MediaTrack(index: -1, title: "Off")]
            + player.textTracks.enumerated().map { MediaTrack(index: $0.offset, title: $0.element.trackName) }
        let audioTracks = [MediaTrack(index: -1, title: "Off")]
            + player.audioTracks.enumerated().map { MediaTrack(index: $0.offset, title: $0.element.trackName) }
        let videoTracks = [MediaTrack(index: -1, title: "Off")]
            + player.videoTracks.enumerated().map { MediaTrack(index: $0.offset, title: $0.element.trackName) }

        // Subtitles genuinely default to off (PlaybackManager explicitly
        // forces this), so trusting currentSubtitleTrackIndex == -1 as
        // "Off" is correct even when VLCKit never marks any text track
        // isSelected. Audio/video have no such override — VLCKit's own
        // .auto default plays the first real track without ever marking
        // it isSelected either, so currentAudioTrackIndex/
        // currentVideoTrackIndex == -1 there means "nothing explicit was
        // chosen", not "off". Showing the "Off" row checked in that case
        // would be wrong — audio is audibly playing — so fall back to the
        // first real track instead, matching audioTrackIndex(from: .auto)/
        // subtitleTrackIndex(from: .auto)'s own "first track" semantics.
        let currentSubtitleTrack: MediaTrack = subtitleTracks
            .first(where: { $0.index == player.currentSubtitleTrackIndex })
            .chaining(.init(index: -1, title: "Off"))
        let currentAudioTrack: MediaTrack = currentTrack(
            in: audioTracks,
            selectedIndex: player.currentAudioTrackIndex
        )
        let currentVideoTrack: MediaTrack = currentTrack(
            in: videoTracks,
            selectedIndex: player.currentVideoTrackIndex
        )

        return VLCVideoPlayer.PlaybackInformation(
            startConfiguration: configuration,
            // VLCKit 4.0 changed `position` from Float to Double;
            // PlaybackInformation.position stays Float, same as before.
            position: Float(player.position),
            length: media.length.intValue.asInt,
            isSeekable: player.isSeekable,
            playbackRate: player.rate,
            videoSize: player.videoSize,
            currentSubtitleTrack: currentSubtitleTrack,
            currentAudioTrack: currentAudioTrack,
            currentVideoTrack: currentVideoTrack,
            subtitleTracks: subtitleTracks,
            audioTracks: audioTracks,
            videoTracks: videoTracks,
            statistics: .init(stats: media.statistics)
        )
    }

    /// For audio/video only (not subtitles, which genuinely default to
    /// off) — treats `selectedIndex == -1` as "nothing explicit chosen
    /// yet" rather than "off", since VLCKit's own .auto default plays the
    /// first real track without ever marking it isSelected. Falls back to
    /// the first real track so the picker's checkmark matches what's
    /// actually audible/visible instead of showing "Off" while it plays.
    private func currentTrack(in tracks: [MediaTrack], selectedIndex: Int) -> MediaTrack {
        if selectedIndex >= 0, let match = tracks.first(where: { $0.index == selectedIndex }) {
            return match
        }
        return tracks.first(where: { $0.index >= 0 }) ?? MediaTrack(index: -1, title: "Off")
    }
}

// MARK: VLCMediaPlayerDelegate

extension UIVLCVideoPlayerView: VLCMediaPlayerDelegate {

    public func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // VLCKit 4.0's stopTimeChangeUpdateTimer() force-fires the pending
        // timer synchronously on whatever thread calls it (its own
        // background input thread included), instead of only ever firing
        // via the main run loop as VLCKit 3.x did. Everything downstream
        // here publishes to SwiftUI/@Published state that assumes main
        // thread, so re-enter on main if we weren't called there.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.mediaPlayerTimeChanged(aNotification)
            }
            return
        }

        let player = aNotification.object as! VLCMediaPlayer
        let currentTicks = player.time.intValue
        let playbackInformation = constructPlaybackInformation(player: player, media: player.media!)

        if !hasSetConfiguration {
            setConfigurationValues(
                with: player,
                from: configuration
            )

            hasSetConfiguration = true
        } else {
            onTicksUpdated(currentTicks.asInt, playbackInformation)
        }

        // Set playing state
        if lastPlayerState != .playing,
           abs(currentTicks - lastPlayerTicks) >= 200
        {
            onStateUpdated(.playing, playbackInformation)
            lastPlayerState = .playing
            lastPlayerTicks = currentTicks
        }

        #if !os(macOS)
        proxy?.invalidatePictureInPicturePlaybackState()
        #endif

        // Replay
        if configuration.replay,
           lastPlayerState == .playing,
           abs(player.media!.length.intValue - currentTicks) <= 500
        {
            configuration.autoPlay = true
            configuration.startTime = .ticks(0)
            setupVLCMediaPlayer(with: configuration)
        }
    }

    public func mediaPlayerStateChanged(_ aNotification: Notification) {
        // Same background-thread risk as mediaPlayerTimeChanged above —
        // VLCKit 4.0 can call this delegate method from its own internal
        // input thread on a state transition, not only from main.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.mediaPlayerStateChanged(aNotification)
            }
            return
        }

        let player = aNotification.object as! VLCMediaPlayer
        guard player.state != .playing, player.state != lastPlayerState else { return }

        let wrappedState = VLCVideoPlayer.State(player.state)
        let playbackInformation = constructPlaybackInformation(player: player, media: player.media!)

        onStateUpdated(wrappedState, playbackInformation)
        lastPlayerState = player.state

        #if !os(macOS)
        proxy?.invalidatePictureInPicturePlaybackState()
        #endif
    }

    private func setConfigurationValues(with player: VLCMediaPlayer, from configuration: VLCVideoPlayer.Configuration) {

        if configuration.startTime.asTicks != 0 {
            player.time = VLCTime(int: configuration.startTime.asTicks.asInt32)
        }

        let defaultPlayerSpeed = player.rate(from: configuration.rate)
        player.fastForward(atRate: defaultPlayerSpeed)

        if configuration.aspectFill {
            videoContentView.scale(x: aspectFillScale, y: aspectFillScale)
        } else {
            videoContentView.apply(transform: .identity)
        }

        let defaultSubtitleTrackIndex = player.subtitleTrackIndex(from: configuration.subtitleIndex)
        player.selectSubtitleTrackIndex(defaultSubtitleTrackIndex)

        let defaultAudioTrackIndex = player.audioTrackIndex(from: configuration.audioIndex)
        player.selectAudioTrackIndex(defaultAudioTrackIndex)

        player.setSubtitleSize(configuration.subtitleSize)
        player.setSubtitleFont(configuration.subtitleFont)
        player.setSubtitleColor(configuration.subtitleColor)
    }
}

// MARK: VLCLogBridge

/// Adapts `VLCVideoPlayer.LoggingLevel`/`VLCVideoPlayerLogger` (VLCUI's own,
/// pre-4.0 logging API, kept unchanged here since this app never actually
/// uses it — grepped: no `.logging(...)` call site anywhere) onto VLCKit
/// 4.0's `VLCLogging` protocol, assigned via `VLCLibrary.loggers` instead of
/// the removed debugLogging/debugLoggingTarget delegate pair.
private final class VLCLogBridge: NSObject, VLCLogging {
    private let loggingInfo: (logger: VLCVideoPlayerLogger, level: VLCVideoPlayer.LoggingLevel)

    init(loggingInfo: (logger: VLCVideoPlayerLogger, level: VLCVideoPlayer.LoggingLevel)) {
        self.loggingInfo = loggingInfo
    }

    var level: VLCLogLevel {
        get { loggingInfo.level.asVLCLogLevel }
        set { /* driven by loggingInfo.level only — VLCKit never needs to change this itself */ }
    }

    func handleMessage(_ message: String, logLevel level: VLCLogLevel, context: VLCLogContext?) {
        loggingInfo.logger.vlcVideoPlayer(didLog: message, at: loggingInfo.level)
    }
}

private extension VLCVideoPlayer.LoggingLevel {
    var asVLCLogLevel: VLCLogLevel {
        switch self {
        case .error: return .error
        case .warning: return .warning
        case .info: return .info
        case .debug: return .debug
        }
    }
}
