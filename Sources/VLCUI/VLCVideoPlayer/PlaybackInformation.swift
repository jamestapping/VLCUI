import Foundation

import VLCKit

public extension VLCVideoPlayer {

    struct PlaybackInformation {
        public let startConfiguration: VLCVideoPlayer.Configuration
        public let position: Float
        public let length: Int
        public let isSeekable: Bool
        public let playbackRate: Float

        public let videoSize: CGSize

        public let currentSubtitleTrack: MediaTrack
        public let currentAudioTrack: MediaTrack
        public let currentVideoTrack: MediaTrack
        public let subtitleTracks: [MediaTrack]
        public let audioTracks: [MediaTrack]
        public let videoTracks: [MediaTrack]

        public let statistics: Statistics
    }

    struct Statistics {
        public let readBytes: Int
        public let inputBitrate: Float
        public let demuxReadBytes: Int
        public let demuxBitrate: Float
        public let demuxCorrupted: Int
        public let demuxDiscontinuity: Int
        public let decodedVideo: Int
        public let decodedAudio: Int
        public let displayedPictures: Int
        public let lostPictures: Int
        public let playedAudioBuffers: Int
        public let lostAudioBuffers: Int
        public let sentPackets: Int
        public let sentBytes: Int
        public let sendBitrate: Float

        public init(stats: VLCMedia.Stats) {
            readBytes = stats.readBytes.asInt
            inputBitrate = stats.inputBitrate
            demuxReadBytes = stats.demuxReadBytes.asInt
            demuxBitrate = stats.demuxBitrate
            demuxCorrupted = stats.demuxCorrupted.asInt
            demuxDiscontinuity = stats.demuxDiscontinuity.asInt
            decodedVideo = stats.decodedVideo.asInt
            decodedAudio = stats.decodedAudio.asInt
            displayedPictures = stats.displayedPictures.asInt
            lostPictures = stats.lostPictures.asInt
            playedAudioBuffers = stats.playedAudioBuffers.asInt
            lostAudioBuffers = stats.lostAudioBuffers.asInt
            // VLCKit 4.0's VLCMediaStats dropped the stream-output (sout)
            // counters entirely — sentPackets/sentBytes/sendBitrate only
            // ever meant anything for sout sessions (stream-output /
            // transcoding), not regular playback. Kept as always-0 fields
            // here rather than removed, so this isn't a source-breaking
            // change to VLCUI's own public API for anything reading them
            // (nothing in playr does — grepped).
            sentPackets = 0
            sentBytes = 0
            sendBitrate = 0
        }
    }
}
