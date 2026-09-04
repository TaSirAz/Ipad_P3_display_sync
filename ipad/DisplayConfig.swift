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
        for value in [UInt32(5), UInt32(width), UInt32(height), UInt32(refreshHz), UInt32(24), UInt32(tileSize)] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }
}
