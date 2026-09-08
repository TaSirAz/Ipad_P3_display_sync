import Foundation
import Compression

enum LosslessCodec {
    static let lz4Raw: UInt32 = 1
    static let xorFlag: UInt32 = 1
    static func decodeLZ4(_ encoded: Data, decodedBytes: Int) -> Data? {
        guard decodedBytes > 0, encoded.count > 0 else { return nil }
        var result = Data(count: decodedBytes + 1)
        let count = result.withUnsafeMutableBytes { dstRaw in
            encoded.withUnsafeBytes { srcRaw in
                compression_decode_buffer(dstRaw.bindMemory(to: UInt8.self).baseAddress!, decodedBytes + 1,
                    srcRaw.bindMemory(to: UInt8.self).baseAddress!, encoded.count, nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard count == decodedBytes else { return nil }
        result.removeLast(); return result
    }
    static func decodeFull(_ payload: Data, expectedXor: Bool) -> Data? {
        guard payload.count >= 17, payload.u32LE(at: 0) == 17,
              Int(payload.u32LE(at: 4)) == DisplayConfig.frameBytes else { return nil }
        let encodedBytes = Int(payload.u32LE(at: 8)), flags = payload.u32LE(at: 12)
        guard flags == (expectedXor ? xorFlag : 0), encodedBytes == payload.count - 16 else { return nil }
        return decodeLZ4(payload.subdata(in: 16..<payload.count), decodedBytes: DisplayConfig.frameBytes)
    }
}

struct FrameSnapshot: Sendable {
    let data: Data, epoch: UInt64
    let countable: Bool
    let sequence: UInt64, readyNs: UInt64, receiveStartNs: UInt64
}
struct XorTileUpdate: Sendable {
    let batchID: UInt64
    let x: Int, y: Int, width: Int, height: Int
    let delta: Data
}
struct CompressedTileUpdate: Sendable {
    let batchID: UInt64
    let x: Int, y: Int, width: Int, height: Int
    let decodedBytes: Int
    let encoded: Data
}

final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var framebuffer = Data(count: DisplayConfig.frameBytes)
    private var buildingBatch: UInt64?
    private var batchTiles: [XorTileUpdate] = []
    private var tileIndices: Set<Int> = []
    private var needsFullFrame = true
    private var lastBatch: UInt64?
    private var committedGeneration: UInt64 = 0, consumedGeneration: UInt64 = 0, epoch: UInt64 = 0
    private var receivedFrames: UInt64 = 0, presentedFrames: UInt64 = 0
    private var readyNs: UInt64 = 0, timingSequence: UInt64 = 0
    private var receiveStartNs: UInt64 = 0, pendingReceiveStartNs: UInt64 = 0
    private var events: [(UInt64,UInt64,UInt64)] = [], lostEvents: UInt64 = 0

    func referenceReadings(codes: [[UInt32]]) -> String {
        lock.lock(); defer { lock.unlock() }
        guard receivedFrames > 0 else { return "尚未收到影格；請啟動 Windows 串流" }
        var lines: [String] = []
        for i in 0..<codes.count {
            let x = (i % 3) * DisplayConfig.width / 3 + DisplayConfig.width / 12
            let y = (i / 3) * DisplayConfig.height / 4 + DisplayConfig.height / 8
            let offset = (y * DisplayConfig.width + x) * DisplayConfig.bytesPerPixel
            let words = (0..<4).map { channel in framebuffer.withUnsafeBytes { raw in raw.loadUnaligned(fromByteOffset: offset + channel * 2, as: UInt16.self) }.littleEndian }
            lines.append("\(i+1): " + words.map { String(format: "%04X", $0) }.joined(separator: "/"))
        }
        return lines.joined(separator: "  |  ")
    }
    func currentEpoch() -> UInt64 { lock.lock(); defer { lock.unlock() }; return epoch }
    @discardableResult func beginTiming(sequence: UInt64, now: UInt64, expectedEpoch: UInt64? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let expectedEpoch, expectedEpoch != epoch { return false }
        if timingSequence != sequence || pendingReceiveStartNs == 0 { timingSequence = sequence; pendingReceiveStartNs = now }
        return true
    }
    func timing(_ sequence: UInt64,_ metric: UInt64,_ value: UInt64,epoch expected: UInt64? = nil) {
        lock.lock(); defer { lock.unlock() }; if let expected, expected != epoch { return }
        if events.count < 8192 { events.append((sequence,metric,value)) } else { lostEvents &+= 1 }
    }
    func takeTiming() -> [(UInt64,UInt64,UInt64)] {
        lock.lock(); defer { lock.unlock() }; var result=events;events.removeAll(keepingCapacity:true)
        if lostEvents > 0 { result.append((0,99,lostEvents));lostEvents=0 };return result
    }
    func reset() {
        lock.lock(); defer { lock.unlock() };framebuffer=Data(count:DisplayConfig.frameBytes)
        batchTiles.removeAll(keepingCapacity:true);tileIndices.removeAll(keepingCapacity:true);buildingBatch=nil;lastBatch=nil;needsFullFrame=true
        epoch &+= 1;receivedFrames=0;presentedFrames=0;events.removeAll(keepingCapacity:true);lostEvents=0;readyNs=0;receiveStartNs=0;pendingReceiveStartNs=0;timingSequence=0;committedGeneration &+= 1
    }
    func receive(tile: XorTileUpdate,expectedEpoch: UInt64? = nil) -> Bool {
        lock.lock();defer{lock.unlock()};if let expectedEpoch,expectedEpoch != epoch{return false};let size=DisplayConfig.tileSize
        guard !needsFullFrame,tile.x>=0,tile.y>=0,tile.x<DisplayConfig.width,tile.y<DisplayConfig.height,tile.x%size==0,tile.y%size==0,
              tile.width==min(size,DisplayConfig.width-tile.x),tile.height==min(size,DisplayConfig.height-tile.y),
              tile.delta.count==tile.width*tile.height*DisplayConfig.bytesPerPixel,batchTiles.count<DisplayConfig.tileCount,
              buildingBatch==nil||buildingBatch==tile.batchID,lastBatch==nil||tile.batchID>lastBatch! else{return false}
        let columns=(DisplayConfig.width+size-1)/size,index=(tile.y/size)*columns+tile.x/size
        guard tileIndices.insert(index).inserted else{return false};buildingBatch=tile.batchID;batchTiles.append(tile);return true
    }
    func commit(batchID: UInt64,expectedEpoch: UInt64? = nil) -> Bool {
        lock.lock();defer{lock.unlock()};if let expectedEpoch,expectedEpoch != epoch{return false}
        guard !needsFullFrame,buildingBatch==batchID,!batchTiles.isEmpty else{return false}
        framebuffer.withUnsafeMutableBytes { dstRaw in
            let dst=dstRaw.bindMemory(to:UInt8.self).baseAddress!
            for tile in batchTiles { tile.delta.withUnsafeBytes { srcRaw in
                let src=srcRaw.bindMemory(to:UInt8.self).baseAddress!
                for row in 0..<tile.height { let to=(tile.y+row)*DisplayConfig.rowBytes+tile.x*DisplayConfig.bytesPerPixel,from=row*tile.width*DisplayConfig.bytesPerPixel
                    for i in 0..<(tile.width*DisplayConfig.bytesPerPixel) { dst[to+i] ^= src[from+i] }
                }
            }}
        }
        batchTiles.removeAll(keepingCapacity:true);tileIndices.removeAll(keepingCapacity:true);buildingBatch=nil;lastBatch=batchID
        receivedFrames &+= 1;committedGeneration &+= 1;receiveStartNs=pendingReceiveStartNs;readyNs=DispatchTime.now().uptimeNanoseconds;return true
    }
    func publish(frame: Data,batchID: UInt64,xor: Bool=false,expectedEpoch: UInt64? = nil) -> Bool {
        lock.lock();defer{lock.unlock()};if let expectedEpoch,expectedEpoch != epoch{return false}
        guard frame.count == DisplayConfig.frameBytes, buildingBatch == nil, lastBatch == nil || batchID > lastBatch!, !xor || !needsFullFrame else { return false }
        if xor { framebuffer.withUnsafeMutableBytes { dstRaw in frame.withUnsafeBytes { srcRaw in
            let dst=dstRaw.bindMemory(to:UInt8.self).baseAddress!,src=srcRaw.bindMemory(to:UInt8.self).baseAddress!
            for i in 0..<DisplayConfig.frameBytes { dst[i] ^= src[i] }
        }}} else { framebuffer=frame }
        lastBatch=batchID;needsFullFrame=false;committedGeneration &+= 1;receivedFrames &+= 1;receiveStartNs=pendingReceiveStartNs;readyNs=DispatchTime.now().uptimeNanoseconds;return true
    }
    func didPresent(epoch frameEpoch: UInt64){lock.lock();defer{lock.unlock()};if frameEpoch==epoch{presentedFrames &+= 1}}
    func statistics()->(received:UInt64,presented:UInt64){lock.lock();defer{lock.unlock()};return(receivedFrames,presentedFrames)}
    func consume()->Data?{consumeFrame()?.data}
    func consumeFrame()->FrameSnapshot?{lock.lock();defer{lock.unlock()};guard committedGeneration != consumedGeneration else{return nil};consumedGeneration=committedGeneration
        return FrameSnapshot(data:framebuffer,epoch:epoch,countable:receivedFrames>0,sequence:lastBatch ?? 0,readyNs:readyNs,receiveStartNs:receiveStartNs)}
}

enum FrameWork: Sendable { case tile(CompressedTileUpdate);case full(Data,Bool);case commit }
struct PacketMeasurement: Sendable {let sequence:UInt64,startNs:UInt64,readNs:UInt64,appendNs:UInt64,callbacks:UInt64,queuedNs:UInt64}
enum FrameWorkProcessor {
    static func apply(_ work:FrameWork,measurement m:PacketMeasurement,epoch:UInt64,store:FrameStore)->Bool{
        let started=DispatchTime.now().uptimeNanoseconds;guard store.beginTiming(sequence:m.sequence,now:m.startNs,expectedEpoch:epoch)else{return false}
        let before=DispatchTime.now().uptimeNanoseconds;var decodeNs:UInt64=0;let ok:Bool
        switch work {
        case .tile(let tile):
            guard let delta=LosslessCodec.decodeLZ4(tile.encoded,decodedBytes:tile.decodedBytes)else{return false};decodeNs=DispatchTime.now().uptimeNanoseconds-before
            ok=store.receive(tile:XorTileUpdate(batchID:tile.batchID,x:tile.x,y:tile.y,width:tile.width,height:tile.height,delta:delta),expectedEpoch:epoch)
        case .full(let payload,let xor):
            guard let pixels=LosslessCodec.decodeFull(payload,expectedXor:xor)else{return false};decodeNs=DispatchTime.now().uptimeNanoseconds-before
            ok=store.publish(frame:pixels,batchID:m.sequence,xor:xor,expectedEpoch:epoch)
        case .commit: ok=store.commit(batchID:m.sequence,expectedEpoch:epoch)
        }
        let done=DispatchTime.now().uptimeNanoseconds
        for(metric,value) in [(UInt64(1),m.readNs),(2,m.appendNs),(3,decodeNs),(4,done-before),(11,m.callbacks),(12,started-m.queuedNs)]{store.timing(m.sequence,metric,value,epoch:epoch)}
        return ok
    }
}

extension Data {
    func u16LE(at o:Int)->UInt16{UInt16(self[o])|(UInt16(self[o+1])<<8)}
    func u32LE(at o:Int)->UInt32{UInt32(u16LE(at:o))|(UInt32(u16LE(at:o+2))<<16)}
    func u64LE(at o:Int)->UInt64{UInt64(u32LE(at:o))|(UInt64(u32LE(at:o+4))<<32)}
}


