import SwiftUI
import MetalKit
import QuartzCore

struct MetalDisplayContainer: UIViewRepresentable {
    let frameStore: FrameStore
    let outputColorTag: OutputColorTag

    private func applyColorTag(to view: MTKView) {
        guard let layer = view.layer as? CAMetalLayer else { return }
        // Explicit compositor color management; SDR samples stay in [0,1].
        layer.wantsExtendedDynamicRangeContent = outputColorTag != .legacyP3
        switch outputColorTag {
        case .displayP3, .legacyP3:
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        case .rec709:
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }
    }

    func makeCoordinator() -> Renderer {
        Renderer(store: frameStore)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgr10a2Unorm
        view.preferredFramesPerSecond = DisplayConfig.refreshHz
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true

        if let layer = view.layer as? CAMetalLayer {
            layer.pixelFormat = .bgr10a2Unorm
            layer.maximumDrawableCount = 2
        }
        applyColorTag(to: view)

        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        applyColorTag(to: uiView)
        // Timed MTKView ignores setNeedsDisplay when enableSetNeedsDisplay is false.
        // Static frames must also invalidate the renderer, not only layer metadata.
        context.coordinator.requestRedraw()
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    private let store: FrameStore
    private let device: MTLDevice
    private let queue: MTLCommandQueue

    private let textures: [MTLTexture]
    private var needsRedraw = true
    private var front = 0
    private var frontPending = false
    private var frontEpoch: UInt64 = 0
    private var frontSequence: UInt64 = 0, frontReceiveStart: UInt64 = 0
    private let gpuAvailable = DispatchSemaphore(value: 1)

    private let pipeline: MTLRenderPipelineState

    init(store: FrameStore) {
        // IMPORTANT: do not touch any instance property before super.init().
        // Build everything from local constants first.
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is unavailable on this device")
        }

        guard let commandQueue = metalDevice.makeCommandQueue() else {
            fatalError("Could not create Metal command queue")
        }

        func makeTexture(device: MTLDevice) -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgr10a2Unorm,
                width: DisplayConfig.width,
                height: DisplayConfig.height,
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]

            guard let texture = device.makeTexture(descriptor: descriptor) else {
                fatalError("Could not create Metal framebuffer texture")
            }
            return texture
        }

        let texture0 = makeTexture(device: metalDevice)
        let texture1 = makeTexture(device: metalDevice)
        let blank = Data(count: DisplayConfig.frameBytes)
        blank.withUnsafeBytes { raw in
            for texture in [texture0, texture1] {
                texture.replace(region: MTLRegionMake2D(0, 0, DisplayConfig.width, DisplayConfig.height),
                                mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: DisplayConfig.rowBytes)
            }
        }

        let shaderSource = #"""
        #include <metal_stdlib>
        using namespace metal;

        struct V {
            float4 p [[position]];
            float2 uv;
        };

        vertex V vs(uint i [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
            const float2 p[4] = {
                float2(-1,-1), float2(1,-1),
                float2(-1,1),  float2(1,1)
            };
            const float2 u[4] = {
                float2(0,1), float2(1,1),
                float2(0,0), float2(1,0)
            };

            V o;
            o.p = float4(p[i] * scale, 0, 1);
            o.uv = u[i];
            return o;
        }

        fragment float4 fs(V in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(
                coord::normalized,
                address::clamp_to_edge,
                min_filter::nearest,
                mag_filter::nearest
            );
            return tex.sample(s, in.uv);
        }
        """#

        let library: MTLLibrary
        do {
            library = try metalDevice.makeLibrary(source: shaderSource, options: nil)
        } catch {
            fatalError("Metal shader compilation failed: \(error)")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "vs")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fs")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgr10a2Unorm

        let renderPipeline: MTLRenderPipelineState
        do {
            renderPipeline = try metalDevice.makeRenderPipelineState(
                descriptor: pipelineDescriptor
            )
        } catch {
            fatalError("Metal pipeline creation failed: \(error)")
        }

        // Assign all stored properties using locals only.
        self.store = store
        self.device = metalDevice
        self.queue = commandQueue
        self.textures = [texture0, texture1]
        self.pipeline = renderPipeline

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsRedraw = true }

    func requestRedraw() { needsRedraw = true }

    func draw(in view: MTKView) {
        guard gpuAvailable.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { gpuAvailable.signal() } }
        if let snapshot = store.consumeFrame() {
            needsRedraw = true
            let uploadStart = DispatchTime.now().uptimeNanoseconds
            if snapshot.countable { store.timing(snapshot.sequence, 5, uploadStart - snapshot.readyNs, epoch: snapshot.epoch) }
            let frame = snapshot.data
            let next = 1 - front

            frame.withUnsafeBytes { raw in
                if let p = raw.baseAddress {
                    textures[next].replace(
                        region: MTLRegionMake2D(0,0,DisplayConfig.width,DisplayConfig.height),
                        mipmapLevel: 0,
                        withBytes: p,
                        bytesPerRow: DisplayConfig.width*4
                    )
                }
            }

            if snapshot.countable { store.timing(snapshot.sequence, 6, DispatchTime.now().uptimeNanoseconds - uploadStart, epoch: snapshot.epoch) }
            frontSequence = snapshot.sequence; frontReceiveStart = snapshot.receiveStartNs
            front = next
            frontEpoch = snapshot.epoch
            frontPending = snapshot.countable
        }

        guard needsRedraw || frontPending else { return }
        let renderStart = DispatchTime.now().uptimeNanoseconds
        guard
            let rp = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let cb = queue.makeCommandBuffer(),
            let enc = cb.makeRenderCommandEncoder(descriptor: rp)
        else { return }

        let srcAspect = Float(DisplayConfig.width) / Float(DisplayConfig.height)
        let dstAspect = Float(drawable.texture.width) / Float(drawable.texture.height)

        var scale = SIMD2<Float>(1,1)
        if dstAspect > srcAspect {
            scale.x = srcAspect / dstAspect
        } else {
            scale.y = dstAspect / srcAspect
        }

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(
            &scale,
            length: MemoryLayout<SIMD2<Float>>.stride,
            index: 0
        )
        enc.setFragmentTexture(textures[front], index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        if frontPending {
            let frameEpoch = frontEpoch
            let frameStore = store
            let sequence = frontSequence, receiveStart = frontReceiveStart
            let submitNs = DispatchTime.now().uptimeNanoseconds
            frameStore.timing(sequence, 7, submitNs - renderStart, epoch: frameEpoch)
            drawable.addPresentedHandler { _ in
                let now = DispatchTime.now().uptimeNanoseconds
                frameStore.didPresent(epoch: frameEpoch)
                frameStore.timing(sequence, 8, now - submitNs, epoch: frameEpoch)
                if receiveStart > 0 { frameStore.timing(sequence, 10, now - receiveStart, epoch: frameEpoch) }
            }
            cb.addCompletedHandler { command in
                let seconds = command.gpuEndTime - command.gpuStartTime
                if seconds >= 0 && seconds.isFinite { frameStore.timing(sequence, 9, UInt64(seconds * 1_000_000_000), epoch: frameEpoch) }
            }
            frontPending = false
        }
        cb.present(drawable)
        let gate = gpuAvailable
        cb.addCompletedHandler { _ in gate.signal() }
        submitted = true
        cb.commit()
        needsRedraw = false
    }
}

// Runs the production fragment shader into a 10-bit target, then checks the stored
// bytes. This tests GPU packing and sampling, not the physical panel/compositor.
extension Renderer {
    func verifyTenBitShader() -> String {
        let width = 1024
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgr10a2Unorm,
                                                         width: width, height: 1, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead, .renderTarget]
        guard let input = device.makeTexture(descriptor: d),
              let output = device.makeTexture(descriptor: d),
              let command = queue.makeCommandBuffer() else { return "GPU CHECK FAILED: allocation" }
        let expected: [UInt32] = (0..<width).map { i in
            UInt32(1023 - i) | (UInt32((i * 37) & 1023) << 10) | (UInt32(i) << 20) | 0xc0000000
        }
        expected.withUnsafeBytes { raw in
            input.replace(region: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0,
                          withBytes: raw.baseAddress!, bytesPerRow: width * 4)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = command.makeRenderCommandEncoder(descriptor: pass) else { return "GPU CHECK FAILED: encoder" }
        var scale = SIMD2<Float>(1, 1)
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        enc.setFragmentTexture(input, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { return "GPU CHECK FAILED: execution" }
        var actual = [UInt32](repeating: 0, count: width)
        actual.withUnsafeMutableBytes { raw in
            output.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, 1), mipmapLevel: 0)
        }
        let errors = zip(actual, expected).filter { $0 != $1 }.count
        return errors == 0 ? "GPU PASS: all 1024 RGB levels preserved exactly" : "GPU FAIL: \(errors)/1024 packed pixels differ"
    }
}

private enum ColorReferencePattern {
    // All reference channels use precisely the same q/1023 values as Metal.
    static let codes: [[UInt32]] = [
        [1023, 0, 0], [0, 1023, 0], [0, 0, 1023], [1023, 307, 0], [1023, 0, 614], [0, 819, 716],
        [0, 0, 0], [41, 41, 41], [188, 188, 188], [512, 512, 512], [768, 768, 768], [1023, 1023, 1023]
    ]
    static func makeStore() -> FrameStore {
        let store = FrameStore()
        var data = Data(count: DisplayConfig.frameBytes)
        data.withUnsafeMutableBytes { raw in
            let pixels = raw.bindMemory(to: UInt32.self)
            for y in 0..<DisplayConfig.height {
                for x in 0..<DisplayConfig.width {
                    let q = codes[min(1, y * 2 / DisplayConfig.height) * 6 + min(5, x * 6 / DisplayConfig.width)]
                    pixels[y * DisplayConfig.width + x] = q[2] | (q[1] << 10) | (q[0] << 20) | 0xc0000000
                }
            }
        }
        _ = store.publish(frame: data, batchID: 1)
        return store
    }
}

private final class ColorReferenceModel: ObservableObject {
    let store = ColorReferencePattern.makeStore()
    @Published var gpuResult = "GPU check pending"
    func check() { gpuResult = Renderer(store: store).verifyTenBitShader() }
}

struct ColorReferenceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var reference = ColorReferenceModel()
    @State private var tag = OutputColorTag.displayP3
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Color reference • 7.4 (10)").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("Compare matching patches. This bypasses Windows and USB.")
            Picker("Metal output", selection: $tag) {
                ForEach(OutputColorTag.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            HStack(alignment: .top, spacing: 16) {
                VStack {
                    Text("Metal • BGR10A2 • \(tag.title)")
                    MetalDisplayContainer(frameStore: reference.store, outputColorTag: tag)
                        .aspectRatio(CGFloat(DisplayConfig.width) / CGFloat(DisplayConfig.height), contentMode: .fit)
                }
                VStack {
                    Text("Native Apple Display P3 reference")
                    VStack(spacing: 0) {
                        ForEach(0..<2) { row in
                            HStack(spacing: 0) {
                                ForEach(0..<6) { col in
                                    let q = ColorReferencePattern.codes[row * 6 + col]
                                    Color(.displayP3, red: Double(q[0]) / 1023,
                                          green: Double(q[1]) / 1023, blue: Double(q[2]) / 1023, opacity: 1)
                                }
                            }
                        }
                    }.aspectRatio(CGFloat(DisplayConfig.width) / CGFloat(DisplayConfig.height), contentMode: .fit)
                }
            }
            Text(reference.gpuResult).font(.system(.body, design: .monospaced))
            Text("GPU PASS verifies shader pixels only. Matching the native reference verifies the display path visually.")
                .font(.footnote)
            Spacer()
        }
        .padding(24)
        .background(Color.black)
        .foregroundStyle(.white)
        .task { reference.check() }
    }
}
