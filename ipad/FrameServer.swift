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
    private var timingTimer: DispatchSourceTimer?
    private var timingSendBusy = false
    private var timingBatch: UInt64?
    private var readNs: UInt64 = 0, appendNs: UInt64 = 0, callbacks: UInt64 = 0
    private let processing = DispatchQueue(label: "V7.native.processing", qos: .userInteractive)
    private var probe = TransferProbe()
    private var probeMode: UInt32?
    private var jobs = 0, reading = false
    private var connectionEpoch: UInt64 = 0, batchStartNs: UInt64 = 0
    private func enqueue(_ work: FrameWork, on c: NWConnection, sequence: UInt64, completesFrame: Bool) {
        let measurement = PacketMeasurement(sequence: sequence, startNs: batchStartNs, readNs: readNs, appendNs: appendNs, callbacks: callbacks, queuedNs: DispatchTime.now().uptimeNanoseconds)
        let epoch = connectionEpoch, store = frameStore
        jobs += 1; reading = false
        processing.async { [weak self, weak c] in
            let ok = FrameWorkProcessor.apply(work, measurement: measurement, epoch: epoch, store: store)
            guard let self, let c else { return }
            self.queue.async { [weak self, weak c] in
                guard let self, let c, self.connection === c else { return }
                self.jobs -= 1
                if !ok { self.fail(c, "Invalid ordered frame work"); return }
                if completesFrame { self.reportFrame(on: c, sequence: sequence) }
                self.receivePacket(on: c)
            }
        }
        receivePacket(on: c)
    }
    private func flushTiming(on c: NWConnection) {
        guard connection === c, !timingSendBusy else { return }
        let events = frameStore.takeTiming()
        guard !events.isEmpty else { return }
        var data = Data(); data.reserveCapacity(events.count * 32)
        for (sequence, metric, value) in events {
            data.append(contentsOf: "IPD71TIM".utf8)
            for word in [sequence, metric, value] { var little = word.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        }
        timingSendBusy = true
        c.send(content: data, completion: .contentProcessed { [weak self, weak c] error in
            guard let self, let c, self.connection === c else { return }
            self.timingSendBusy = false
            if let error { self.fail(c, error.localizedDescription) }
        })
    }
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
                case .ready: self.report("READY v6 COLOR CHECK 7.4 • NATIVE 2360×1640 • USB :55001")
                case .failed(let e): self.report("LISTENER FAILED • \(e.localizedDescription)")
                case .waiting(let e): self.report("WAITING • \(e.localizedDescription)")
                default: break
                }
            }
            l.newConnectionHandler = { [weak self, weak l] c in
                guard let self, let l, self.listener === l else { c.cancel(); return }
                self.timingTimer?.cancel(); self.timingTimer = nil
                self.connection?.cancel()
                self.frameStore.reset()
                self.connection = c
                self.probe = TransferProbe(); self.probeMode = nil
                self.jobs = 0; self.reading = false; self.connectionEpoch = self.frameStore.currentEpoch()
                self.lastStatsTime = DispatchTime.now().uptimeNanoseconds
                self.lastReceived = 0; self.lastPresented = 0; self.timingBatch = nil; self.timingSendBusy = false
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
                timer.setEventHandler { [weak self, weak c] in if let self, let c { self.flushTiming(on: c) } }
                self.timingTimer = timer; timer.resume()
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
            self.timingTimer?.cancel(); self.timingTimer = nil
            self.connection?.cancel(); self.connection = nil
            self.listener?.cancel(); self.listener = nil
            self.frameStore.reset()
            self.startOnQueue()
        }
    }
    private func fail(_ c: NWConnection, _ message: String) {
        guard connection === c else { return }
        timingTimer?.cancel(); timingTimer = nil
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
        report(String(format: "LIVE v6 COLOR CHECK 7.4 • RX %.1f fps • shown %.1f fps • 10-bit lossless", rx, shown))
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
    private func receiveExact(_ count: Int, on c: NWConnection, tracked: Bool = true, completion: @escaping (Data) -> Void) {
        let readStart = DispatchTime.now().uptimeNanoseconds
        var buffer = Data(); buffer.reserveCapacity(count)
        func step() {
            guard connection === c else { return }
            c.receive(minimumIncompleteLength: min(count - buffer.count, 64 * 1024), maximumLength: min(count - buffer.count, 1024 * 1024)) { [weak self] data, _, complete, error in
                guard let self, self.connection === c else { return }
                let appendStart = DispatchTime.now().uptimeNanoseconds
                if let data { buffer.append(data) }
                if tracked { self.appendNs &+= DispatchTime.now().uptimeNanoseconds - appendStart; self.callbacks &+= 1 }
                if let error { self.fail(c, error.localizedDescription); return }
                if buffer.count == count { if tracked { self.readNs &+= DispatchTime.now().uptimeNanoseconds - readStart }; completion(buffer) }
                else if complete { self.fail(c, "USB closed") }
                else { step() }
            }
        }
        step()
    }

    // Type 5 discards each network chunk immediately: no full-frame Data or decoding.
    private func receiveDiscard(_ count: Int, on c: NWConnection, completion: @escaping () -> Void) {
        var remaining = count
        func step() {
            guard connection === c else { return }
            c.receive(minimumIncompleteLength: min(remaining, 64 * 1024),
                      maximumLength: min(remaining, 1024 * 1024)) { [weak self] data, _, complete, error in
                guard let self, self.connection === c else { return }
                let got = data?.count ?? 0
                guard got <= remaining else { self.fail(c, "Invalid benchmark chunk"); return }
                remaining -= got
                self.probe.received(got, now: DispatchTime.now().uptimeNanoseconds)
                if let error { self.fail(c, error.localizedDescription); return }
                if remaining == 0 { completion() }
                else if complete { self.fail(c, "USB closed during speed test") }
                else { step() }
            }
        }
        step()
    }
    private func reportProbe(on c: NWConnection, sequence: UInt64) {
        let bytes = probe.bytes, elapsed = probe.elapsedNs
        var data = Data("IPD71BEN".utf8)
        for value in [sequence, bytes, elapsed] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        probe = TransferProbe()
        // This ACK means all preceding payload bytes actually reached the iPad.
        c.send(content: data, completion: .contentProcessed { [weak self, weak c] error in
            guard let self, let c, self.connection === c else { return }
            if let error { self.fail(c, error.localizedDescription) }
        })
        reading = false
        receivePacket(on: c)
    }

    private func receivePacket(on c: NWConnection) {
        guard connection === c, !reading, jobs < 2 else { return }
        reading = true
        receiveExact(32, on: c, tracked: false) { [weak self] h in
            guard let self, self.connection === c else { return }
            guard h.prefix(8) == Data(DisplayConfig.magic.utf8), h.u64LE(at: 24) == 0 else {
                self.fail(c, "Native protocol mismatch"); return
            }
            let type = h.u32LE(at: 8)
            let payloadSize = Int(h.u32LE(at: 12))
            let sequence = h.u64LE(at: 16)
            if self.timingBatch != sequence {
                self.timingBatch = sequence; self.readNs = 0; self.appendNs = 0; self.callbacks = 0
                self.batchStartNs = DispatchTime.now().uptimeNanoseconds
            }
            if TransferProbe.accepts(type: type, size: payloadSize) {
                self.probe.begin(now: DispatchTime.now().uptimeNanoseconds)
                if self.probeMode != type {
                    self.probeMode = type
                    self.report(type == 5 ? "USB SPEED TEST • RECEIVE ONLY" : "USB SPEED TEST • RECEIVE + ASSEMBLE")
                }
                if type == 5 {
                    self.receiveDiscard(payloadSize, on: c) { [weak self] in
                        guard let self, self.connection === c else { return }
                        self.reading = false; self.receivePacket(on: c)
                    }
                } else {
                    self.receiveExact(payloadSize, on: c, tracked: false) { [weak self] data in
                        guard let self, self.connection === c else { return }
                        self.probe.received(data.count, now: DispatchTime.now().uptimeNanoseconds)
                        self.reading = false; self.receivePacket(on: c)
                    }
                }
            } else if type == 6, payloadSize == 0 {
                self.reportProbe(on: c, sequence: sequence)
            } else if type == 1 {
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
                        self.enqueue(.tile(RawTileUpdate(batchID: sequence, x: x, y: y, width: w, height: h, payload: pixels)), on: c, sequence: sequence, completesFrame: false)
                    }
                }
            } else if type == 4, payloadSize >= 24, payloadSize <= DisplayConfig.frameBytes + 528 {
                self.probe.begin(now: DispatchTime.now().uptimeNanoseconds)
                self.receiveExact(payloadSize, on: c) { [weak self] data in
                    guard let self, self.connection === c else { return }
                    self.probe.received(data.count, now: DispatchTime.now().uptimeNanoseconds)
                    self.enqueue(.lossless(data), on: c, sequence: sequence, completesFrame: true)
                }
            } else if type == 3, payloadSize == DisplayConfig.frameBytes {
                self.probe.begin(now: DispatchTime.now().uptimeNanoseconds)
                self.receiveExact(payloadSize, on: c) { [weak self] pixels in
                    guard let self, self.connection === c else { return }
                    self.probe.received(pixels.count, now: DispatchTime.now().uptimeNanoseconds)
                    self.enqueue(.full(pixels), on: c, sequence: sequence, completesFrame: true)
                }
            } else if type == 2, payloadSize == 0 {
                self.enqueue(.commit, on: c, sequence: sequence, completesFrame: true)
            } else { self.fail(c, "Invalid packet type") }
        }
    }
}
extension Data {
    func u16LE(at o: Int) -> UInt16 { UInt16(self[o]) | (UInt16(self[o+1]) << 8) }
    func u32LE(at o: Int) -> UInt32 { UInt32(u16LE(at: o)) | (UInt32(u16LE(at: o+2)) << 16) }
    func u64LE(at o: Int) -> UInt64 { UInt64(u32LE(at: o)) | (UInt64(u32LE(at: o+4)) << 32) }
}
