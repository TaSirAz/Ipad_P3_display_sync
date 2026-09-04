import SwiftUI
import MetalKit
import QuartzCore

struct MetalDisplayContainer: UIViewRepresentable {
    let frameStore: FrameStore

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
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
            layer.maximumDrawableCount = 3
        }

        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

final class Renderer: NSObject, MTKViewDelegate {
    private let store: FrameStore
    private let device: MTLDevice
    private let queue: MTLCommandQueue

    private let textures: [MTLTexture]
    private var front = 0
    private var frontPending = false
    private var frontEpoch: UInt64 = 0
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard gpuAvailable.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { gpuAvailable.signal() } }
        if let snapshot = store.consumeFrame() {
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

            front = next
            frontEpoch = snapshot.epoch
            frontPending = true
        }

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
            drawable.addPresentedHandler { _ in frameStore.didPresent(epoch: frameEpoch) }
            frontPending = false
        }
        cb.present(drawable)
        let gate = gpuAvailable
        cb.addCompletedHandler { _ in gate.signal() }
        submitted = true
        cb.commit()
    }
}
