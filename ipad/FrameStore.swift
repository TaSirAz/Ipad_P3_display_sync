import Foundation
import Compression

enum RawLossless {
    // Matches LosslessFrame.h; blocks are independent and every frame is complete.
    static func decode(_ payload: Data) -> Data? {
        func u32(_ at: Int) -> UInt32 {
            UInt32(payload[at]) | UInt32(payload[at+1]) << 8 |
            UInt32(payload[at+2]) << 16 | UInt32(payload[at+3]) << 24
        }
        guard payload.count >= 16, u32(0) == 1, Int(u32(8)) == DisplayConfig.frameBytes,
              u32(12) == 0 else { return nil }
        let count = Int(u32(4))
        guard count >= 1, count <= 64, payload.count >= 16 + count * 8 else { return nil }
        var blocks: [(decoded: Int, stored: Int, raw: Bool)] = []
        var encodedTotal = 16 + count * 8, decodedTotal = 0
        for i in 0..<count {
            let decoded = Int(u32(16 + i * 8)), value = u32(20 + i * 8)
            let stored = Int(value & 0x7fff_ffff), raw = value & 0x8000_0000 != 0
            guard decoded > 0, decoded <= DisplayConfig.frameBytes - decodedTotal,
                  stored > 0, stored <= payload.count - encodedTotal,
                  !raw || stored == decoded else { return nil }
            blocks.append((decoded, stored, raw)); encodedTotal += stored; decodedTotal += decoded
        }
        guard encodedTotal == payload.count, decodedTotal == DisplayConfig.frameBytes else { return nil }
        // One extra byte detects an oversized decoded block instead of accepting truncation.
        var result = Data(count: DisplayConfig.frameBytes + 1)
        let valid = result.withUnsafeMutableBytes { dstRaw in
            payload.withUnsafeBytes { srcRaw in
                let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                let src = srcRaw.bindMemory(to: UInt8.self).baseAddress!
                var from = 16 + count * 8, to = 0
                for block in blocks {
                    if block.raw { memcpy(dst + to, src + from, block.decoded) }
                    else {
                        let n = compression_decode_buffer(dst + to, block.decoded + 1,
                                                          src + from, block.stored, nil, COMPRESSION_LZ4_RAW)
                        if n != block.decoded { return false }
                    }
                    from += block.stored; to += block.decoded
                }
                return true
            }
        }
        guard valid else { return nil }; result.removeLast(); return result
    }
}
struct FrameSnapshot: Sendable {
    let data: Data
    let epoch: UInt64
    let countable: Bool
    let sequence: UInt64
    let readyNs: UInt64
    let receiveStartNs: UInt64
}
struct RawTileUpdate: Sendable {
    let batchID: UInt64
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let payload: Data
}
final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var framebuffer = Data(count: DisplayConfig.frameBytes)
    private var buildingBatch: UInt64?
    private var batchTiles: [RawTileUpdate] = []
    private var tileIndices: Set<Int> = []
    private var needsFullFrame = true
    private var lastBatch: UInt64?
    private var committedGeneration: UInt64 = 0
    private var consumedGeneration: UInt64 = 0
    private var epoch: UInt64 = 0
    private var receivedFrames: UInt64 = 0
    private var presentedFrames: UInt64 = 0
    private var readyNs: UInt64 = 0
    private var timingSequence: UInt64 = 0
    private var receiveStartNs: UInt64 = 0
    private var pendingReceiveStartNs: UInt64 = 0
    private var events: [(UInt64, UInt64, UInt64)] = []
    private var lostEvents: UInt64 = 0
    func beginTiming(sequence: UInt64, now: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if timingSequence != sequence || pendingReceiveStartNs == 0 { timingSequence = sequence; pendingReceiveStartNs = now }
    }
    func timing(_ sequence: UInt64, _ metric: UInt64, _ value: UInt64, epoch expected: UInt64? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let expected, expected != epoch { return }
        if events.count < 8192 { events.append((sequence, metric, value)) } else { lostEvents &+= 1 }
    }
    func takeTiming() -> [(UInt64, UInt64, UInt64)] {
        lock.lock(); defer { lock.unlock() }
        var result = events; events.removeAll(keepingCapacity: true)
        if lostEvents > 0 { result.append((0, 99, lostEvents)); lostEvents = 0 }
        return result
    }
    func reset() {
        lock.lock(); defer { lock.unlock() }
        framebuffer = Data(count: DisplayConfig.frameBytes)
        batchTiles.removeAll(keepingCapacity: true)
        tileIndices.removeAll(keepingCapacity: true)
        buildingBatch = nil; lastBatch = nil; needsFullFrame = true
        epoch &+= 1; receivedFrames = 0; presentedFrames = 0
        events.removeAll(keepingCapacity: true); lostEvents = 0; readyNs = 0; receiveStartNs = 0; pendingReceiveStartNs = 0; timingSequence = 0
        committedGeneration &+= 1
    }
    func receive(tile: RawTileUpdate) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let size = DisplayConfig.tileSize
        guard tile.x >= 0, tile.y >= 0,
              tile.x < DisplayConfig.width, tile.y < DisplayConfig.height,
              tile.x % size == 0, tile.y % size == 0,
              tile.width == min(size, DisplayConfig.width - tile.x),
              tile.height == min(size, DisplayConfig.height - tile.y),
              tile.payload.count == tile.width * tile.height * 4,
              batchTiles.count < DisplayConfig.tileCount,
              buildingBatch == nil || buildingBatch == tile.batchID,
              lastBatch == nil || tile.batchID > lastBatch! else { return false }
        let columns = (DisplayConfig.width + size - 1) / size
        let index = (tile.y / size) * columns + tile.x / size
        guard tileIndices.insert(index).inserted else { return false }
        buildingBatch = tile.batchID
        batchTiles.append(tile)
        return true
    }
    func commit(batchID: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard buildingBatch == batchID,
              !needsFullFrame || batchTiles.count == DisplayConfig.tileCount else { return false }
        framebuffer.withUnsafeMutableBytes { dstRaw in
            guard let dst = dstRaw.baseAddress else { return }
            for tile in batchTiles {
                tile.payload.withUnsafeBytes { srcRaw in
                    guard let src = srcRaw.baseAddress else { return }
                    for row in 0..<tile.height {
                        memcpy(dst.advanced(by: (tile.y + row) * DisplayConfig.rowBytes + tile.x * 4),
                               src.advanced(by: row * tile.width * 4), tile.width * 4)
                    }
                }
            }
        }
        batchTiles.removeAll(keepingCapacity: true)
        tileIndices.removeAll(keepingCapacity: true)
        buildingBatch = nil; lastBatch = batchID; needsFullFrame = false
        receivedFrames &+= 1
        committedGeneration &+= 1
        receiveStartNs = pendingReceiveStartNs
        readyNs = DispatchTime.now().uptimeNanoseconds
        return true
    }
    func publish(frame: Data, batchID: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard frame.count == DisplayConfig.frameBytes, buildingBatch == nil,
              lastBatch == nil || batchID > lastBatch! else { return false }
        framebuffer = frame
        lastBatch = batchID; needsFullFrame = false
        committedGeneration &+= 1; receivedFrames &+= 1
        receiveStartNs = pendingReceiveStartNs
        readyNs = DispatchTime.now().uptimeNanoseconds
        return true
    }
    func didPresent(epoch frameEpoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if frameEpoch == epoch { presentedFrames &+= 1 }
    }
    func statistics() -> (received: UInt64, presented: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (receivedFrames, presentedFrames)
    }
    func consume() -> Data? { consumeFrame()?.data }
    func consumeFrame() -> FrameSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard committedGeneration != consumedGeneration else { return nil }
        consumedGeneration = committedGeneration
        // Data value semantics isolate later writes by copy-on-write.
        return FrameSnapshot(data: framebuffer, epoch: epoch, countable: receivedFrames > 0, sequence: lastBatch ?? 0, readyNs: readyNs, receiveStartNs: receiveStartNs)
    }
}
