import Foundation
import CoreImage
import CoreMedia
import CoreVideo
import Metal

#if canImport(MetalFX)
import MetalFX
#endif
import VideoToolbox

enum NativeStreamFrameGenerationQuality: String, Codable, CaseIterable, Identifiable {
    case performance, native
    var id: String { rawValue }
    var label: String { self == .performance ? "Performance" : "Native" }
}

struct NativeStreamFrameGenerationLimits: Equatable {
    let maximumDimension: Int
    let maximumPixels: Int
    func contains(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension else { return false }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && pixels <= maximumPixels
    }
    var label: String { "≤\(maximumDimension) px per axis, ≤\(String(format: "%.2f", Double(maximumPixels)/1_000_000)) MP" }
}

struct NativeStreamPresentationRates: Equatable {
    let generatedFPS: Double
    let displayedFPS: Double
    var label: String { String(format: "Generated %.0f FPS · Displayed %.0f FPS", generatedFPS, displayedFPS) }
}

/// Count actual drawable presentation callbacks, excluding the anchor frame from
/// each time window so decoded and generated frames are never double-counted.
struct NativeStreamPresentationRateMeter {
    private var windowStart: Double?
    private var lastTime: Double?
    private var generated = 0
    private var displayed = 0
    private var measuredAt: Double?
    private var rates: NativeStreamPresentationRates?
    mutating func observe(time: Double, generatedFrame: Bool) {
        guard time.isFinite, time > (lastTime ?? -.infinity) else { return }
        if windowStart == nil || time - (lastTime ?? time) > 3 {
            windowStart = time; lastTime = time
            generated = 0; displayed = 0; rates = nil; measuredAt = nil
            return
        }
        lastTime = time
        displayed += 1
        if generatedFrame { generated += 1 }
        let elapsed = time - windowStart!
        guard elapsed >= 1 else { return }
        rates = .init(generatedFPS: Double(generated)/elapsed, displayedFPS: Double(displayed)/elapsed)
        measuredAt = time
        windowStart = time; generated = 0; displayed = 0
    }
    func snapshot(now: Double) -> NativeStreamPresentationRates? {
        guard let measuredAt, now.isFinite, now >= measuredAt, now - measuredAt < 3 else { return nil }
        return rates
    }
}

/// Effects operate after decode. Neither feature changes the host's codec, color,
/// resolution or FPS request. In particular, frame generation cannot repair a
/// decoder that is already receiving more frames than it can process.
enum NativeStreamVideoEffectsPolicy {
    static func presentationSize(source: CGSize, display: CGSize, stretch: Bool) -> CGSize {
        guard !stretch, source.width > 0, source.height > 0 else { return display }
        let scale = min(display.width / source.width, display.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }

    static func upscaleSize(source: CGSize, destination: CGSize) -> CGSize? {
        guard source.width > 0, source.height > 0,
              destination.width > source.width * 1.02,
              destination.height > source.height * 1.02,
              destination.width <= source.width * 4,
              destination.height <= source.height * 4 else { return nil }
        return CGSize(width: destination.width.rounded(), height: destination.height.rounded())
    }

    static func frameGenerationLimits() -> NativeStreamFrameGenerationLimits {
        #if !targetEnvironment(simulator)
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *),
           let dimension = VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor: 1),
           let pixels = VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor: 1) {
            return .init(maximumDimension: dimension, maximumPixels: pixels)
        }
        #endif
        // Older OS versions cannot report these limits. Use the experimentally
        // validated 1080p ceiling rather than presenting unwritten buffers.
        return .init(maximumDimension: 1920, maximumPixels: 1920 * 1080)
    }

    static func interpolationSize(source: CGSize, quality: NativeStreamFrameGenerationQuality) -> CGSize {
        guard quality == .performance, source.width > 0, source.height > 0 else { return source }
        let scale = min(1, 960 / max(source.width, source.height), sqrt(518400 / (source.width * source.height)))
        guard scale < 1 else { return source }
        return CGSize(width: max(2, floor(source.width * scale / 2) * 2),
                      height: max(2, floor(source.height * scale / 2) * 2))
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
    static func interpolationFormat(source: OSType, supported: [OSType], hdr: Bool = false) -> OSType? {
        if supported.contains(source) { return source }
        // Full/video range are compatible 8-bit 4:2:0 layouts, not a chroma or
        // depth downgrade. Apple's video processor may advertise only 420v.
        if source == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
           supported.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        return supported.contains(kCVPixelFormatType_64RGBAHalf) ? kCVPixelFormatType_64RGBAHalf : nil
    }

    /// Sharpening can overshoot below zero or above SDR white. MetalFX linear
    /// input is defined only in [0,1]; invalid values can produce NaN output.
    /// HDR retains its half-float range and highlights rather than clipping to SDR.
    static func spatialInput(image: CIImage, hdr: Bool) -> CIImage {
        image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: hdr ? 65504 : 1, y: hdr ? 65504 : 1, z: hdr ? 65504 : 1, w: 1)
        ]).cropped(to: image.extent)
    }

    static func workingColorSpace(hdr: Bool) -> CGColorSpace {
        CGColorSpace(name: hdr ? CGColorSpace.extendedLinearITUR_2020 : CGColorSpace.extendedLinearSRGB)!
    }
}

/// A few initial submissions may compile ML/render pipelines. Judge sustained
/// completion cost after warm-up, without repeatedly unloading the ML session.
struct NativeStreamFrameGenerationBudget {
    private var warmupRemaining = 8
    private var recent: [Bool] = []
    private(set) var averageSeconds: Double = 0
    private var durations: [Double] = []

    mutating func record(processingSeconds: Double, displayHz: Int) -> Bool {
        guard processingSeconds.isFinite, processingSeconds >= 0, displayHz > 0 else { return false }
        if warmupRemaining > 0 { warmupRemaining -= 1; return false }
        recent.append(processingSeconds > 1.0 / Double(displayHz))
        durations.append(processingSeconds)
        if recent.count > 12 { recent.removeFirst(); durations.removeFirst() }
        averageSeconds = durations.reduce(0, +) / Double(durations.count)
        return recent.count == 12 && recent.filter { $0 }.count >= 9 && averageSeconds > 1.0 / Double(displayHz)
    }

    mutating func reset(warmingUp: Bool = true) {
        warmupRemaining = warmingUp ? 8 : 0
        recent.removeAll(keepingCapacity: true)
        durations.removeAll(keepingCapacity: true)
        averageSeconds = 0
    }
}

/// GPU-only range conversion and optional resizing for 8-bit NV12. Retains
/// 4:2:0 layout, matrix, primaries and transfer function; no RGB round-trip or CPU wait.
final class NativeStreamNV12RangeBridge {
    private let pipeline: any MTLComputePipelineState
    init?(device: any MTLDevice) {
        do {
            let library = try device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            kernel void nv12Range(texture2d<float,access::sample> input [[texture(0)]],
                                  texture2d<float,access::write> output [[texture(1)]],
                                  constant float2 &scaleOffset [[buffer(0)]],
                                  uint2 p [[thread_position_in_grid]]) {
                if (p.x >= output.get_width() || p.y >= output.get_height()) return;
                constexpr sampler bilinear(coord::normalized,address::clamp_to_edge,filter::linear);
                float2 uv = (float2(p)+0.5f)/float2(output.get_width(),output.get_height());
                float4 value = input.sample(bilinear,uv);
                output.write(float4(clamp(value.rg * scaleOffset.x + scaleOffset.y, 0.0f, 1.0f),0,1),p);
            }
            """, options: nil)
            guard let function = library.makeFunction(name: "nv12Range") else { return nil }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch { return nil }
    }

    func encode(source: CVPixelBuffer, destination: CVPixelBuffer,
                cache: CVMetalTextureCache, commandBuffer: any MTLCommandBuffer) -> Bool {
        let sourceFormat = CVPixelBufferGetPixelFormatType(source), destinationFormat = CVPixelBufferGetPixelFormatType(destination)
        let formats = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        guard formats.contains(sourceFormat), formats.contains(destinationFormat),
              CVPixelBufferGetPlaneCount(source) == 2, CVPixelBufferGetPlaneCount(destination) == 2 else { return false }
        let sourceFull = sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let destinationFull = destinationFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        var references: [CVMetalTexture] = []
        var pairs: [(any MTLTexture, any MTLTexture)] = []
        for plane in 0..<2 {
            let sourceWidth = CVPixelBufferGetWidthOfPlane(source, plane), sourceHeight = CVPixelBufferGetHeightOfPlane(source, plane)
            let width = CVPixelBufferGetWidthOfPlane(destination, plane), height = CVPixelBufferGetHeightOfPlane(destination, plane)
            guard width > 0, height > 0, width <= sourceWidth, height <= sourceHeight else { return false }
            var input: CVMetalTexture?, output: CVMetalTexture?
            let format: MTLPixelFormat = plane == 0 ? .r8Unorm : .rg8Unorm
            let readUsage = [kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)] as CFDictionary
            let writeUsage = [kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage.shaderWrite.rawValue)] as CFDictionary
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, source, readUsage, format, sourceWidth, sourceHeight, plane, &input) == kCVReturnSuccess,
                  CVMetalTextureCacheCreateTextureFromImage(nil, cache, destination, writeUsage, format, width, height, plane, &output) == kCVReturnSuccess,
                  let input, let output, let inputTexture = CVMetalTextureGetTexture(input),
                  let outputTexture = CVMetalTextureGetTexture(output) else { return false }
            references += [input, output]; pairs.append((inputTexture, outputTexture))
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        for (plane, pair) in pairs.enumerated() {
            var scaleOffset = SIMD2<Float>(1,0)
            if sourceFull && !destinationFull {
                scaleOffset = plane == 0 ? SIMD2<Float>(219.0 / 255,16.0 / 255)
                    : SIMD2<Float>(224.0 / 255,(128.0 / 255)*(1-224.0 / 255))
            } else if !sourceFull && destinationFull {
                scaleOffset = plane == 0 ? SIMD2<Float>(255.0 / 219,-16.0 / 219)
                    : SIMD2<Float>(255.0 / 224,(128.0 / 255)*(1-255.0 / 224))
            }
            encoder.setTexture(pair.0, index: 0); encoder.setTexture(pair.1, index: 1)
            encoder.setBytes(&scaleOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: pair.1.width, height: pair.1.height, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        }
        encoder.endEncoding()
        CVBufferPropagateAttachments(source, destination)
        CVBufferSetAttachment(destination, kCMFormatDescriptionExtension_FullRangeVideo, destinationFull ? kCFBooleanTrue : kCFBooleanFalse, .shouldPropagate)
        commandBuffer.addCompletedHandler { [source, destination, references] _ in _ = (source, destination, references) }
        return true
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
            status = "No upscale: \(Int(sourceSize.width))×\(Int(sourceSize.height)) → \(Int(destinationSize.width))×\(Int(destinationSize.height))"; return nil
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
        context.render(NativeStreamVideoEffectsPolicy.spatialInput(image: image, hdr: hdr), to: input, commandBuffer: commandBuffer,
                       bounds: CGRect(origin: .zero, size: sourceSize), colorSpace: space)
        resources.scaler.colorTexture = input; resources.scaler.outputTexture = output
        resources.scaler.inputContentWidth = next.width; resources.scaler.inputContentHeight = next.height
        resources.scaler.encode(commandBuffer: commandBuffer)
        // The three texture slots are reused on ONE serial GPU queue, with at most
        // two submissions in flight. Retain the scaler across settings/size changes.
        commandBuffer.addCompletedHandler { [resources] _ in _ = resources }
        status = "\(next.width)×\(next.height) → \(next.outputWidth)×\(next.outputHeight)"
        // CI already accounts for Metal texture coordinates on import. An extra
        // mirror here reverses the normal CI-to-drawable playback orientation.
        return CIImage(mtlTexture: output, options: [.colorSpace: space])
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
    private struct Key: Equatable { let width, height, sourceWidth, sourceHeight: Int; let format: OSType; let hdr: Bool; let transfer: String }
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
        let rangeBridge: NativeStreamNV12RangeBridge?
        init(processor: VTFrameProcessor, format: OSType, pool: CVPixelBufferPool,
             sourcePool: CVPixelBufferPool, textureCache: CVMetalTextureCache, rangeBridge: NativeStreamNV12RangeBridge?) {
            self.processor = processor; self.format = format; self.pool = pool
            self.sourcePool = sourcePool; self.textureCache = textureCache
            self.rangeBridge = rangeBridge
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

    func clearHistory() { previous = nil }

    func encode(buffer: CVPixelBuffer, timestamp: Int64, device: any MTLDevice,
                context: CIContext, commandBuffer: any MTLCommandBuffer,
                quality: NativeStreamFrameGenerationQuality = .native) -> CIImage? {
        #if targetEnvironment(simulator)
        status = "Requires a physical device"; return nil
        #else
        guard #available(iOS 26.0, *), VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            status = "Unavailable on this device"; return nil
        }
        let hdr = NativeStreamHDRTransfer.detect(in: buffer) != .sdr
        let sourceWidth = CVPixelBufferGetWidth(buffer), sourceHeight = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let canResize = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(format)
        let processing = NativeStreamVideoEffectsPolicy.interpolationSize(source: CGSize(width: sourceWidth,height: sourceHeight),
            quality: canResize ? quality : .native)
        let next = Key(width: Int(processing.width), height: Int(processing.height), sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                       format: format, hdr: hdr,
                       transfer: CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String ?? "")
        if next != key {
            reset(); key = next
            let limits = NativeStreamVideoEffectsPolicy.frameGenerationLimits()
            NativeStreamVideoPerformanceLog.record("frame-generation limits=\(limits.label) source=\(next.sourceWidth)x\(next.sourceHeight) processing=\(next.width)x\(next.height)")
            guard limits.contains(width: next.sourceWidth, height: next.sourceHeight),
                  limits.contains(width: next.width, height: next.height) else {
                status = "Resolution unsupported: \(limits.label)"; return nil
            }
            let token = generation
            status = "Preparing"
            setupQueue.async { [weak self] in
                var result: Session?
                var reason = "Unavailable for this resolution"
                if let config = VTLowLatencyFrameInterpolationConfiguration(frameWidth: next.width,
                    frameHeight: next.height, numberOfInterpolatedFrames: 1) {
                    let formats = config.supportedPixelFormats
                    NativeStreamVideoPerformanceLog.record("frame-generation supported-formats=\(formats.map { String(format: "%08x", $0) }.joined(separator: ",")) source=\(next.width)x\(next.height)")
                    reason = formats == [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                        ? "Requires 8-bit 4:2:0 on this device" : "Unavailable for this color format"
                    if let format = NativeStreamVideoEffectsPolicy.interpolationFormat(source: next.format, supported: formats, hdr: next.hdr) {
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
                                    sourcePool: sourcePool, textureCache: cache,
                                    rangeBridge: [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(format)
                                        && (format != next.format || next.width != next.sourceWidth || next.height != next.sourceHeight)
                                        ? NativeStreamNV12RangeBridge(device: device) : nil)
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
        if session.format != next.format || next.width != next.sourceWidth || next.height != next.sourceHeight {
            if [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(session.format) {
                guard let converted = allocate(from: session.sourcePool),
                      session.rangeBridge?.encode(source: buffer, destination: converted,
                        cache: session.textureCache, commandBuffer: commandBuffer) == true else {
                    status = "Color-range conversion unavailable"; return nil
                }
                source = converted
            } else {
            // A half-float RGB bridge preserves HDR and every chroma sample.
            // Only an 8-bit NV12 source may use the smaller processing geometry.
            guard let converted = allocate(from: session.sourcePool) else { status = "Buffer limit reached"; return nil }
            var reference: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil, session.textureCache, converted, nil,
                .rgba16Float, next.width, next.height, 0, &reference) == kCVReturnSuccess,
                  let reference, let texture = CVMetalTextureGetTexture(reference) else { return nil }
            let image = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(
                scaleX: CGFloat(next.width) / CGFloat(next.sourceWidth),
                y: CGFloat(next.height) / CGFloat(next.sourceHeight)))
            context.render(image, to: texture, commandBuffer: commandBuffer,
                bounds: CGRect(x: 0, y: 0, width: next.width, height: next.height), colorSpace: space)
            CVBufferSetAttachment(converted, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
            CVBufferSetAttachment(converted, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_Linear, .shouldPropagate)
            commandBuffer.addCompletedHandler { [reference, buffer] _ in _ = (reference, buffer) }
            source = converted
            }
        }
        let prior = previous
        previous = (source, timestamp)
        guard let prior, NativeStreamVideoEffectsPolicy.continuousPair(previous: prior.timestamp, current: timestamp),
              let output = allocate(from: session.pool) else { status = "Waiting for steady 60 FPS input"; return nil }
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
        status = "Interpolating \(next.width)×\(next.height)"
        return CIImage(cvPixelBuffer: output, options: session.format == kCVPixelFormatType_64RGBAHalf ? [.colorSpace: space] : [:])
        #endif
    }
}
