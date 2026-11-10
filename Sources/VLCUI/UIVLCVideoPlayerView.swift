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
// `.drawable` — the same object that's always been responsible for
// `addSubview:`/`bounds` (VLCDrawable). Rather than route PiP through
// `UIVLCVideoPlayerView` itself, this stays on `videoContentView` (now this
// dedicated subclass instead of a plain `_PlatformView`): that's already the
// exact view VLCKit draws its real rendering content into today, with the
// aspect-fill transform logic in this file already keyed to it specifically.
// Keeping `.drawable` pointed at the same object PiP is also implemented on
// means zero behavior change to existing rendering for players that never
// touch PiP.
private final class VLCDrawableContentView: _PlatformView, VLCDrawable, VLCPictureInPictureDrawable, VLCPictureInPictureMediaControlling {
    weak var owner: UIVLCVideoPlayerView?

    func mediaController() -> VLCPictureInPictureMediaControlling {
        self
    }

    func pictureInPictureReady() -> (VLCPictureInPictureWindowControlling) -> Void {
        { [weak self] controller in
            self?.owner?.handlePictureInPictureReady(controller)
        }
    }

    func play() {
        owner?.currentMediaPlayer?.play()
    }

    func pause() {
        owner?.currentMediaPlayer?.pause()
    }

    func seekBy(_ offset: Int64, completion: @escaping () -> Void) {
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

    private var configuration: VLCVideoPlayer.Configuration
    private var proxy: VLCVideoPlayer.Proxy?
    private let onTicksUpdated: (Int, VLCVideoPlayer.PlaybackInformation) -> Void
    private let onStateUpdated: (VLCVideoPlayer.State, VLCVideoPlayer.PlaybackInformation) -> Void
    private let loggingInfo: (logger: VLCVideoPlayerLogger, level: VLCVideoPlayer.LoggingLevel)?
    private var currentMediaPlayer: VLCMediaPlayer?

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

        let media = VLCMedia(url: newConfiguration.url)
        media.addOptions(newConfiguration.options)

        let newMediaPlayer = VLCMediaPlayer()
        newMediaPlayer.media = media
        newMediaPlayer.drawable = videoContentView
        newMediaPlayer.delegate = self

        if let loggingInfo {
            newMediaPlayer.libraryInstance.debugLogging = true
            newMediaPlayer.libraryInstance.debugLoggingLevel = loggingInfo.level.rawValue.asInt32
            newMediaPlayer.libraryInstance.debugLoggingTarget = self
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
        #if os(macOS)
        let view = _PlatformView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer?.backgroundColor = .black
        return view
        #else
        let view = VLCDrawableContentView(frame: .zero)
        view.owner = self
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .black
        return view
        #endif
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

        let subtitleIndexes = player.videoSubTitlesIndexes as! [Int]
        let subtitleNames = player.videoSubTitlesNames as! [String]

        let audioIndexes = player.audioTrackIndexes as! [Int]
        let audioNames = player.audioTrackNames as! [String]

        let videoIndexes = player.videoTrackIndexes as! [Int]
        let videoNames = player.videoTrackNames as? [String]

        let subtitleTracks = zip(subtitleIndexes, subtitleNames).map { MediaTrack(index: $0, title: $1) }
        let audioTracks = zip(audioIndexes, audioNames).map { MediaTrack(index: $0, title: $1) }
        let videoTracks = zip(videoIndexes, videoNames ?? []).map { MediaTrack(index: $0, title: $1) }

        let currentSubtitleTrack: MediaTrack = subtitleTracks
            .first(where: { $0.index == player.currentVideoSubTitleIndex.asInt })
            .chaining(.init(index: -1, title: "Disable"))
        let currentAudioTrack: MediaTrack = audioTracks
            .first(where: { $0.index == player.currentAudioTrackIndex.asInt })
            .chaining(.init(index: -1, title: "Disable"))
        let currentVideoTrack: MediaTrack = videoTracks
            .first(where: { $0.index == player.currentVideoTrackIndex.asInt })
            .chaining(.init(index: -1, title: "Disable"))

        return VLCVideoPlayer.PlaybackInformation(
            startConfiguration: configuration,
            position: player.position,
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
}

// MARK: VLCMediaPlayerDelegate

extension UIVLCVideoPlayerView: VLCMediaPlayerDelegate {

    public func mediaPlayerTimeChanged(_ aNotification: Notification) {
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
        let player = aNotification.object as! VLCMediaPlayer
        guard player.state != .playing, player.state != lastPlayerState else { return }

        let wrappedState = VLCVideoPlayer.State(rawValue: player.state.rawValue) ?? .error
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
        player.currentVideoSubTitleIndex = defaultSubtitleTrackIndex.asInt32

        let defaultAudioTrackIndex = player.audioTrackIndex(from: configuration.audioIndex)
        player.currentAudioTrackIndex = defaultAudioTrackIndex.asInt32

        player.setSubtitleSize(configuration.subtitleSize)
        player.setSubtitleFont(configuration.subtitleFont)
        player.setSubtitleColor(configuration.subtitleColor)
    }
}

// MARK: VLCLibraryLogReceiverProtocol

extension UIVLCVideoPlayerView: VLCLibraryLogReceiverProtocol {

    public func handleMessage(_ message: String, debugLevel level: Int32) {
        guard let loggingInfo, level >= loggingInfo.level.rawValue else { return }
        let level = VLCVideoPlayer.LoggingLevel(rawValue: level.asInt) ?? .info
        loggingInfo.logger.vlcVideoPlayer(didLog: message, at: level)
    }
}
