import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import Metal

#if canImport(MetalFX)
import MetalFX
#endif
import VideoToolbox

/// Effects operate after decode. Neither feature changes the host's codec, color,
/// resolution or FPS request. In particular, frame generation cannot repair a
/// decoder that is already receiving more frames than it can process.
enum NativeStreamVideoEffectsPolicy {
    static func upscaleSize(source: CGSize, destination: CGSize) -> CGSize? {
        guard source.width > 0, source.height > 0,
              destination.width > source.width * 1.02,
              destination.height > source.height * 1.02,
              destination.width <= source.width * 4,
              destination.height <= source.height * 4 else { return nil }
        return CGSize(width: destination.width.rounded(), height: destination.height.rounded())
    }

    static func frameGenerationAllowed(sourceFPS: Int, displayHz: Int,
                                       lowPower: Bool, thermal: Int) -> Bool {
        sourceFPS == 60 && displayHz >= 120 && !lowPower && thermal < 2
    }

    static func continuousPair(previous: Int64, current: Int64) -> Bool {
        let (delta, overflow) = current.subtractingReportingOverflow(previous)
        return !overflow && delta >= 12_000_000 && delta <= 24_000_000
    }

    /// An RGB half-float bridge keeps every chroma sample and HDR precision when
    /// the processor cannot accept the decoder's native bi-planar format.
    static func interpolationFormat(source: OSType, supported: [OSType]) -> OSType? {
        if supported.contains(source) { return source }
        return supported.contains(kCVPixelFormatType_64RGBAHalf) ? kCVPixelFormatType_64RGBAHalf : nil
    }

    static func workingColorSpace(hdr: Bool) -> CGColorSpace {
        CGColorSpace(name: hdr ? CGColorSpace.extendedLinearITUR_2020 : CGColorSpace.extendedLinearSRGB)!
    }
}

/// One scaler per geometry/color configuration; model/pipeline creation stays off
/// the display thread. Main-thread access only. GPU work uses the renderer's queue.
#if canImport(MetalFX)
final class NativeStreamSpatialUpscaler {
    private struct Key: Equatable { let width, height, outputWidth, outputHeight: Int; let hdr: Bool }
    private struct Resources {
        let scaler: any MTLFXSpatialScaler
        let inputs, outputs: [any MTLTexture]
    }
    private let device: any MTLDevice
    private let setupQueue = DispatchQueue(label: "OpenNOW.MetalFX.setup", qos: .userInitiated)
    private var key: Key?
    private var resources: Resources?
    private var generation = 0
    private var slot = 0
    private(set) var status = "Off"

    init(device: any MTLDevice) { self.device = device }

    func reset() {
        generation += 1; key = nil; resources = nil; status = "Off"
    }

    func encode(image: CIImage, sourceSize: CGSize, destinationSize: CGSize, hdr: Bool,
                context: CIContext, commandBuffer: any MTLCommandBuffer) -> CIImage? {
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
            status = "Unavailable on this device"; return nil
        }
        guard let size = NativeStreamVideoEffectsPolicy.upscaleSize(source: sourceSize, destination: destinationSize) else {
            status = "Not needed at this resolution"; return nil
        }
        let next = Key(width: Int(sourceSize.width), height: Int(sourceSize.height),
                       outputWidth: Int(size.width), outputHeight: Int(size.height), hdr: hdr)
        if next != key {
            key = next; resources = nil; generation += 1
            let token = generation, device = device
            status = "Preparing"
            setupQueue.async { [weak self] in
                let descriptor = MTLFXSpatialScalerDescriptor()
                descriptor.inputWidth = next.width; descriptor.inputHeight = next.height
                descriptor.outputWidth = next.outputWidth; descriptor.outputHeight = next.outputHeight
                descriptor.colorTextureFormat = .rgba16Float; descriptor.outputTextureFormat = .rgba16Float
                descriptor.colorProcessingMode = next.hdr ? .hdr : .linear
                var result: Resources?
                if let scaler = descriptor.makeSpatialScaler(device: device) {
                    func textures(width: Int, height: Int, usage: MTLTextureUsage) -> [any MTLTexture] {
                        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                            width: width, height: height, mipmapped: false)
                        td.storageMode = .private; td.usage = usage.union([.shaderRead, .shaderWrite, .renderTarget])
                        return (0..<3).compactMap { _ in device.makeTexture(descriptor: td) }
                    }
                    let inputs = textures(width: next.width, height: next.height, usage: scaler.colorTextureUsage)
                    let outputs = textures(width: next.outputWidth, height: next.outputHeight, usage: scaler.outputTextureUsage)
                    if inputs.count == 3 && outputs.count == 3 { result = Resources(scaler: scaler, inputs: inputs, outputs: outputs) }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.resources = result
                    self.status = result == nil ? "Unavailable for this resolution" : "Ready"
                }
            }
        }
        guard let resources else { return nil }
        let input = resources.inputs[slot], output = resources.outputs[slot]
        slot = (slot + 1) % resources.inputs.count
        let space = NativeStreamVideoEffectsPolicy.workingColorSpace(hdr: hdr)
        context.render(image, to: input, commandBuffer: commandBuffer,
                       bounds: CGRect(origin: .zero, size: sourceSize), colorSpace: space)
        resources.scaler.colorTexture = input; resources.scaler.outputTexture = output
        resources.scaler.inputContentWidth = next.width; resources.scaler.inputContentHeight = next.height
        resources.scaler.encode(commandBuffer: commandBuffer)
        // The three texture slots are reused on ONE serial GPU queue, with at most
        // two submissions in flight. Retain the scaler across settings/size changes.
        commandBuffer.addCompletedHandler { [resources] _ in _ = resources }
        status = "\(next.width)×\(next.height) → \(next.outputWidth)×\(next.outputHeight)"
        // CI's bitmap/image coordinates are bottom-left; a rendered Metal texture
        // is top-left. Re-importing without this flip vertically mirrors the stream.
        return CIImage(mtlTexture: output, options: [.colorSpace: space])?.oriented(.downMirrored)
    }
}

#else
final class NativeStreamSpatialUpscaler {
    private(set) var status = "Requires a physical device"
    init(device: any MTLDevice) {}
    func reset() { status = "Off" }
    func encode(image: CIImage, sourceSize: CGSize, destinationSize: CGSize, hdr: Bool,
                context: CIContext, commandBuffer: any MTLCommandBuffer) -> CIImage? {
        status = "Requires a physical device"; return nil
    }
}
#endif

/// Apple video interpolation, rather than game-renderer interpolation with fake
/// depth. No CPU waits for ML initialization or GPU completion on the display path.
final class NativeStreamFrameGenerator {
    private let setupQueue = DispatchQueue(label: "OpenNOW.FrameGeneration.setup", qos: .userInitiated)
    private struct Key: Equatable { let width, height: Int; let format: OSType; let hdr: Bool; let transfer: String }
    private var key: Key?
    private var generation = 0
    private var previous: (buffer: CVPixelBuffer, timestamp: Int64)?
    private(set) var status = "Off"
    #if !targetEnvironment(simulator)
    @available(iOS 26.0, *)
    private final class Session {
        let processor: VTFrameProcessor
        let format: OSType
        let pool: CVPixelBufferPool
        let sourcePool: CVPixelBufferPool
        let textureCache: CVMetalTextureCache
        init(processor: VTFrameProcessor, format: OSType, pool: CVPixelBufferPool,
             sourcePool: CVPixelBufferPool, textureCache: CVMetalTextureCache) {
            self.processor = processor; self.format = format; self.pool = pool
            self.sourcePool = sourcePool; self.textureCache = textureCache
        }
        deinit { processor.endSession() }
    }
    private var sessionStorage: AnyObject?
    #endif

    func reset() {
        generation += 1; key = nil; previous = nil; status = "Off"
        #if !targetEnvironment(simulator)
        // Session deinit can wait for ML work; never release the last reference on
        // the main thread. Submitted command buffers retain their session too.
        if let old = sessionStorage {
            sessionStorage = nil
            setupQueue.async { _ = old }
        }
        #endif
    }

    func encode(buffer: CVPixelBuffer, timestamp: Int64, device: any MTLDevice,
                context: CIContext, commandBuffer: any MTLCommandBuffer) -> CIImage? {
        #if targetEnvironment(simulator)
        status = "Requires a physical device"; return nil
        #else
        guard #available(iOS 26.0, *), VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            status = "Unavailable on this device"; return nil
        }
        let hdr = NativeStreamHDRTransfer.detect(in: buffer) != .sdr
        let next = Key(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                       format: CVPixelBufferGetPixelFormatType(buffer), hdr: hdr,
                       transfer: CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String ?? "")
        if next != key {
            reset(); key = next; let token = generation
            status = "Preparing"
            setupQueue.async { [weak self] in
                var result: Session?
                var reason = "Unavailable for this resolution"
                if let config = VTLowLatencyFrameInterpolationConfiguration(frameWidth: next.width,
                    frameHeight: next.height, numberOfInterpolatedFrames: 1) {
                    let formats = config.supportedPixelFormats
                    NativeStreamVideoPerformanceLog.record("frame-generation supported-formats=\(formats.map { String(format: "%08x", $0) }.joined(separator: ",")) source=\(next.width)x\(next.height)")
                    reason = "Unavailable without changing color format"
                    if let format = NativeStreamVideoEffectsPolicy.interpolationFormat(source: next.format, supported: formats) {
                        let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: next.width,
                            kCVPixelBufferHeightKey: next.height, kCVPixelBufferPixelFormatTypeKey: format,
                            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
                        func makePool(required: [String: any Sendable]) -> CVPixelBufferPool? {
                            var resolved: CFDictionary?, pool: CVPixelBufferPool?
                            guard CVPixelBufferCreateResolvedAttributesDictionary(nil,
                                [required as NSDictionary, attributes as NSDictionary] as CFArray,
                                &resolved) == kCVReturnSuccess, let resolved,
                                CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                    resolved, &pool) == kCVReturnSuccess else { return nil }
                            return pool
                        }
                        var cache: CVMetalTextureCache?
                        let processor = VTFrameProcessor()
                        do {
                            try processor.startSession(configuration: config)
                            if let pool = makePool(required: config.destinationPixelBufferAttributes),
                               let sourcePool = makePool(required: config.sourcePixelBufferAttributes),
                               CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
                               let cache {
                                result = Session(processor: processor, format: format, pool: pool,
                                    sourcePool: sourcePool, textureCache: cache)
                            } else { processor.endSession(); reason = "Buffer allocation unavailable" }
                        } catch { reason = "Processor setup failed" }
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else {
                        self?.setupQueue.async { _ = result }; return
                    }
                    self.sessionStorage = result; self.status = result == nil ? reason : "Ready"
                }
            }
        }
        guard let session = sessionStorage as? Session else { return nil }
        func allocate(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
            var result: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &result) == kCVReturnSuccess else { return nil }
            return result
        }
        var source = buffer
        let space = NativeStreamVideoEffectsPolicy.workingColorSpace(hdr: hdr)
        if session.format != next.format {
            // Only the full-resolution half-float RGB bridge is permitted; never
            // subsample 4:4:4 or truncate HDR to satisfy processor restrictions.
            guard let converted = allocate(from: session.sourcePool) else { status = "Buffer limit reached"; return nil }
            var reference: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil, session.textureCache, converted, nil,
                .rgba16Float, next.width, next.height, 0, &reference) == kCVReturnSuccess,
                  let reference, let texture = CVMetalTextureGetTexture(reference) else { return nil }
            context.render(CIImage(cvPixelBuffer: buffer), to: texture, commandBuffer: commandBuffer,
                bounds: CGRect(x: 0, y: 0, width: next.width, height: next.height), colorSpace: space)
            CVBufferSetAttachment(converted, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
            CVBufferSetAttachment(converted, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_Linear, .shouldPropagate)
            commandBuffer.addCompletedHandler { [reference, buffer] _ in _ = (reference, buffer) }
            source = converted
        }
        let prior = previous
        previous = (source, timestamp)
        guard let prior, NativeStreamVideoEffectsPolicy.continuousPair(previous: prior.timestamp, current: timestamp),
              let output = allocate(from: session.pool) else { status = "Waiting for consecutive frames"; return nil }
        CVBufferPropagateAttachments(source, output)
        let midpoint = prior.timestamp + (timestamp - prior.timestamp) / 2
        guard let currentFrame = VTFrameProcessorFrame(buffer: source,
                presentationTimeStamp: CMTime(value: timestamp, timescale: 1_000_000_000)),
              let previousFrame = VTFrameProcessorFrame(buffer: prior.buffer,
                presentationTimeStamp: CMTime(value: prior.timestamp, timescale: 1_000_000_000)),
              let destinationFrame = VTFrameProcessorFrame(buffer: output,
                presentationTimeStamp: CMTime(value: midpoint, timescale: 1_000_000_000)),
              let parameters = VTLowLatencyFrameInterpolationParameters(sourceFrame: currentFrame,
                previousFrame: previousFrame, interpolationPhase: [0.5], destinationFrames: [destinationFrame]) else {
            status = "Frame preparation failed"; return nil
        }
        session.processor.process(with: commandBuffer, parameters: parameters)
        commandBuffer.addCompletedHandler { [session, parameters] _ in _ = (session, parameters) }
        status = "60 → 120 FPS (experimental)"
        return CIImage(cvPixelBuffer: output, options: session.format == next.format ? [:] : [.colorSpace: space])
        #endif
    }
}
