import Foundation
struct FrameSnapshot: Sendable {
    let data: Data
    let epoch: UInt64
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
    func reset() {
        lock.lock(); defer { lock.unlock() }
        framebuffer = Data(count: DisplayConfig.frameBytes)
        batchTiles.removeAll(keepingCapacity: true)
        tileIndices.removeAll(keepingCapacity: true)
        buildingBatch = nil; lastBatch = nil; needsFullFrame = true
        epoch &+= 1; receivedFrames = 0; presentedFrames = 0
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
        return true
    }
    func publish(frame: Data, batchID: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard frame.count == DisplayConfig.frameBytes, buildingBatch == nil,
              lastBatch == nil || batchID > lastBatch! else { return false }
        framebuffer = frame
        lastBatch = batchID; needsFullFrame = false
        committedGeneration &+= 1; receivedFrames &+= 1
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
        return FrameSnapshot(data: framebuffer, epoch: epoch)
    }
}
