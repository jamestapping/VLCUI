#if os(macOS)
import AppKit
#else
import UIKit
#endif

import VLCKit

extension VLCMediaPlayer {

    func setSubtitleSize(_ size: VLCVideoPlayer.ValueSelector<Int>) {
        let value: Int?

        switch size {
        case .auto:
            value = nil
        case let .absolute(size):
            value = size
        }

        #if !os(macOS)
        perform(
            Selector(("setTextRendererFontSize:")),
            with: value
        )
        #endif
    }

    func setSubtitleFont(_ font: VLCVideoPlayer.ValueSelector<_PlatformFont>) {
        switch font {
        case .auto:
            setSubtitleFont(_PlatformFont.defaultSubtitleFont.fontName)
        case let .absolute(font):
            setSubtitleFont(font.fontName)
        }
    }

    func setSubtitleFont(_ fontName: String) {
        #if !os(macOS)
        perform(
            Selector(("setTextRendererFont:")),
            with: fontName
        )
        #endif
    }

    func setSubtitleColor(_ color: VLCVideoPlayer.ValueSelector<_PlatformColor>) {
        let value: UInt

        switch color {
        case .auto:
            value = _PlatformColor.white.hex
        case let .absolute(fontColor):
            value = fontColor.hex
        }

        #if !os(macOS)
        perform(
            Selector(("setTextRendererFontColor:")),
            with: value
        )
        #endif
    }

    // VLCKit 4.0 replaced the old `videoSubTitlesIndexes`/`audioTrackIndexes`
    // (raw libvlc index arrays, with a literal -1 entry meaning "disabled")
    // and `currentVideoSubTitleIndex`/`currentAudioTrackIndex` setters with
    // `textTracks`/`audioTracks` (arrays of VLCMediaPlayerTrack) plus
    // `-selectTrackAtIndex:type:`/`-deselectAllTextTracks`/
    // `-deselectAllAudioTracks`. VLCUI's own public API (MediaTrack.index,
    // ValueSelector<Int>) still models a track purely as a position in that
    // array — -1 keeps meaning "disabled", now by position lookup against
    // the real array rather than a sentinel value embedded inside it.
    func subtitleTrackIndex(from track: VLCVideoPlayer.ValueSelector<Int>) -> Int {
        let count = textTracks.count
        switch track {
        case .auto:
            return count > 0 ? 0 : -1
        case let .absolute(index):
            return (0 ..< count).contains(index) ? index : -1
        }
    }

    func audioTrackIndex(from track: VLCVideoPlayer.ValueSelector<Int>) -> Int {
        let count = audioTracks.count
        switch track {
        case .auto:
            return count > 0 ? 0 : -1
        case let .absolute(index):
            return (0 ..< count).contains(index) ? index : -1
        }
    }

    /// Replaces the old `currentVideoSubTitleIndex = ...` setter. `index`
    /// is a position in `textTracks` as returned by `subtitleTrackIndex(from:)`
    /// above — -1 (or any out-of-range value) means "no subtitles",
    /// matching the old sentinel's meaning.
    func selectSubtitleTrackIndex(_ index: Int) {
        guard (0 ..< textTracks.count).contains(index) else {
            deselectAllTextTracks()
            return
        }
        selectTrackAtIndex(index, type: .text)
    }

    /// Replaces the old `currentAudioTrackIndex = ...` setter — see
    /// `selectSubtitleTrackIndex` above, same reasoning for audio.
    func selectAudioTrackIndex(_ index: Int) {
        guard (0 ..< audioTracks.count).contains(index) else {
            deselectAllAudioTracks()
            return
        }
        selectTrackAtIndex(index, type: .audio)
    }

    /// Replaces reading `currentVideoSubTitleIndex`/`currentAudioTrackIndex`
    /// directly — the position of whichever track in `textTracks`/
    /// `audioTracks` currently has `isSelected == true`, or -1 if none does.
    var currentSubtitleTrackIndex: Int {
        textTracks.firstIndex(where: \.isSelected) ?? -1
    }

    var currentAudioTrackIndex: Int {
        audioTracks.firstIndex(where: \.isSelected) ?? -1
    }

    var currentVideoTrackIndex: Int {
        videoTracks.firstIndex(where: \.isSelected) ?? -1
    }

    func rate(from rate: VLCVideoPlayer.ValueSelector<Float>) -> Float {
        switch rate {
        case .auto:
            return 1
        case let .absolute(speed):
            return speed
        }
    }
}
