import Foundation
import Combine
@preconcurrency import Network
final class FrameServer: ObservableObject, @unchecked Sendable {
    @Published private(set) var status = "STARTING"
    let frameStore = FrameStore()
    // Listener, connection and packet state is confined to this queue.
    private let queue = DispatchQueue(label: "V7.native.image", qos: .userInteractive)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var lastStatsTime: UInt64 = 0
    private var lastReceived: UInt64 = 0
    private var lastPresented: UInt64 = 0
    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.status = message }
    }
    func start() { queue.async { [weak self] in self?.startOnQueue() } }
    private func startOnQueue() {
        guard listener == nil else { return }
        do {
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: DisplayConfig.port)!)
            listener = l
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self, let l, self.listener === l else { return }
                switch state {
                case .ready: self.report("READY v3 • NATIVE 2360×1640 • USB :55001")
                case .failed(let e): self.report("LISTENER FAILED • \(e.localizedDescription)")
                case .waiting(let e): self.report("WAITING • \(e.localizedDescription)")
                default: break
                }
            }
            l.newConnectionHandler = { [weak self, weak l] c in
                guard let self, let l, self.listener === l else { c.cancel(); return }
                self.connection?.cancel()
                self.frameStore.reset()
                self.connection = c
                self.lastStatsTime = DispatchTime.now().uptimeNanoseconds
                self.lastReceived = 0; self.lastPresented = 0
                c.stateUpdateHandler = { [weak self, weak c] state in
                    guard let self, let c, self.connection === c else { return }
                    switch state {
                    case .ready:
                        c.send(content: DisplayConfig.hello, completion: .contentProcessed { [weak self, weak c] error in
                            guard let self, let c, self.connection === c else { return }
                            if let error { self.fail(c, error.localizedDescription); return }
                            self.report("CONNECTED • WAITING FOR NATIVE FRAME")
                            self.receivePacket(on: c)
                        })
                    case .failed(let error): self.fail(c, error.localizedDescription)
                    default: break
                    }
                }
                c.start(queue: self.queue)
            }
            l.start(queue: queue)
        } catch { report("CREATE FAILED • \(error.localizedDescription)") }
    }
    func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.connection?.cancel(); self.connection = nil
            self.listener?.cancel(); self.listener = nil
            self.frameStore.reset()
            self.startOnQueue()
        }
    }
    private func fail(_ c: NWConnection, _ message: String) {
        guard connection === c else { return }
        c.cancel(); connection = nil
        frameStore.reset()
        report("DISCONNECTED • \(message)")
    }
    private func reportFrame(on c: NWConnection, sequence: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        let stats = frameStore.statistics()
        let seconds = Double(now - lastStatsTime) / 1_000_000_000
        guard seconds >= 1 || stats.received == 1 else { return }
        let interval = max(seconds, 0.001)
        let rx = Double(stats.received - lastReceived) / interval
        let shown = Double(stats.presented - lastPresented) / interval
        report(String(format: "LIVE v3 • RX %.1f fps • shown %.1f fps • 10-bit P3", rx, shown))
        lastStatsTime = now; lastReceived = stats.received; lastPresented = stats.presented
        var data = Data("IPD71STA".utf8)
        for value in [sequence, stats.received, stats.presented] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        c.send(content: data, completion: .contentProcessed { [weak self, weak c] error in
            guard let self, let c, self.connection === c else { return }
            if let error { self.fail(c, error.localizedDescription) }
        })
    }
    private func receiveExact(_ count: Int, on c: NWConnection, completion: @escaping (Data) -> Void) {
        var buffer = Data(); buffer.reserveCapacity(count)
        func step() {
            guard connection === c else { return }
            c.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { [weak self] data, _, complete, error in
                guard let self, self.connection === c else { return }
                if let data { buffer.append(data) }
                if let error { self.fail(c, error.localizedDescription); return }
                if buffer.count == count { completion(buffer) }
                else if complete { self.fail(c, "USB closed") }
                else { step() }
            }
        }
        step()
    }
    private func receivePacket(on c: NWConnection) {
        receiveExact(32, on: c) { [weak self] h in
            guard let self, self.connection === c else { return }
            guard h.prefix(8) == Data(DisplayConfig.magic.utf8), h.u64LE(at: 24) == 0 else {
                self.fail(c, "Native protocol mismatch"); return
            }
            let type = h.u32LE(at: 8)
            let payloadSize = Int(h.u32LE(at: 12))
            let sequence = h.u64LE(at: 16)
            if type == 1 {
                guard payloadSize >= 20, payloadSize <= 16 + DisplayConfig.tileSize * DisplayConfig.tileSize * 4 else {
                    self.fail(c, "Invalid tile size"); return
                }
                self.receiveExact(16, on: c) { [weak self] th in
                    guard let self, self.connection === c else { return }
                    let x = Int(th.u16LE(at: 0)), y = Int(th.u16LE(at: 2))
                    let w = Int(th.u16LE(at: 4)), h = Int(th.u16LE(at: 6))
                    let bytes = Int(th.u32LE(at: 8)), size = DisplayConfig.tileSize
                    guard x < DisplayConfig.width, y < DisplayConfig.height,
                          x % size == 0, y % size == 0,
                          w == min(size, DisplayConfig.width - x), h == min(size, DisplayConfig.height - y),
                          bytes == w * h * 4, payloadSize == 16 + bytes, th.u32LE(at: 12) == 0 else {
                        self.fail(c, "Invalid native tile bounds"); return
                    }
                    self.receiveExact(bytes, on: c) { [weak self] pixels in
                        guard let self, self.connection === c else { return }
                        guard self.frameStore.receive(tile: RawTileUpdate(batchID: sequence, x: x, y: y, width: w, height: h, payload: pixels)) else {
                            self.fail(c, "Invalid tile batch"); return
                        }
                        self.receivePacket(on: c)
                    }
                }
            } else if type == 4, payloadSize >= 24, payloadSize <= DisplayConfig.frameBytes + 528 {
                self.receiveExact(payloadSize, on: c) { [weak self] data in
                    guard let self, self.connection === c else { return }
                    guard let pixels = RawLossless.decode(data), self.frameStore.publish(frame: pixels, batchID: sequence) else {
                        self.fail(c, "Invalid lossless frame"); return
                    }
                    self.reportFrame(on: c, sequence: sequence)
                    self.receivePacket(on: c)
                }
            } else if type == 3, payloadSize == DisplayConfig.frameBytes {
                self.receiveExact(payloadSize, on: c) { [weak self] pixels in
                    guard let self, self.connection === c else { return }
                    guard self.frameStore.publish(frame: pixels, batchID: sequence) else {
                        self.fail(c, "Invalid full frame"); return
                    }
                    self.reportFrame(on: c, sequence: sequence)
                    self.receivePacket(on: c)
                }
            } else if type == 2, payloadSize == 0 {
                guard self.frameStore.commit(batchID: sequence) else { self.fail(c, "Incomplete native frame"); return }
                self.reportFrame(on: c, sequence: sequence)
                self.receivePacket(on: c)
            } else { self.fail(c, "Invalid packet type") }
        }
    }
}
extension Data {
    func u16LE(at o: Int) -> UInt16 { UInt16(self[o]) | (UInt16(self[o+1]) << 8) }
    func u32LE(at o: Int) -> UInt32 { UInt32(u16LE(at: o)) | (UInt32(u16LE(at: o+2)) << 16) }
    func u64LE(at o: Int) -> UInt64 { UInt64(u32LE(at: o)) | (UInt64(u32LE(at: o+4)) << 32) }
}
