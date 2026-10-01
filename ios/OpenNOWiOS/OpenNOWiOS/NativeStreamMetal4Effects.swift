import Foundation
import CoreImage
import CoreVideo
import Metal
#if canImport(MetalFX)
import MetalFX
#endif

#if !targetEnvironment(simulator)
/// Metal 4 presentation and spatial upscaling for decoded and interpolated images.
/// Core Image and VTFrameProcessor currently accept only legacy command buffers.
/// Their producer signals an event; the Metal 4 consumer never waits on the CPU.
@available(iOS 26.0, macOS 26.0, *)
final class NativeStreamMetal4EffectsRenderer {
    private struct Key: Hashable {
        let width, height, outputWidth, outputHeight: Int
        let transfer: Int
        let upscale: Bool
    }
    private struct Slot {
        let allocator: any MTL4CommandAllocator
        let command: any MTL4CommandBuffer
        let arguments: any MTL4ArgumentTable
        let residency: any MTLResidencySet
        let uniforms: any MTLBuffer
        let input, output: any MTLTexture
        let scaler: (any MTL4FXSpatialScaler)?
    }
    private final class Resources {
        let slots: [Slot]
        private let lock = NSLock()
        private var available = [0,1]
        init(slots: [Slot]) { self.slots = slots }
        func take() -> Int? { lock.lock(); defer { lock.unlock() }; return available.popLast() }
        func release(_ index: Int) { lock.lock(); available.append(index); lock.unlock() }
    }
    private let device: any MTLDevice
    private let queue: any MTL4CommandQueue
    private let compiler: any MTL4Compiler
    private let sdrPipeline, hdrPipeline: any MTLRenderPipelineState
    private let producerEvent: any MTLSharedEvent
    private var producerValue: UInt64 = 0
    private let setupQueue = DispatchQueue(label: "OpenNOW.Metal4FX.setup", qos: .userInitiated)
    private var resources: [Key: Resources] = [:]
    private var preparing: Set<Key> = []
    private var rejected: Set<Key> = []
    private var order: [Key] = []
    private(set) var status = "Preparing Metal 4"
    init?(device: any MTLDevice) {
        guard NativeStreamMetal4HDRRenderer.isSupported(device: device),
              let queue = device.makeMTL4CommandQueue(), let event = device.makeSharedEvent() else { return nil }
        do {
            let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            func pipeline(_ format: MTLPixelFormat) throws -> any MTLRenderPipelineState {
                let descriptor = MTL4RenderPipelineDescriptor()
                let vertex = MTL4LibraryFunctionDescriptor(); vertex.library = library; vertex.name = "effectsVertex"
                let fragment = MTL4LibraryFunctionDescriptor(); fragment.library = library; fragment.name = "effectsFragment"
                descriptor.vertexFunctionDescriptor = vertex; descriptor.fragmentFunctionDescriptor = fragment
                descriptor.colorAttachments[0].pixelFormat = format
                return try compiler.makeRenderPipelineState(descriptor: descriptor)
            }
            sdrPipeline = try pipeline(.bgra8Unorm); hdrPipeline = try pipeline(.bgr10a2Unorm)
            self.device = device; self.queue = queue; self.compiler = compiler; producerEvent = event
        } catch { return nil }
    }
    /// Called on the display thread. False leaves the producer uncommitted for legacy fallback.
    func submit(image: CIImage, destination: CGRect, transfer: Int, upscale: Bool,
                context: CIContext, producer: any MTLCommandBuffer, target: any MTLTexture,
                drawable: (any MTLDrawable)? = nil, ticket: NativeStreamMetalFrameTimeline.Ticket? = nil,
                presented: (@Sendable (Double) -> Void)? = nil,
                completion: @escaping @Sendable (Double, NSError?) -> Void) -> Bool {
        let size = image.extent.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              transfer >= 0, transfer <= 2,
              target.pixelFormat == (transfer == 0 ? .bgra8Unorm : .bgr10a2Unorm) else { return false }
        let outputSize = upscale ? NativeStreamVideoEffectsPolicy.upscaleSize(source: size, destination: destination.size) : nil
        let key = Key(width: Int(size.width.rounded()), height: Int(size.height.rounded()),
            outputWidth: Int((outputSize?.width ?? size.width).rounded()),
            outputHeight: Int((outputSize?.height ?? size.height).rounded()), transfer: transfer, upscale: outputSize != nil)
        guard let resource = resources[key] else {
            prepare(key); status = rejected.contains(key) ? "Metal 4 unavailable for this resolution" : "Preparing Metal 4"
            return false
        }
        guard let index = resource.take() else { return false }
        let slot = resource.slots[index]
        let space = NativeStreamVideoEffectsPolicy.workingColorSpace(hdr: transfer != 0)
        let source = key.upscale ? NativeStreamVideoEffectsPolicy.spatialInput(image: image, hdr: transfer != 0) : image
        context.render(source.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)),
            to: slot.input, commandBuffer: producer,
            bounds: CGRect(x: 0, y: 0, width: key.width, height: key.height), colorSpace: space)
        producer.addCompletedHandler { [resource] _ in _ = resource }
        slot.allocator.reset(); slot.residency.removeAllAllocations()
        for texture in [slot.input, slot.output, target] { slot.residency.addAllocation(texture) }
        slot.residency.addAllocation(slot.uniforms); slot.residency.commit()
        var uniforms = SIMD4<Float>(Float(transfer), 0, 0, 0)
        withUnsafeBytes(of: &uniforms) { slot.uniforms.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        slot.arguments.setAddress(slot.uniforms.gpuAddress, index: 0)
        slot.arguments.setTexture(slot.output.gpuResourceID, index: 0)
        slot.command.beginCommandBuffer(allocator: slot.allocator); slot.command.useResidencySet(slot.residency)
        if let scaler = slot.scaler {
            scaler.colorTexture = slot.input; scaler.outputTexture = slot.output
            scaler.inputContentWidth = key.width; scaler.inputContentHeight = key.height
            scaler.encode(commandBuffer: slot.command)
        }
        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store; pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1)
        guard let encoder = slot.command.makeRenderCommandEncoder(descriptor: pass) else {
            slot.command.endCommandBuffer(); resource.release(index); return false
        }
        // Metal 4 does not infer dependencies between the scaler and fragment read.
        encoder.barrier(afterQueueStages: [.dispatch, .fragment, .vertex, .blit], beforeStages: .fragment, visibilityOptions: .device)
        encoder.setRenderPipelineState(transfer == 0 ? sdrPipeline : hdrPipeline)
        encoder.setViewport(MTLViewport(originX: destination.minX, originY: destination.minY,
            width: destination.width, height: destination.height, znear: 0, zfar: 1))
        encoder.setArgumentTable(slot.arguments, stages: .fragment)
        encoder.drawPrimitives(primitiveType: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding(); slot.command.endCommandBuffer()
        producerValue += 1
        let value = producerValue, event = producerEvent
        producer.encodeSignalEvent(event, value: value)
        // A failed producer can skip its GPU signal. Only unblock after completion;
        // report the error to the consumer completion as well as recovering the event.
        let producerFailure = ProducerFailure()
        producer.addCompletedHandler { command in
            if command.status == .error {
                producerFailure.set(command.error as NSError?)
                event.signaledValue = max(event.signaledValue, value)
            }
        }
        let options = MTL4CommitOptions()
        options.addFeedbackHandler { [resource, slot, target, drawable, producer] feedback in
            _ = (slot, target, drawable)
            let error = producerFailure.error ?? feedback.error as NSError?
            if error != nil { ticket?.recoverAfterGPUFailure() }
            resource.release(index)
            completion(max(feedback.gpuEndTime - feedback.gpuStartTime, 0) + max(producer.gpuEndTime - producer.gpuStartTime, 0), error)
        }
        if let drawable, let presented { drawable.addPresentedHandler { value in
            if value.presentedTime > 0 { presented(value.presentedTime) }
        } }
        producer.commit()
        queue.waitForEvent(event, value: value)
        if let drawable { queue.waitForDrawable(drawable) }
        queue.commit([slot.command], options: options)
        if let ticket { queue.signalEvent(ticket.event, value: ticket.value) }
        if let drawable { queue.signalDrawable(drawable); drawable.present() }
        status = key.upscale ? "Metal 4 · \(key.width)×\(key.height) → \(key.outputWidth)×\(key.outputHeight)" : "Metal 4 · presentation"
        return true
    }
    private final class ProducerFailure: @unchecked Sendable {
        private let lock = NSLock(); private var stored: NSError?
        var error: NSError? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ error: NSError?) { lock.lock(); stored = error ?? NSError(domain: "OpenNOW.Metal4Producer", code: -1); lock.unlock() }
    }
    private func prepare(_ key: Key) {
        guard !preparing.contains(key), !rejected.contains(key), preparing.count < 2 else { return }
        preparing.insert(key)
        let device = device, compiler = compiler
        setupQueue.async { [weak self] in
            var slots: [Slot] = []
            do {
                for _ in 0..<2 {
                    var scaler: (any MTL4FXSpatialScaler)?
                    if key.upscale {
                        let descriptor = MTLFXSpatialScalerDescriptor()
                        descriptor.inputWidth = key.width; descriptor.inputHeight = key.height
                        descriptor.outputWidth = key.outputWidth; descriptor.outputHeight = key.outputHeight
                        descriptor.colorTextureFormat = .rgba16Float; descriptor.outputTextureFormat = .rgba16Float
                        descriptor.colorProcessingMode = key.transfer == 0 ? .linear : .hdr
                        scaler = descriptor.makeSpatialScaler(device: device, compiler: compiler)
                        guard scaler != nil else { throw NSError(domain: "OpenNOW.Metal4FX", code: 1) }
                    }
                    func texture(_ width: Int, _ height: Int, _ usage: MTLTextureUsage) -> (any MTLTexture)? {
                        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
                        descriptor.storageMode = .private; descriptor.usage = usage.union([.shaderRead, .shaderWrite, .renderTarget])
                        return device.makeTexture(descriptor: descriptor)
                    }
                    guard let input = texture(key.width, key.height, scaler?.colorTextureUsage ?? []),
                          let output = key.upscale ? texture(key.outputWidth, key.outputHeight, scaler?.outputTextureUsage ?? []) : input,
                          let allocator = device.makeCommandAllocator(), let command = device.makeCommandBuffer(),
                          let uniforms = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
                        else { throw NSError(domain: "OpenNOW.Metal4FX", code: 2) }
                    let table = MTL4ArgumentTableDescriptor(); table.maxTextureBindCount = 1; table.maxBufferBindCount = 1
                    let residency = MTLResidencySetDescriptor(); residency.initialCapacity = 4
                    slots.append(Slot(allocator: allocator, command: command, arguments: try device.makeArgumentTable(descriptor: table),
                        residency: try device.makeResidencySet(descriptor: residency), uniforms: uniforms, input: input, output: output, scaler: scaler))
                }
            } catch { slots.removeAll() }
            let result = slots.count == 2 ? Resources(slots: slots) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.preparing.remove(key)
                if let result {
                    self.resources[key] = result; self.order.append(key)
                    // Real/generated performance images may have different sizes.
                    // Keep two configurations; in-flight completions retain evicted resources.
                    while self.order.count > 2 { self.resources.removeValue(forKey: self.order.removeFirst()) }
                } else { self.rejected.insert(key) }
            }
        }
    }
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; };
    vertex V effectsVertex(uint id [[vertex_id]]) {
        const float2 p[] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
        const float2 uv[] = {float2(0,1),float2(0,0),float2(1,1),float2(1,0)};
        return {float4(p[id],0,1),uv[id]};
    }
    fragment float4 effectsFragment(V v [[stage_in]], texture2d<float> image [[texture(0)]], constant float4 &u [[buffer(0)]]) {
        constexpr sampler s(filter::linear,address::clamp_to_edge);
        float3 rgb = max(image.sample(s,v.uv).rgb,0.0f);
        if (u.x > 0) {
            // Both PQ and HLG sources are converted by CI to linear BT.2020.
            // Normalize HDR presentation to PQ; no approximate HLG OOTF shader.
            // CI extended linear BT.2020 uses 203 nit reference white.
            float3 y = pow(rgb * 0.0203f, float3(2610.0f/16384.0f));
            rgb = pow((3424.0f/4096.0f + (2413.0f/128.0f)*y)/(1.0f+(2392.0f/128.0f)*y),float3(2523.0f/32.0f));
        } else {
            rgb = select(1.055f*pow(rgb,float3(1.0f/2.4f))-0.055f,12.92f*rgb,rgb<=0.0031308f);
        }
        return float4(rgb,1);
    }
    """
}
#else
@available(iOS 26.0, macOS 26.0, *)
final class NativeStreamMetal4EffectsRenderer {
    init?(device: any MTLDevice) { return nil }
}
#endif
