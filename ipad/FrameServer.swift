import Foundation
import Combine
@preconcurrency import Network

final class FrameServer: ObservableObject, @unchecked Sendable {
    @Published private(set) var status = "STARTING"
    let frameStore = FrameStore()
    private let queue = DispatchQueue(label:"V17.lossless.network",qos:.userInteractive)
    private let processing = DispatchQueue(label:"V17.lossless.decode",qos:.userInteractive)
    private var listener:NWListener?,connection:NWConnection?
    private var timingTimer:DispatchSourceTimer?,timingSendBusy=false
    private var lastStatsTime:UInt64=0,lastReceived:UInt64=0,lastPresented:UInt64=0
    private var timingBatch:UInt64?,readNs:UInt64=0,appendNs:UInt64=0,callbacks:UInt64=0,batchStartNs:UInt64=0
    private var jobs=0,reading=false,connectionEpoch:UInt64=0

    private func report(_ message:String){DispatchQueue.main.async{[weak self] in self?.status=message}}
    func start(){queue.async{[weak self] in self?.startOnQueue()}}
    func restart(){queue.async{[weak self] in guard let self else{return};self.timingTimer?.cancel();self.timingTimer=nil;self.connection?.cancel();self.connection=nil;self.listener?.cancel();self.listener=nil;self.frameStore.reset();self.startOnQueue()}}

    private func startOnQueue(){
        guard listener==nil else{return}
        do{
            let tcp=NWProtocolTCP.Options();tcp.noDelay=true;let params=NWParameters(tls:nil,tcp:tcp);params.allowLocalEndpointReuse=true
            let l=try NWListener(using:params,on:NWEndpoint.Port(rawValue:DisplayConfig.port)!);listener=l
            l.stateUpdateHandler={[weak self,weak l] state in guard let self,let l,self.listener===l else{return};switch state{
            case .ready:self.report("READY v17 • FP16 LOSSLESS • USB :55002")
            case .failed(let e):self.report("LISTENER FAILED • \(e.localizedDescription)")
            case .waiting(let e):self.report("WAITING • \(e.localizedDescription)")
            default:break}}
            l.newConnectionHandler={[weak self,weak l] c in
                guard let self,let l,self.listener===l else{c.cancel();return}
                self.timingTimer?.cancel();self.connection?.cancel();self.frameStore.reset();self.connection=c;self.jobs=0;self.reading=false
                self.connectionEpoch=self.frameStore.currentEpoch();self.lastStatsTime=DispatchTime.now().uptimeNanoseconds;self.lastReceived=0;self.lastPresented=0;self.timingBatch=nil;self.timingSendBusy=false
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
                timer.setEventHandler { [weak self, weak c] in
                    if let self, let c { self.flushTiming(on: c) }
                }
                self.timingTimer = timer
                timer.resume()
                c.stateUpdateHandler={[weak self,weak c] state in guard let self,let c,self.connection===c else{return};switch state{
                case .ready:c.send(content:DisplayConfig.hello,completion:.contentProcessed{[weak self,weak c] error in guard let self,let c,self.connection===c else{return};if let error{self.fail(c,error.localizedDescription);return};self.report("CONNECTED • WAITING FOR LOSSLESS FP16");self.receivePacket(on:c)})
                case .failed(let e):self.fail(c,e.localizedDescription)
                default:break}}
                c.start(queue:self.queue)
            }
            l.start(queue:queue)
        }catch{report("CREATE FAILED • \(error.localizedDescription)")}
    }
    private func fail(_ c:NWConnection,_ message:String){guard connection===c else{return};timingTimer?.cancel();timingTimer=nil;c.cancel();connection=nil;frameStore.reset();reading=false;jobs=0;report("DISCONNECTED • \(message)")}

    private func receiveExact(_ count:Int,on c:NWConnection,tracked:Bool=true,completion:@escaping(Data)->Void){
        let started=DispatchTime.now().uptimeNanoseconds;var buffer=Data();buffer.reserveCapacity(count)
        func step(){guard connection===c else{return};let remaining=count-buffer.count
            c.receive(minimumIncompleteLength:min(remaining,64*1024),maximumLength:min(remaining,4*1024*1024)){[weak self] data,_,complete,error in
                guard let self,self.connection===c else{return};let appendStart=DispatchTime.now().uptimeNanoseconds;if let data{buffer.append(data)}
                if tracked{self.appendNs &+= DispatchTime.now().uptimeNanoseconds-appendStart;self.callbacks &+= 1}
                if let error{self.fail(c,error.localizedDescription);return}
                if buffer.count==count{if tracked{self.readNs &+= DispatchTime.now().uptimeNanoseconds-started};completion(buffer)}
                else if complete{self.fail(c,"USB closed")}else{step()}
            }
        };step()
    }
    private func enqueue(_ work:FrameWork,on c:NWConnection,sequence:UInt64,completesFrame:Bool){
        let m=PacketMeasurement(sequence:sequence,startNs:batchStartNs,readNs:readNs,appendNs:appendNs,callbacks:callbacks,queuedNs:DispatchTime.now().uptimeNanoseconds),epoch=connectionEpoch,store=frameStore
        jobs += 1;reading=false
        processing.async{[weak self,weak c] in let ok=FrameWorkProcessor.apply(work,measurement:m,epoch:epoch,store:store);guard let self,let c else{return};self.queue.async{[weak self,weak c] in
            guard let self,let c,self.connection===c else{return};self.jobs -= 1;if !ok{self.fail(c,"Invalid or non-lossless frame work");return};if completesFrame{self.reportFrame(on:c,sequence:sequence)};self.receivePacket(on:c)}}
        receivePacket(on:c)
    }
    private func receivePacket(on c: NWConnection) {
        guard connection === c, !reading, jobs < 2 else { return }
        reading = true
        receiveExact(32, on: c, tracked: false) { [weak self] header in
            guard let self, self.connection === c else { return }
            guard header.prefix(8) == Data(DisplayConfig.magic.utf8), header.u64LE(at: 24) == 0 else { self.fail(c, "v17 protocol mismatch"); return }
            let type = header.u32LE(at: 8), size = Int(header.u32LE(at: 12)), sequence = header.u64LE(at: 16)
            if self.timingBatch != sequence { self.timingBatch = sequence; self.readNs = 0; self.appendNs = 0; self.callbacks = 0; self.batchStartNs = DispatchTime.now().uptimeNanoseconds }
            switch type {
            case 4, 19:
                let limit = DisplayConfig.frameBytes + DisplayConfig.frameBytes / 255 + 64
                guard size >= 17, size <= limit else { self.fail(c, "Invalid compressed frame size"); return }
                self.receiveExact(size, on: c) { [weak self] payload in guard let self, self.connection === c else { return }; self.enqueue(.full(payload, type == 19), on: c, sequence: sequence, completesFrame: true) }
            case 17:
                guard size >= 25, size <= 24 + DisplayConfig.maxCompressedTileBytes else { self.fail(c, "Invalid compressed tile size"); return }
                self.receiveExact(24, on: c) { [weak self] th in
                    guard let self, self.connection === c else { return }
                    let x = Int(th.u16LE(at: 0)), y = Int(th.u16LE(at: 2)), w = Int(th.u16LE(at: 4)), h = Int(th.u16LE(at: 6)), decoded = Int(th.u32LE(at: 8)), encoded = Int(th.u32LE(at: 12)), tile = DisplayConfig.tileSize
                    guard x < DisplayConfig.width, y < DisplayConfig.height, x % tile == 0, y % tile == 0,
                          w == min(tile, DisplayConfig.width - x), h == min(tile, DisplayConfig.height - y),
                          decoded == w * h * DisplayConfig.bytesPerPixel,
                          encoded == size - 24, th.u32LE(at: 16) == LosslessCodec.lz4Raw, th.u32LE(at: 20) == LosslessCodec.xorFlag else {
                        self.fail(c, "Invalid FP16 tile header")
                        return
                    }
                    self.receiveExact(encoded, on: c) { [weak self] data in
                        guard let self, self.connection === c else { return }
                        let tile = CompressedTileUpdate(batchID: sequence, x: x, y: y, width: w, height: h, decodedBytes: decoded, encoded: data)
                        self.enqueue(.tile(tile), on: c, sequence: sequence, completesFrame: false)
                    }
                }
            case 18:
                guard size==0 else{self.fail(c,"Invalid commit");return};self.enqueue(.commit,on:c,sequence:sequence,completesFrame:true)
            default:self.fail(c,"Uncompressed or unknown packet rejected")
            }
        }
    }
    private func reportFrame(on c:NWConnection,sequence:UInt64){
        let now=DispatchTime.now().uptimeNanoseconds,stats=frameStore.statistics(),seconds=Double(now-lastStatsTime)/1_000_000_000
        guard seconds>=1||stats.received==1 else{return};let interval=max(seconds,0.001),rx=Double(stats.received-lastReceived)/interval,shown=Double(stats.presented-lastPresented)/interval
        report(String(format:"LIVE v17 • RX %.1f fps • shown %.1f fps • FP16 BIT-EXACT LZ4",rx,shown));lastStatsTime=now;lastReceived=stats.received;lastPresented=stats.presented
        var data=Data("IPD71STA".utf8);for value in [sequence,stats.received,stats.presented]{var little=value.littleEndian;withUnsafeBytes(of:&little){data.append(contentsOf:$0)}}
        c.send(content:data,completion:.contentProcessed{[weak self,weak c] error in guard let self,let c,self.connection===c else{return};if let error{self.fail(c,error.localizedDescription)}})
    }
    private func flushTiming(on c:NWConnection){
        guard connection===c,!timingSendBusy else{return};let events=frameStore.takeTiming();guard !events.isEmpty else{return};var data=Data();data.reserveCapacity(events.count*32)
        for(sequence,metric,value) in events{data.append(contentsOf:"IPD71TIM".utf8);for word in [sequence,metric,value]{var little=word.littleEndian;withUnsafeBytes(of:&little){data.append(contentsOf:$0)}}}
        timingSendBusy=true;c.send(content:data,completion:.contentProcessed{[weak self,weak c] error in guard let self,let c,self.connection===c else{return};self.timingSendBusy=false;if let error{self.fail(c,error.localizedDescription)}})
    }
}

