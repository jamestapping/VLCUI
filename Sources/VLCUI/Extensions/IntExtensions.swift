extension Int {

    var asInt32: Int32 {
        Int32(self)
    }
}

extension Int32 {

    var asInt: Int {
        Int(self)
    }
}

extension UInt64 {

    // VLCKit 4.0's VLCMediaStats fields are uint64_t, not the int32_t the
    // old VLCMediaStats used — this keeps PlaybackInformation.Statistics'
    // own fields as plain Int, same as before.
    var asInt: Int {
        Int(self)
    }
}
