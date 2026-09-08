import Foundation
import Combine
@preconcurrency import Network

final class FrameServer: ObservableObject, @unchecked Sendable {
    @Published private(set) var status = "STARTING"
    let frameStore = FrameStore()
    private let queue = DispatchQueue(label: "V17.lossless.network", qos: .userInteractive)
    private let processing = DispatchQueue(label: "V17.lossless.decode", qos: .userInteractive)
    private var listener0: NWListener?, listener1: NWListener?
    private var connection0: NWConnection?, connection1: NWConnection?
    private var reading0 = false, reading1 = false
    private var timingTimer: DispatchSourceTimer?, timingSendBusy = false
    private var lastStatsTime: UInt64 = 0, lastReceived: UInt64 = 0, lastPresented: UInt64 = 0
    private var timingBatch: UInt64?, readNs: UInt64 = 0, appendNs: UInt64 = 0, callbacks: UInt64 = 0, batchStartNs: UInt64 = 0
    private var jobs = 0, connectionEpoch: UInt64 = 0

    private struct PendingFrame {
        let sequence: UInt64
        let type: UInt32
        let totalSize: Int
        var data: Data
        var receivedBytes: Int
    }
    private var pendingFrames: [UInt64: PendingFrame] = [:]

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.status = message }
    }

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timingTimer?.cancel()
            self.timingTimer = nil
            self.connection0?.cancel()
            self.connection0 = nil
            self.connection1?.cancel()
            self.connection1 = nil
            self.listener0?.cancel()
            self.listener0 = nil
            self.listener1?.cancel()
            self.listener1 = nil
            self.frameStore.reset()
            self.pendingFrames.removeAll(keepingCapacity: true)
            self.startOnQueue()
        }
    }

    private func startOnQueue() {
        guard listener0 == nil, listener1 == nil else { return }
        startListener(port: DisplayConfig.port, isSecondary: false)
        startListener(port: DisplayConfig.secondaryPort, isSecondary: true)
    }

    private func startListener(port: UInt16, isSecondary: Bool) {
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            params.allowLocalEndpointReuse = true
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
            let l = try NWListener(using: params, on: endpointPort)
            if isSecondary { listener1 = l } else { listener0 = l }

            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self, let l, (isSecondary ? self.listener1 === l : self.listener0 === l) else { return }
                switch state {
                case .ready:
                    if !isSecondary { self.report("READY v17 • FP16 LOSSLESS • DUAL-PORT 55002+55003") }
                case .failed(let e):
                    self.report("LISTENER \(port) FAILED • \(e.localizedDescription)")
                case .waiting(let e):
                    self.report("WAITING \(port) • \(e.localizedDescription)")
                default: break
                }
            }

            l.newConnectionHandler = { [weak self, weak l] c in
                guard let self, let l, (isSecondary ? self.listener1 === l : self.listener0 === l) else {
                    c.cancel()
                    return
                }
                if isSecondary {
                    self.connection1?.cancel()
                    self.connection1 = c
                    self.reading1 = false
                } else {
                    self.timingTimer?.cancel()
                    self.connection0?.cancel()
                    self.connection1?.cancel()
                    self.connection1 = nil
                    self.frameStore.reset()
                    self.pendingFrames.removeAll(keepingCapacity: true)
                    self.connection0 = c
                    self.jobs = 0
                    self.reading0 = false
                    self.reading1 = false
                    self.connectionEpoch = self.frameStore.currentEpoch()
                    self.lastStatsTime = DispatchTime.now().uptimeNanoseconds
                    self.lastReceived = 0
                    self.lastPresented = 0
                    self.timingBatch = nil
                    self.timingSendBusy = false

                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
                    timer.setEventHandler { [weak self] in
                        self?.flushTiming()
                    }
                    self.timingTimer = timer
                    timer.resume()
                }

                c.stateUpdateHandler = { [weak self, weak c] state in
                    guard let self, let c, (isSecondary ? self.connection1 === c : self.connection0 === c) else { return }
                    switch state {
                    case .ready:
                        c.send(content: DisplayConfig.hello, completion: .contentProcessed { [weak self, weak c] error in
                            guard let self, let c, (isSecondary ? self.connection1 === c : self.connection0 === c) else { return }
                            if let error {
                                self.handleFail(c, isSecondary: isSecondary, error.localizedDescription)
                                return
                            }
                            if !isSecondary {
                                self.report("CONNECTED CH0 (55002) • WAITING FOR CH1 / FP16")
                            } else {
                                self.report("DUAL CHANNELS CONNECTED (55002+55003) • 10G DUAL-STREAM")
                            }
                            self.receivePacket(on: c, isSecondary: isSecondary)
                        })
                    case .failed(let e):
                        self.handleFail(c, isSecondary: isSecondary, e.localizedDescription)
                    default: break
                    }
                }
                c.start(queue: self.queue)
            }
            l.start(queue: queue)
        } catch {
            report("CREATE LISTENER \(port) FAILED • \(error.localizedDescription)")
        }
    }

    private func handleFail(_ c: NWConnection, isSecondary: Bool, _ message: String) {
        if isSecondary {
            guard connection1 === c else { return }
            reading1 = false
            c.cancel()
            connection1 = nil
            report("CH1 DISCONNECTED • \(message)")
        } else {
            guard connection0 === c else { return }
            timingTimer?.cancel()
            timingTimer = nil
            reading0 = false
            reading1 = false
            c.cancel()
            connection0 = nil
            connection1?.cancel()
            connection1 = nil
            frameStore.reset()
            pendingFrames.removeAll(keepingCapacity: true)
            jobs = 0
            report("DISCONNECTED • \(message)")
        }
    }

    private func receiveExact(_ count: Int, on c: NWConnection, isSecondary: Bool, tracked: Bool = true, completion: @escaping (Data) -> Void) {
        let started = DispatchTime.now().uptimeNanoseconds
        var buffer = Data()
        buffer.reserveCapacity(count)
        func step() {
            guard (isSecondary ? connection1 === c : connection0 === c) else { return }
            let remaining = count - buffer.count
            c.receive(minimumIncompleteLength: min(remaining, 64 * 1024), maximumLength: min(remaining, 4 * 1024 * 1024)) { [weak self] data, _, complete, error in
                guard let self, (isSecondary ? self.connection1 === c : self.connection0 === c) else { return }
                let appendStart = DispatchTime.now().uptimeNanoseconds
                if let data { buffer.append(data) }
                if tracked {
                    self.appendNs &+= DispatchTime.now().uptimeNanoseconds - appendStart
                    self.callbacks &+= 1
                }
                if let error {
                    self.handleFail(c, isSecondary: isSecondary, error.localizedDescription)
                    return
                }
                if buffer.count == count {
                    if tracked { self.readNs &+= DispatchTime.now().uptimeNanoseconds - started }
                    completion(buffer)
                } else if complete {
                    self.handleFail(c, isSecondary: isSecondary, "USB closed")
                } else {
                    step()
                }
            }
        }
        step()
    }

    private func pump() {
        if let c0 = connection0, !reading0, jobs < 3 { receivePacket(on: c0, isSecondary: false) }
        if let c1 = connection1, !reading1, jobs < 3 { receivePacket(on: c1, isSecondary: true) }
    }

    private func receivePacket(on c: NWConnection, isSecondary: Bool) {
        guard (isSecondary ? connection1 === c : connection0 === c),
              !(isSecondary ? reading1 : reading0),
              jobs < 3 else { return }
        if isSecondary { reading1 = true } else { reading0 = true }

        receiveExact(32, on: c, isSecondary: isSecondary, tracked: false) { [weak self] header in
            guard let self, (isSecondary ? self.connection1 === c : self.connection0 === c) else { return }
            guard header.prefix(8) == Data(DisplayConfig.magic.utf8) else {
                self.handleFail(c, isSecondary: isSecondary, "v17 magic mismatch")
                return
            }
            let type = header.u32LE(at: 8)
            let size = Int(header.u32LE(at: 12))
            let sequence = header.u64LE(at: 16)
            let offset = Int(header.u32LE(at: 24))
            let totalSize = Int(header.u32LE(at: 28))

            if self.timingBatch != sequence {
                self.timingBatch = sequence
                self.readNs = 0
                self.appendNs = 0
                self.callbacks = 0
                self.batchStartNs = DispatchTime.now().uptimeNanoseconds
            }

            switch type {
            case 4, 19:
                let limit = DisplayConfig.frameBytes + DisplayConfig.frameBytes / 255 + 64
                let effectiveTotal = (totalSize > 0) ? totalSize : size
                guard size > 0, effectiveTotal >= 17, effectiveTotal <= limit, offset >= 0, offset + size <= effectiveTotal else {
                    self.handleFail(c, isSecondary: isSecondary, "Invalid frame size or chunk bounds")
                    return
                }

                self.receiveExact(size, on: c, isSecondary: isSecondary) { [weak self] payload in
                    guard let self, (isSecondary ? self.connection1 === c : self.connection0 === c) else { return }
                    if isSecondary { self.reading1 = false } else { self.reading0 = false }

                    if effectiveTotal == size && offset == 0 {
                        self.enqueue(.full(payload, type == 19), sequence: sequence, completesFrame: true)
                        self.pump()
                    } else {
                        var pending = self.pendingFrames[sequence] ?? PendingFrame(
                            sequence: sequence,
                            type: type,
                            totalSize: effectiveTotal,
                            data: Data(count: effectiveTotal),
                            receivedBytes: 0
                        )
                        pending.data.withUnsafeMutableBytes { dst in
                            payload.withUnsafeBytes { src in
                                guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else { return }
                                dstBase.advanced(by: offset).copyMemory(from: srcBase, byteCount: size)
                            }
                        }
                        pending.receivedBytes += size

                        if pending.receivedBytes == pending.totalSize {
                            self.pendingFrames.removeValue(forKey: sequence)
                            self.enqueue(.full(pending.data, pending.type == 19), sequence: sequence, completesFrame: true)
                        } else {
                            self.pendingFrames[sequence] = pending
                        }
                        if self.pendingFrames.count > 4 {
                            let oldest = self.pendingFrames.keys.filter { $0 + 4 < sequence }
                            for k in oldest { self.pendingFrames.removeValue(forKey: k) }
                        }
                        self.pump()
                    }
                }

            case 17:
                guard size >= 25, size <= 24 + DisplayConfig.maxCompressedTileBytes else {
                    self.handleFail(c, isSecondary: isSecondary, "Invalid compressed tile size")
                    return
                }
                self.receiveExact(24, on: c, isSecondary: isSecondary) { [weak self] th in
                    guard let self, (isSecondary ? self.connection1 === c : self.connection0 === c) else { return }
                    let x = Int(th.u16LE(at: 0)), y = Int(th.u16LE(at: 2)), w = Int(th.u16LE(at: 4)), h = Int(th.u16LE(at: 6)),
                        decoded = Int(th.u32LE(at: 8)), encoded = Int(th.u32LE(at: 12)), tile = DisplayConfig.tileSize
                    guard x < DisplayConfig.width, y < DisplayConfig.height, x % tile == 0, y % tile == 0,
                          w == min(tile, DisplayConfig.width - x), h == min(tile, DisplayConfig.height - y),
                          decoded == w * h * DisplayConfig.bytesPerPixel,
                          encoded == size - 24, th.u32LE(at: 16) == LosslessCodec.lz4Raw, th.u32LE(at: 20) == LosslessCodec.xorFlag else {
                        self.handleFail(c, isSecondary: isSecondary, "Invalid FP16 tile header")
                        return
                    }
                    self.receiveExact(encoded, on: c, isSecondary: isSecondary) { [weak self] data in
                        guard let self, (isSecondary ? self.connection1 === c : self.connection0 === c) else { return }
                        if isSecondary { self.reading1 = false } else { self.reading0 = false }
                        let tileObj = CompressedTileUpdate(batchID: sequence, x: x, y: y, width: w, height: h, decodedBytes: decoded, encoded: data)
                        self.enqueue(.tile(tileObj), sequence: sequence, completesFrame: false)
                        self.pump()
                    }
                }

            case 18:
                if isSecondary { self.reading1 = false } else { self.reading0 = false }
                guard size == 0 else {
                    self.handleFail(c, isSecondary: isSecondary, "Invalid commit")
                    return
                }
                self.enqueue(.commit, sequence: sequence, completesFrame: true)
                self.pump()

            default:
                if isSecondary { self.reading1 = false } else { self.reading0 = false }
                self.handleFail(c, isSecondary: isSecondary, "Uncompressed or unknown packet rejected")
            }
        }
    }

    private func enqueue(_ work: FrameWork, sequence: UInt64, completesFrame: Bool) {
        let m = PacketMeasurement(sequence: sequence, startNs: batchStartNs, readNs: readNs, appendNs: appendNs, callbacks: callbacks, queuedNs: DispatchTime.now().uptimeNanoseconds)
        let epoch = connectionEpoch, store = frameStore
        jobs += 1
        processing.async { [weak self] in
            let ok = FrameWorkProcessor.apply(work, measurement: m, epoch: epoch, store: store)
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self else { return }
                self.jobs -= 1
                if !ok {
                    if let c0 = self.connection0 { self.handleFail(c0, isSecondary: false, "Invalid or non-lossless frame work") }
                    return
                }
                if completesFrame {
                    self.reportFrame(sequence: sequence)
                }
                self.pump()
            }
        }
    }

    private func reportFrame(sequence: UInt64) {
        guard let c = connection0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds, stats = frameStore.statistics(), seconds = Double(now - lastStatsTime) / 1_000_000_000
        guard seconds >= 1 || stats.received == 1 else { return }
        let interval = max(seconds, 0.001), rx = Double(stats.received - lastReceived) / interval, shown = Double(stats.presented - lastPresented) / interval
        let chStatus = (connection1 != nil) ? "DUAL-CH 10G" : "SINGLE-CH"
        report(String(format: "LIVE v17 • %@ • RX %.1f fps • shown %.1f fps • FP16 LZ4", chStatus, rx, shown))
        lastStatsTime = now
        lastReceived = stats.received
        lastPresented = stats.presented
        var data = Data("IPD71STA".utf8)
        for value in [sequence, stats.received, stats.presented] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        c.send(content: data, completion: .contentProcessed { [weak self, weak c] error in
            guard let self, let c, self.connection0 === c else { return }
            if let error { self.handleFail(c, isSecondary: false, error.localizedDescription) }
        })
    }

    private func flushTiming() {
        guard let c = connection0, !timingSendBusy else { return }
        let events = frameStore.takeTiming()
        guard !events.isEmpty else { return }
        var data = Data()
        data.reserveCapacity(events.count * 32)
        for (sequence, metric, value) in events {
            data.append(contentsOf: "IPD71TIM".utf8)
            for word in [sequence, metric, value] {
                var little = word.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
        }
        timingSendBusy = true
        c.send(content: data, completion: .contentProcessed { [weak self, weak c] error in
            guard let self, let c, self.connection0 === c else { return }
            self.timingSendBusy = false
            if let error { self.handleFail(c, isSecondary: false, error.localizedDescription) }
        })
    }
}

