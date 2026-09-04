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
