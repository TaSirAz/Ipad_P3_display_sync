import Foundation
import Compression

func check(_ value:Bool,_ message:String){if !value{fatalError(message)}}
func appendU32(_ value:UInt32,to data:inout Data){var little=value.littleEndian;withUnsafeBytes(of:&little){data.append(contentsOf:$0)}}
func encodeLZ4(_ input:Data)->Data{
    let capacity=input.count+input.count/255+16
    var out=Data(count:capacity)
    let n=out.withUnsafeMutableBytes{dst in input.withUnsafeBytes{src in
        compression_encode_buffer(dst.bindMemory(to:UInt8.self).baseAddress!,capacity,
            src.bindMemory(to:UInt8.self).baseAddress!,input.count,nil,COMPRESSION_LZ4_RAW)}}
    check(n>0,"LZ4 encode");out.removeSubrange(n..<out.count);return out
}
func fullPayload(_ pixels:Data,xor:Bool)->Data{
    let encoded=encodeLZ4(pixels);var payload=Data();for value in [UInt32(17),UInt32(pixels.count),UInt32(encoded.count),xor ? UInt32(1):UInt32(0)]{appendU32(value,to:&payload)};payload.append(encoded);return payload
}

check(DisplayConfig.frameBytes==30_963_200,"FP16 frame size")
check(DisplayConfig.rowBytes==18_880,"FP16 stride")
check(DisplayConfig.hello.prefix(8)==Data("IPD17ACK".utf8),"v17 handshake")
check(DisplayConfig.hello.u32LE(at:8)==17,"v17 number")

var first=Data(count:DisplayConfig.frameBytes)
let pattern:[UInt8]=[0x00,0xb4,0x00,0x40,0x01,0x00,0x00,0x3c]
first.replaceSubrange(0..<8,with:pattern);first.replaceSubrange((first.count-8)..<first.count,with:pattern.reversed())
let store=FrameStore();let epoch=store.currentEpoch()
let full=fullPayload(first,xor:false)
guard let decoded=LosslessCodec.decodeFull(full,expectedXor:false)else{fatalError("full decode")}
check(decoded==first,"full byte exact")
check(store.publish(frame:decoded,batchID:1,expectedEpoch:epoch),"publish full")
check(store.consume()==first,"consume full")

var second=first;second[0]^=0x80;second[17]^=0x55;second[second.count-1]^=1
var delta=Data(count:first.count);delta.withUnsafeMutableBytes{d in first.withUnsafeBytes{a in second.withUnsafeBytes{b in
    let dp=d.bindMemory(to:UInt8.self).baseAddress!,ap=a.bindMemory(to:UInt8.self).baseAddress!,bp=b.bindMemory(to:UInt8.self).baseAddress!
    for i in 0..<first.count{dp[i]=ap[i]^bp[i]}
}}}
guard let decodedDelta=LosslessCodec.decodeFull(fullPayload(delta,xor:true),expectedXor:true)else{fatalError("xor full decode")}
check(store.publish(frame:decodedDelta,batchID:2,xor:true,expectedEpoch:epoch),"publish xor full")
check(store.consume()==second,"xor full byte exact")

var third=second;third[100]^=7
let tileWidth=min(DisplayConfig.tileSize,DisplayConfig.width),tileHeight=min(DisplayConfig.tileSize,DisplayConfig.height)
var tileDelta=Data(count:tileWidth*tileHeight*DisplayConfig.bytesPerPixel)
tileDelta.withUnsafeMutableBytes{dst in second.withUnsafeBytes{a in third.withUnsafeBytes{b in
    let dp=dst.bindMemory(to:UInt8.self).baseAddress!,ap=a.bindMemory(to:UInt8.self).baseAddress!,bp=b.bindMemory(to:UInt8.self).baseAddress!
    for row in 0..<tileHeight{for i in 0..<(tileWidth*DisplayConfig.bytesPerPixel){let at=row*DisplayConfig.rowBytes+i;dp[row*tileWidth*DisplayConfig.bytesPerPixel+i]=ap[at]^bp[at]}}
}}}
let compressedTile=CompressedTileUpdate(batchID:3,x:0,y:0,width:tileWidth,height:tileHeight,decodedBytes:tileDelta.count,encoded:encodeLZ4(tileDelta))
let m=PacketMeasurement(sequence:3,startNs:1,readNs:0,appendNs:0,callbacks:1,queuedNs:1)
check(FrameWorkProcessor.apply(.tile(compressedTile),measurement:m,epoch:epoch,store:store),"tile decode")
check(FrameWorkProcessor.apply(.commit,measurement:m,epoch:epoch,store:store),"tile commit")
check(store.consume()==third,"tile XOR byte exact")
check(!store.publish(frame:Data(count:DisplayConfig.frameBytes/2),batchID:4,expectedEpoch:epoch),"reject reduced color frame")
print("PASS v17 FP16 LZ4 full, XOR-full, XOR-tile byte-exact; raw/reduced frame rejected")



