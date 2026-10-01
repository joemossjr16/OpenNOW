import Foundation
import CoreVideo
import Metal

/// Shared interpretation for rendering and actual-output status.
enum NativeStreamTenBitSurface {
    static func chroma(_ format: OSType) -> String? {
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: return "4:2:0"
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: return "4:2:2"
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: return "4:4:4"
        default: return nil
        }
    }

    static func isFullRange(_ format: OSType) -> Bool {
        [kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr10BiPlanarFullRange].contains(format)
    }

    static func preserves444(_ buffer: CVPixelBuffer) -> Bool {
        chroma(CVPixelBufferGetPixelFormatType(buffer)) == "4:4:4"
            && CVPixelBufferGetPlaneCount(buffer) == 2
            && CVPixelBufferGetWidthOfPlane(buffer, 0) == CVPixelBufferGetWidthOfPlane(buffer, 1)
            && CVPixelBufferGetHeightOfPlane(buffer, 0) == CVPixelBufferGetHeightOfPlane(buffer, 1)
    }

    static func hasValidPlanes(_ buffer: CVPixelBuffer) -> Bool {
        guard let chroma = chroma(CVPixelBufferGetPixelFormatType(buffer)),
              CVPixelBufferGetPlaneCount(buffer) == 2 else { return false }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let horizontal = chroma == "4:4:4" ? 1 : 2
        let vertical = chroma == "4:2:0" ? 2 : 1
        return width > 0 && height > 0
            && CVPixelBufferGetWidthOfPlane(buffer, 0) == width
            && CVPixelBufferGetHeightOfPlane(buffer, 0) == height
            && CVPixelBufferGetWidthOfPlane(buffer, 1) == (width + horizontal - 1) / horizontal
            && CVPixelBufferGetHeightOfPlane(buffer, 1) == (height + vertical - 1) / vertical
    }
}

/// One owner for source validation, range/matrix math and orientation in both APIs.
enum NativeStreamHDRMetalProgram {
    struct Uniforms {
        var range: SIMD4<Float>
        var coefficients: SIMD4<Float>
        var green: SIMD4<Float>
    }
    struct Input {
        let buffer: CVPixelBuffer
        let yReference, uvReference: CVMetalTexture
        let y, uv: any MTLTexture
        let uniforms: Uniforms
        init?(buffer: CVPixelBuffer, cache: CVMetalTextureCache, target: any MTLTexture, destination: CGRect) {
            let format = CVPixelBufferGetPixelFormatType(buffer)
            guard NativeStreamTenBitSurface.hasValidPlanes(buffer),
                  destination.width > 0, destination.height > 0,
                  target.pixelFormat == .bgr10a2Unorm,
                  CVBufferCopyAttachment(buffer,kCVImageBufferYCbCrMatrixKey,nil) as? String
                    == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String else { return nil }
            let transfer = CVBufferCopyAttachment(buffer,kCVImageBufferTransferFunctionKey,nil) as? String
            guard transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
                || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String else { return nil }
            var yRef: CVMetalTexture?, uvRef: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil,cache,buffer,nil,.r16Unorm,
                CVPixelBufferGetWidthOfPlane(buffer,0),CVPixelBufferGetHeightOfPlane(buffer,0),0,&yRef) == kCVReturnSuccess,
                CVMetalTextureCacheCreateTextureFromImage(nil,cache,buffer,nil,.rg16Unorm,
                CVPixelBufferGetWidthOfPlane(buffer,1),CVPixelBufferGetHeightOfPlane(buffer,1),1,&uvRef) == kCVReturnSuccess,
                let yRef, let uvRef, let y = CVMetalTextureGetTexture(yRef), let uv = CVMetalTextureGetTexture(uvRef) else { return nil }
            self.buffer = buffer; yReference = yRef; uvReference = uvRef; self.y = y; self.uv = uv
            let full = NativeStreamTenBitSurface.isFullRange(format)
            uniforms = Uniforms(range: SIMD4<Float>(full ? 0 : 64.0/1023,full ? 1 : 876.0/1023,
                512.0/1023,full ? 1 : 896.0/1023),coefficients: SIMD4<Float>(65535.0/(64*1023),1.4746,1.8814,0),
                green: SIMD4<Float>(-0.16455313,-0.57135313,0,0))
        }
    }
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    struct Uniforms { float4 range; float4 coefficients; float4 green; };
    vertex Vertex hdrVertex(uint id [[vertex_id]]) {
        const float2 positions[] = {float2(-1,1), float2(-1,-1), float2(1,1), float2(1,-1)};
        // Decoder IOSurfaces have a top-left origin. Preserve that orientation
        // on the display; an offscreen Core Image reference has a different Y axis.
        const float2 uv[] = {float2(0,0), float2(0,1), float2(1,0), float2(1,1)};
        return {float4(positions[id],0,1), uv[id]};
    }
    float3 hdrEncodedRGB(texture2d<float> y, texture2d<float> uv, float2 coordinate, constant Uniforms &u) {
        constexpr sampler sample(filter::linear, address::clamp_to_edge);
        float luma = (y.sample(sample,coordinate).r * u.coefficients.x - u.range.x) / u.range.y;
        float2 chroma = (uv.sample(sample,coordinate).rg * u.coefficients.x - u.range.z) / u.range.w;
        return float3(luma + u.coefficients.y * chroma.y,
                      luma + dot(u.green.xy,chroma),
                      luma + u.coefficients.z * chroma.x);
    }
    fragment float4 hdrFragment(Vertex v [[stage_in]],
        texture2d<float> y [[texture(0)]], texture2d<float> uv [[texture(1)]],
        constant Uniforms &u [[buffer(0)]]) {
        return float4(hdrEncodedRGB(y, uv, v.uv, u), 1);
    }
    """
}

/// Zero-copy bi-planar 10-bit YCbCr -> encoded BT.2020 RGB. The display layer
/// owns PQ/HLG conversion and EDR. Core Image handles unsupported inputs/effects.
final class NativeStreamHDRMetalRenderer {
    private let pipeline: any MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    init?(device: any MTLDevice) {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil,nil,device,nil,&cache) == kCVReturnSuccess, let cache else { return nil }
        do {
            let library = try device.makeLibrary(source: NativeStreamHDRMetalProgram.shader,options:nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name:"hdrVertex")
            descriptor.fragmentFunction = library.makeFunction(name:"hdrFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgr10a2Unorm
            pipeline = try device.makeRenderPipelineState(descriptor:descriptor); textureCache = cache
        } catch { return nil }
    }
    func encode(buffer: CVPixelBuffer, commandBuffer: any MTLCommandBuffer,
                descriptor: MTLRenderPassDescriptor, destination: CGRect) -> Bool {
        guard let target = descriptor.colorAttachments[0].texture,
              let input = NativeStreamHDRMetalProgram.Input(buffer:buffer,cache:textureCache,target:target,destination:destination),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor:descriptor) else { return false }
        var uniforms = input.uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(MTLViewport(originX:destination.minX,originY:destination.minY,
            width:destination.width,height:destination.height,znear:0,zfar:1))
        encoder.setFragmentTexture(input.y,index:0); encoder.setFragmentTexture(input.uv,index:1)
        encoder.setFragmentBytes(&uniforms,length:MemoryLayout<NativeStreamHDRMetalProgram.Uniforms>.stride,index:0)
        encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4); encoder.endEncoding()
        commandBuffer.addCompletedHandler { [input] _ in _ = input }
        return true
    }
}

/// A single GPU timeline orders legacy and Metal 4 submissions during live path
/// changes. Tickets advance only after submission succeeds. No blocking CPU waits.
final class NativeStreamMetalFrameTimeline {
    struct Ticket {
        let event: any MTLSharedEvent
        let previous, value: UInt64
        let failureLock: NSLock
        init(event: any MTLSharedEvent, previous: UInt64, value: UInt64, failureLock: NSLock = NSLock()) {
            self.event = event; self.previous = previous; self.value = value; self.failureLock = failureLock
        }
        func recoverAfterGPUFailure() {
            failureLock.lock(); defer { failureLock.unlock() }
            // Completion confirmed the failed work has ended; unblock following
            // submissions even if its encoded signal was skipped.
            event.signaledValue = max(event.signaledValue,value)
        }
    }
    private let event: any MTLSharedEvent
    private var last: UInt64 = 0
    private let failureLock = NSLock()
    init?(device: any MTLDevice) { guard let event = device.makeSharedEvent() else { return nil }; self.event = event }
    // Reserved/accepted only by the display thread, like render configuration.
    func next() -> Ticket { Ticket(event:event,previous:last,value:last+1,failureLock:failureLock) }
    func accept(_ ticket: Ticket) { precondition(ticket.previous == last); last = ticket.value }
}

#if !targetEnvironment(simulator)
/// The first Metal 4 streaming path: explicit allocators, argument tables,
/// residency, commit feedback and drawable synchronization. Two bounded slots;
/// reuse begins only after GPU feedback, retaining every IOSurface until then.
@available(iOS 26.0, macOS 26.0, *)
final class NativeStreamMetal4HDRRenderer {
    private struct Slot {
        let allocator: any MTL4CommandAllocator
        let command: any MTL4CommandBuffer
        let arguments: any MTL4ArgumentTable
        let uniforms: any MTLBuffer
        let residency: any MTLResidencySet
    }
    private let queue: any MTL4CommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let cache: CVMetalTextureCache
    private let slots: [Slot]
    private let lock = NSLock()
    private var available = [0,1]
    static func isSupported(device: any MTLDevice) -> Bool { device.supportsFamily(.metal4) }
    init?(device: any MTLDevice) {
        guard Self.isSupported(device:device), let queue = device.makeMTL4CommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil,nil,device,nil,&cache) == kCVReturnSuccess, let cache else { return nil }
        do {
            let compiler = try device.makeCompiler(descriptor:MTL4CompilerDescriptor())
            let library = try device.makeLibrary(source:NativeStreamHDRMetalProgram.shader,options:nil)
            let descriptor = MTL4RenderPipelineDescriptor()
            let vertex = MTL4LibraryFunctionDescriptor(); vertex.library = library; vertex.name = "hdrVertex"
            let fragment = MTL4LibraryFunctionDescriptor(); fragment.library = library; fragment.name = "hdrFragment"
            descriptor.vertexFunctionDescriptor = vertex; descriptor.fragmentFunctionDescriptor = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgr10a2Unorm
            pipeline = try compiler.makeRenderPipelineState(descriptor:descriptor)
            var slots: [Slot] = []
            for _ in 0..<2 {
                let table = MTL4ArgumentTableDescriptor(); table.maxBufferBindCount = 1; table.maxTextureBindCount = 2
                let residency = MTLResidencySetDescriptor(); residency.initialCapacity = 4
                guard let allocator = device.makeCommandAllocator(), let command = device.makeCommandBuffer(),
                    let uniforms = device.makeBuffer(length:MemoryLayout<NativeStreamHDRMetalProgram.Uniforms>.stride,options:.storageModeShared)
                    else { return nil }
                slots.append(Slot(allocator:allocator,command:command,arguments:try device.makeArgumentTable(descriptor:table),
                    uniforms:uniforms,residency:try device.makeResidencySet(descriptor:residency)))
            }
            self.queue = queue; self.cache = cache; self.slots = slots
        } catch { return nil }
    }
    /// Returns false before submitting any work if unsupported or busy; caller
    /// can use the unchanged legacy renderer and the same timeline ticket.
    func submit(buffer: CVPixelBuffer, target: any MTLTexture, destination: CGRect,
                drawable: (any MTLDrawable)? = nil, ticket: NativeStreamMetalFrameTimeline.Ticket? = nil,
                presented: (@Sendable (Double) -> Void)? = nil,
                completion: @escaping @Sendable (Double,NSError?) -> Void) -> Bool {
        guard let input = NativeStreamHDRMetalProgram.Input(buffer:buffer,cache:cache,target:target,destination:destination)
            else { return false }
        lock.lock(); let index = available.popLast(); lock.unlock()
        guard let index else { return false }
        let slot = slots[index]
        slot.allocator.reset()
        slot.residency.removeAllAllocations()
        for allocation in [input.y,input.uv,target] { slot.residency.addAllocation(allocation) }
        slot.residency.addAllocation(slot.uniforms); slot.residency.commit()
        var uniforms = input.uniforms
        withUnsafeBytes(of:&uniforms) { slot.uniforms.contents().copyMemory(from:$0.baseAddress!,byteCount:$0.count) }
        slot.arguments.setAddress(slot.uniforms.gpuAddress,index:0)
        slot.arguments.setTexture(input.y.gpuResourceID,index:0); slot.arguments.setTexture(input.uv.gpuResourceID,index:1)
        slot.command.beginCommandBuffer(allocator:slot.allocator)
        slot.command.useResidencySet(slot.residency)
        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store; pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1)
        guard let encoder = slot.command.makeRenderCommandEncoder(descriptor:pass) else {
            slot.command.endCommandBuffer(); release(index); return false
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(MTLViewport(originX:destination.minX,originY:destination.minY,
            width:destination.width,height:destination.height,znear:0,zfar:1))
        encoder.setArgumentTable(slot.arguments,stages:.fragment)
        encoder.drawPrimitives(primitiveType:.triangleStrip,vertexStart:0,vertexCount:4)
        encoder.endEncoding(); slot.command.endCommandBuffer()
        let options = MTL4CommitOptions()
        options.addFeedbackHandler { [self,input,slot,target,drawable] feedback in
            _ = (input,slot,target,drawable)
            let error = feedback.error as NSError?
            if error != nil { ticket?.recoverAfterGPUFailure() }
            release(index)
            completion(max(feedback.gpuEndTime-feedback.gpuStartTime,0),error)
        }
        if let ticket, ticket.previous > 0 { queue.waitForEvent(ticket.event,value:ticket.previous) }
        if let drawable {
            #if !targetEnvironment(simulator)
            if let presented { drawable.addPresentedHandler { value in
                if value.presentedTime > 0 { presented(value.presentedTime) }
            } }
            #endif
            queue.waitForDrawable(drawable)
        }
        queue.commit([slot.command],options:options)
        if let ticket { queue.signalEvent(ticket.event,value:ticket.value) }
        if let drawable { queue.signalDrawable(drawable); drawable.present() }
        return true
    }
    private func release(_ index: Int) { lock.lock(); available.append(index); lock.unlock() }
}

#else
// CoreSimulator does not expose the Metal 4 command API. Keep the legacy
// renderer testable and buildable with the simulator SDK.
@available(iOS 26.0, macOS 26.0, *)
final class NativeStreamMetal4HDRRenderer {
    static func isSupported(device: any MTLDevice) -> Bool { false }
    init?(device: any MTLDevice) { return nil }
    func submit(buffer: CVPixelBuffer, target: any MTLTexture, destination: CGRect,
                drawable: (any MTLDrawable)? = nil, ticket: NativeStreamMetalFrameTimeline.Ticket? = nil,
                presented: (@Sendable (Double) -> Void)? = nil,
                completion: @escaping @Sendable (Double,NSError?) -> Void) -> Bool { false }
}
#endif
