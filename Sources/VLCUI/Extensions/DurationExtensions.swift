import VLCKit

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
extension Duration {

    var microseconds: Int64 {
        (components.attoseconds / 1_000_000_000_000) + components.seconds * 1_000_000
    }

    var milliseconds: Int64 {
        (components.attoseconds / 1_000_000_000_000_000) + components.seconds * 1000
    }

    var asVLCTime: VLCTime {
        VLCTime(int: Int32(milliseconds))
    }
}
