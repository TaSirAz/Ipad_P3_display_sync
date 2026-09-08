import Foundation

enum OutputColorTag: String, CaseIterable, Identifiable {
    case displayP3
    case rec709
    case legacyP3
    var id: String { rawValue }
    var title: String {
        switch self {
        case .displayP3: return "P3 managed"
        case .rec709: return "709 managed"
        case .legacyP3: return "P3 legacy"
        }
    }
}

enum DisplayConfig {
    static let width = 2360
    static let height = 1640
    static let refreshHz = 60
    static let bytesPerPixel = 8
    static let rowBytes = width * bytesPerPixel
    static let frameBytes = rowBytes * height
    static let tileSize = 128
    static let tileCount = ((width + tileSize - 1) / tileSize) * ((height + tileSize - 1) / tileSize)
    static let maxTileBytes = tileSize * tileSize * bytesPerPixel
    static let maxCompressedTileBytes = maxTileBytes + maxTileBytes / 255 + 16
    static let port: UInt16 = 55002
    static let secondaryPort: UInt16 = 55003
    static let magic = "IPD17RAW"
    static let defaultOutputColorTag: OutputColorTag = .displayP3
    static var hello: Data {
        var data = Data("IPD17ACK".utf8)
        for value in [UInt32(17), UInt32(width), UInt32(height), UInt32(refreshHz), UInt32(10), UInt32(tileSize)] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }
}
