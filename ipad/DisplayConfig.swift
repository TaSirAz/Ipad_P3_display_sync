import Foundation
enum DisplayConfig {
    static let width = 2360
    static let height = 1640
    static let refreshHz = 60
    static let bytesPerPixel = 4
    static let rowBytes = width * bytesPerPixel
    static let frameBytes = rowBytes * height
    static let tileSize = 128
    static let tileCount = ((width + tileSize - 1) / tileSize) * ((height + tileSize - 1) / tileSize)
    static let port: UInt16 = 55001
    static let magic = "IPD71RAW"
    static var hello: Data {
        var data = Data("IPD71ACK".utf8)
        for value in [UInt32(6), UInt32(width), UInt32(height), UInt32(refreshHz), UInt32(24), UInt32(tileSize)] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }
}

// Counts bytes received using the iPad monotonic clock, independent of sender buffering.
// Confined to FrameServer's network queue. Reset at connection and window boundaries.
struct TransferProbe {
    private(set) var bytes: UInt64 = 0
    private var startNs: UInt64?
    private var lastNs: UInt64 = 0
    mutating func begin(now: UInt64) { if startNs == nil { startNs = now } }
    mutating func received(_ count: Int, now: UInt64) {
        guard count > 0, startNs != nil else { return }
        bytes += UInt64(count); lastNs = now
    }
    var elapsedNs: UInt64 {
        guard let startNs, bytes > 0, lastNs >= startNs else { return 0 }
        return lastNs - startNs
    }
    static func accepts(type: UInt32, size: Int) -> Bool {
        (type == 5 || type == 7) && size > 0 && size <= DisplayConfig.frameBytes + 528
    }
}
