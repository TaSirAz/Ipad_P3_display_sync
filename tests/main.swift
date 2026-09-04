import Foundation
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let store = FrameStore()
check(DisplayConfig.hello.count == 32, "Handshake size")
check(DisplayConfig.width == 2360 && DisplayConfig.height == 1640, "Native dimensions")
check(DisplayConfig.frameBytes == 15_481_600 && DisplayConfig.tileCount == 247, "Frame and grid sizes")
func tile(_ x: Int, _ y: Int, batch: UInt64, value: UInt8) -> RawTileUpdate {
    let w = min(DisplayConfig.tileSize, DisplayConfig.width-x)
    let h = min(DisplayConfig.tileSize, DisplayConfig.height-y)
    return RawTileUpdate(batchID: batch, x: x, y: y, width: w, height: h, payload: Data(repeating: value, count: w*h*4))
}
check(store.receive(tile: tile(0,0,batch:0,value:1)), "First tile")
check(!store.commit(batchID:0), "Incomplete first frame rejected")
store.reset()
for y in stride(from: 0, to: DisplayConfig.height, by: DisplayConfig.tileSize) {
    for x in stride(from: 0, to: DisplayConfig.width, by: DisplayConfig.tileSize) {
        check(store.receive(tile: tile(x,y,batch:0,value:UInt8((x/128+y/128)%255))), "Full frame tile")
    }
}
check(store.commit(batchID:0), "Full frame commit")
let first = store.consume()!
check(first.count == DisplayConfig.frameBytes, "Native snapshot size")
check(first[0] == 0 && first[first.count-1] == 30, "First and last native pixels")
check(store.consume() == nil, "No duplicate frame")
check(store.receive(tile: tile(2304,1536,batch:1,value:99)), "56x104 bottom right edge tile")
check(store.commit(batchID:1), "Partial update")
let second = store.consume()!
check(second[second.count-1] == 99 && second[0] == 0, "Partial tile preserved other pixels")
check(first[first.count-1] == 30, "Old snapshot immutable")
check(!store.receive(tile: tile(0,0,batch:1,value:1)), "Old batch rejected")
check(store.receive(tile: tile(0,0,batch:2,value:1)), "New batch")
check(!store.receive(tile: tile(0,0,batch:2,value:1)), "Duplicate tile rejected")
check(!store.receive(tile: tile(0,128,batch:3,value:1)), "Missing commit rejected")
store.reset()
check(!store.receive(tile: RawTileUpdate(batchID:0,x:2359,y:1639,width:128,height:128,payload:Data(count:65536))), "Out of bounds rejected")
print("PASS: native dimensions, handshake length, all 247 tiles, bottom-right edge, full-first-frame requirement, immutable snapshots, partial updates and malformed batches")
store.reset()
let full = Data(repeating: 73, count: DisplayConfig.frameBytes)
check(store.publish(frame: full, batchID: 10), "Full frame published")
let native = store.consumeFrame()!
check(native.countable, "Received frame counts as presentation")
check(native.data == full, "Full frame byte-for-byte preserved")
check(!store.publish(frame: full, batchID: 10), "Duplicate full frame rejected")
check(!store.publish(frame: Data(count: 4), batchID: 11), "Truncated full frame rejected")
store.didPresent(epoch: native.epoch)
check(store.statistics().received == 1 && store.statistics().presented == 1, "RX and actual presentation counters")
store.reset()
store.didPresent(epoch: native.epoch)
check(store.statistics().presented == 0, "Stale presentation from old connection rejected")
check(store.consumeFrame()?.countable == false, "Reset blank is not a received frame")
print("PASS: full-frame RAW publication, exact bytes, duplicate/truncated rejection, presentation epoch accounting")
let fixture = try Data(contentsOf: URL(fileURLWithPath: "tests/fixtures/bgr10a2-lz4.bin"))
let unpacked = RawLossless.decode(fixture)!
check(unpacked.count == DisplayConfig.frameBytes, "Lossless native frame length")
unpacked.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
    for i in 0..<(raw.count / 4) {
        let q = UInt32(i % 1024)
        let green: UInt32 = ((q * 3) % 1024) << 10
        let red: UInt32 = ((q * 7) % 1024) << 20
        let expected: UInt32 = q | green | red | UInt32(0xc0000000)
        let word = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
        check(UInt32(littleEndian: word) == expected, "Windows LZ4 -> Apple exact 10-bit pixel")
    }
}
check(RawLossless.decode(Data(fixture.dropLast())) == nil, "Truncated lossless frame rejected")
var invalid = fixture; invalid[8] ^= 1
check(RawLossless.decode(invalid) == nil, "Invalid decoded size rejected")
invalid = fixture; invalid[20] = 0; invalid[21] = 0; invalid[22] = 0; invalid[23] = 0
check(RawLossless.decode(invalid) == nil, "Empty compressed block rejected")
print("PASS: Windows LZ4 -> Apple Compression, all 3870400 synthetic 10-bit pixels exact, invalid blocks rejected")
let hcFixture = try Data(contentsOf: URL(fileURLWithPath: "tests/fixtures/bgr10a2-hc64.bin"))
check(RawLossless.decode(hcFixture) == unpacked, "64 HC blocks match all original pixels")
let mixed = FrameStore()
check(mixed.publish(frame: full, batchID: 1), "Complete frame starts mixed stream")
let before = mixed.consume()!
check(mixed.receive(tile: tile(0, 0, batch: 2, value: 98)), "Partial RAW after complete frame")
check(mixed.commit(batchID: 2), "Partial update commits atomically")
let after = mixed.consume()!
check(after[0] == 98 && after[after.count-1] == 73 && before[0] == 73, "Mixed stream preserves unchanged pixels and old snapshot")
check(mixed.publish(frame: full, batchID: 3), "Complete frame follows partial update")
check(mixed.consume() == full, "Complete frame resets all pixels exactly")
check(!mixed.receive(tile: tile(0, 0, batch: 2, value: 1)), "Old partial batch rejected")
print("PASS: 64 HC block interoperability and alternating complete/partial atomic RAW frames")

store.reset()
store.beginTiming(sequence: 42, now: 123)
check(store.publish(frame: full, batchID: 42), "Timing full frame")
let timed = store.consumeFrame()!
check(timed.sequence == 42 && timed.receiveStartNs == 123 && timed.readyNs > 0, "Timing associated with frame")
store.timing(42, 9, 100, epoch: timed.epoch)
check(store.takeTiming().count == 1, "Timing event drained")
store.reset()
store.timing(42, 9, 100, epoch: timed.epoch)
check(store.takeTiming().isEmpty, "Stale timing rejected across reset")
for i in 0..<9000 { store.timing(UInt64(i), 1, 0) }
let bounded = store.takeTiming()
check(bounded.count == 8193 && bounded.last!.1 == 99 && bounded.last!.2 == 808, "Timing bounded and losses reported")
print("PASS: per-frame timing association, epoch isolation, bounded reporting")

let piped = FrameStore()
let pipedEpoch = piped.currentEpoch()
func measurement(_ sequence: UInt64) -> PacketMeasurement {
    let now = DispatchTime.now().uptimeNanoseconds
    return PacketMeasurement(sequence: sequence, startNs: now, readNs: 0, appendNs: 0, callbacks: 1, queuedNs: now)
}
check(FrameWorkProcessor.apply(.full(full), measurement: measurement(1), epoch: pipedEpoch, store: piped), "Pipeline full")
let stable = piped.consume()!
check(FrameWorkProcessor.apply(.tile(tile(0,0,batch:2,value:99)), measurement: measurement(2), epoch: pipedEpoch, store: piped), "Pipeline tile")
check(piped.consume() == nil, "Uncommitted tile never visible")
check(FrameWorkProcessor.apply(.commit, measurement: measurement(2), epoch: pipedEpoch, store: piped), "Pipeline commit")
check(piped.consume()![0] == 99 && stable[0] == 73, "Pipeline order and immutable snapshots")
check(FrameWorkProcessor.apply(.lossless(hcFixture), measurement: measurement(3), epoch: pipedEpoch, store: piped), "Pipeline HC decode")
check(piped.consume() == unpacked, "Pipeline decoded bytes exact")
piped.reset()
_ = piped.consume()
check(!FrameWorkProcessor.apply(.full(full), measurement: measurement(4), epoch: pipedEpoch, store: piped), "Old queued frame rejected after reconnect")
check(!piped.publish(frame: full, batchID: 4, expectedEpoch: pipedEpoch), "Decode completing after reset cannot publish")
check(!piped.receive(tile: tile(0,0,batch:4,value:1), expectedEpoch: pipedEpoch), "Old queued tile rejected")
check(!piped.commit(batchID: 4, expectedEpoch: pipedEpoch), "Old queued commit rejected")
check(piped.consume() == nil, "Old connection leaves new framebuffer untouched")
check(FrameWorkProcessor.apply(.full(full), measurement: measurement(1), epoch: piped.currentEpoch(), store: piped), "New connection accepts sequence restart")
check(piped.consume() == full, "New connection frame exact")
print("PASS: ordered processing preserves full/tile/commit/lossless pixels and rejects in-flight old-connection work")

var probe = TransferProbe()
probe.received(10, now: 5)
check(probe.bytes == 0 && probe.elapsedNs == 0, "Probe requires start")
probe.begin(now: 100)
probe.received(65536, now: 200)
probe.begin(now: 250)
probe.received(7, now: 400)
check(probe.bytes == 65543 && probe.elapsedNs == 300, "Fragments counted; begin preserves interval")
probe = TransferProbe()
check(probe.bytes == 0 && probe.elapsedNs == 0, "Window reset clears old data")
probe.begin(now: 500)
check(probe.elapsedNs == 0, "Empty window has zero duration")
check(TransferProbe.accepts(type: 5, size: DisplayConfig.frameBytes), "RAW-sized receive-only probe")
check(TransferProbe.accepts(type: 7, size: DisplayConfig.frameBytes + 528), "Bounded assembled probe")
check(!TransferProbe.accepts(type: 5, size: 0), "Zero payload rejected")
check(!TransferProbe.accepts(type: 5, size: DisplayConfig.frameBytes + 529), "Oversized probe rejected")
check(!TransferProbe.accepts(type: 3, size: DisplayConfig.frameBytes), "Normal frame never mistaken for probe")
check(DisplayConfig.hello[8] == 6, "Receiver advertises probe capability version")
print("PASS: receiver benchmark byte counting, monotonic interval, reset, packet bounds, v6 handshake")
