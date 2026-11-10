import VLCKit

public extension VLCVideoPlayer {

    enum State: Int {
        case stopped
        case opening
        case buffering
        case ended
        case error
        case playing
        case paused
        case esAdded

        // VLCKit 4.0's VLCMediaPlayerState has a different case count and
        // order than this enum's own raw values were built against
        // (nothingSpecial, opening, playing, paused, stopped, stopping,
        // error — 7 cases, no buffering/ended/esAdded, new stopping; the
        // old enum this matched had 8, in a different order). Casting by
        // raw value, as this used to, would silently map to the *wrong*
        // case for several real states (e.g. 4.0's .playing, raw 2, would
        // land on .buffering here, raw 2) — map explicitly by name instead.
        // buffering/ended/esAdded have no equivalent in the new enum at
        // all (buffering progress is now its own delegate callback,
        // mediaPlayerBufferingChanged:, not a discrete state) and are kept
        // here only so this doesn't become a source-breaking API change
        // for anything else matching on them.
        init(_ state: VLCMediaPlayerState) {
            switch state {
            case .nothingSpecial, .stopped, .stopping:
                self = .stopped
            case .opening:
                self = .opening
            case .playing:
                self = .playing
            case .paused:
                self = .paused
            case .error:
                self = .error
            @unknown default:
                self = .error
            }
        }
    }
}
