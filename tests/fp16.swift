import Foundation
func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
check(DisplayConfig.frameBytes == 30_963_200, "FP16 frame size")
check(DisplayConfig.rowBytes == 18_880, "FP16 stride")
check(DisplayConfig.hello.prefix(8) == Data("IPD16ACK".utf8), "Handshake isolation")
let store = FrameStore()
var pixels = Data(count: DisplayConfig.frameBytes)
// Includes negative, >1, subnormal, and ordinary FP16 bit patterns.
let pattern: [UInt8] = [0x00,0xb4,0x00,0x40,0x01,0x00,0x00,0x3c]
pixels.replaceSubrange(0..<8, with: pattern)
pixels.replaceSubrange((pixels.count-8)..<pixels.count, with: pattern.reversed())
check(!store.publish(frame: Data(count: DisplayConfig.frameBytes/2), batchID: 1), "Reject 10-bit frame")
check(store.publish(frame: pixels, batchID: 1), "Accept FP16")
check(store.consume() == pixels, "All FP16 bytes preserved")
check(!store.publish(frame: pixels, batchID: 1), "Reject repeated sequence")
let oldEpoch = store.currentEpoch(); store.reset()
check(!store.publish(frame: pixels, batchID: 2, expectedEpoch: oldEpoch), "Reject stale connection")
print("PASS FP16 size, byte preservation, sequence, epoch, old format rejection")
