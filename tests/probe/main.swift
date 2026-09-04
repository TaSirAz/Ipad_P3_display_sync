import Foundation
import Darwin
func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
let server = FrameServer()
server.start()
func connectLocal() -> Int32 {
    for _ in 0..<30 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = DisplayConfig.port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if result == 0 {
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            return fd
        }
        close(fd); Thread.sleep(forTimeInterval: 0.1)
    }
    fatalError("Probe listener unavailable")
}
func read(_ fd: Int32, _ count: Int) -> Data {
    var data = Data(count: count)
    data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        var used = 0
        while used < count {
            let got = recv(fd, raw.baseAddress!.advanced(by: used), count - used, 0)
            check(got > 0, "Socket closed or read timed out")
            used += got
        }
    }
    return data
}
func write(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        var used = 0
        while used < raw.count {
            let sent = send(fd, raw.baseAddress!.advanced(by: used), raw.count - used, 0)
            check(sent > 0, "Socket write failed"); used += sent
        }
    }
}
func header(_ type: UInt32, _ size: Int, _ sequence: UInt64) -> Data {
    var data = Data(DisplayConfig.magic.utf8)
    for value in [type, UInt32(size)] { var v=value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf:$0) } }
    for value in [sequence, UInt64(0)] { var v=value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf:$0) } }
    return data
}
func ack(_ fd: Int32, _ sequence: UInt64, _ bytes: UInt64) {
    write(fd, header(6,0,sequence))
    for _ in 0..<2048 {
        let data = read(fd,32)
        if data.prefix(8) == Data("IPD71BEN".utf8) {
            check(data.u64LE(at:8)==sequence && data.u64LE(at:16)==bytes, "Receiver acknowledges exact sequence and bytes")
            check(bytes==0 || data.u64LE(at:24)>0, "Nonempty receiver duration")
            return
        }
        check(data.prefix(8)==Data("IPD71TIM".utf8) || data.prefix(8)==Data("IPD71STA".utf8), "Known report")
    }
    fatalError("Probe reply missing")
}
let fd = connectLocal()
check(read(fd,32)==DisplayConfig.hello,"v6 handshake")
let payload = Data(repeating: 91, count: 3*1024*1024+37)
for type: UInt32 in [5,7] {
    let h = header(type,payload.count,UInt64(type))
    write(fd,Data(h.prefix(3))); write(fd,Data(h.dropFirst(3)))
    write(fd,Data(payload.prefix(17))); write(fd,Data(payload.dropFirst(17)))
    ack(fd,UInt64(type+100),UInt64(payload.count))
    check(server.frameStore.statistics().received==0,"Probe bypasses framebuffer publication")
    ack(fd,UInt64(type+200),0)
}
let full=Data(repeating:73,count:DisplayConfig.frameBytes)
write(fd,header(3,full.count,300));write(fd,full);ack(fd,301,UInt64(full.count))
for _ in 0..<100 {
    if server.frameStore.statistics().received==1 { break }
    Thread.sleep(forTimeInterval:0.01)
}
check(server.frameStore.statistics().received==1,"Normal mode still publishes frames")
check(server.frameStore.consumeFrame()!.data==full,"Normal frame byte-exact")
close(fd)
let next=connectLocal()
check(read(next,32)==DisplayConfig.hello,"Reconnect handshake")
ack(next,1,0)
close(next)
print("PASS: real TCP loopback, fragmented headers/payloads, drain/assemble exact counters, window/reset isolation and normal full-frame bytes")
