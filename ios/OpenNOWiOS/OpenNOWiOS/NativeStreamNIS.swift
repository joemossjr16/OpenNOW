import Foundation
import CoreImage
import Metal

enum StreamUpscalingMethod: String, Codable, CaseIterable, Identifiable {
    case metalFX, nis, fsr1
    var id: String { rawValue }
    var label: String { self == .nis ? "NVIDIA Image Scaling" : self == .fsr1 ? "AMD FSR1" : "MetalFX" }
    var shortLabel: String { self == .nis ? "NIS" : self == .fsr1 ? "FSR1" : "MetalFX" }
    func outputSize(source: CGSize, destination: CGSize) -> CGSize? {
        guard self != .metalFX else {
            return NativeStreamVideoEffectsPolicy.upscaleSize(source: source, destination: destination)
        }
        guard source.width.isFinite, source.height.isFinite,
              destination.width.isFinite, destination.height.isFinite,
              source.width > 0, source.height > 0,
              source.width <= CGFloat(UInt32.max), source.height <= CGFloat(UInt32.max),
              destination.width <= CGFloat(UInt32.max), destination.height <= CGFloat(UInt32.max) else { return nil }
        let output = CGSize(width: destination.width.rounded(), height: destination.height.rounded())
        guard output.width >= source.width, output.height >= source.height,
              output.width > source.width || output.height > source.height,
              output.width <= source.width * 2, output.height <= source.height * 2 else { return nil }
        return output
    }
}

/// NIS 1.0.3 constants in the upstream 112-byte shader ABI (allocation aligned to 256).
/// Inputs are display-referred sRGB or BT.2020 PQ; sharpening is part of NVScaler.
enum NativeStreamNISConfig {
    static func words(width: Int, height: Int, outputWidth: Int, outputHeight: Int,
                      hdr: Bool, sharpness: Float) -> [UInt32]? {
        guard width > 0, height > 0, outputWidth >= width, outputHeight >= height,
              outputWidth <= Int(UInt32.max), outputHeight <= Int(UInt32.max),
              outputWidth <= width * 2, outputHeight <= height * 2 else { return nil }
        let slider = (sharpness.isFinite ? min(max(sharpness, 0), 1) : 0) - 0.5
        let maximum: Float = slider >= 0 ? 1.25 : 1.75
        let minimum: Float = slider >= 0 ? 1.25 : 1
        let limit: Float = slider >= 0 ? 1.25 : 1
        let strengthMin = max(0, 0.4 + slider * minimum * (hdr ? 1.1 : 1.2))
        let strengthMax = (hdr ? 2.2 : 1.6) + slider * maximum * 1.8
        let limitMin = max(hdr ? 0.06 : 0.1, (hdr ? 0.10 : 0.14) + slider * limit * (hdr ? 0.28 : 0.32))
        let limitMax = (hdr ? 0.6 : 0.5) + slider * limit * 0.6
        let floats: [Float] = [2 * 1127 / 1024, (hdr ? 32 : 64) / 1024,
            hdr ? 1.5 : 2, 1 / (hdr ? 3.5 : 8), 1, 1 / 255,
            hdr ? 0.35 : 0.45, 1 / (hdr ? 0.20 : 0.45),
            strengthMin, strengthMax - strengthMin, limitMin, limitMax - limitMin,
            Float(width) / Float(outputWidth), Float(height) / Float(outputHeight),
            1 / Float(outputWidth), 1 / Float(outputHeight), 1 / Float(width), 1 / Float(height)]
        return floats.map(\.bitPattern) + [0, 0, UInt32(width), UInt32(height),
            0, 0, UInt32(outputWidth), UInt32(outputHeight), 0, 0]
    }
    static func write(to buffer: any MTLBuffer, width: Int, height: Int,
                      outputWidth: Int, outputHeight: Int, hdr: Bool, sharpness: Float) {
        let words = words(width: width, height: height, outputWidth: outputWidth,
                          outputHeight: outputHeight, hdr: hdr, sharpness: sharpness)!
        words.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }
}

/// Pipeline creation runs on the renderer's background preparation queue.
/// Coefficients live in the library; constants and surfaces belong to frame slots.
final class NativeStreamNISKernel {
    let sdr, pq: any MTLComputePipelineState
    private static func checked(_ pipeline: any MTLComputePipelineState, device: any MTLDevice) throws -> any MTLComputePipelineState {
        guard pipeline.maxTotalThreadsPerThreadgroup >= threads.width,
              pipeline.staticThreadgroupMemoryLength <= device.maxThreadgroupMemoryLength else {
            throw NSError(domain: "OpenNOW.NIS", code: 3)
        }
        return pipeline
    }
    private static func library(device: any MTLDevice, hdr: Bool, source: String?) throws -> any MTLLibrary {
        let text: String
        if let source { text = source }
        else {
            guard let url = Bundle.main.url(forResource: "NIS", withExtension: "metal", subdirectory: "NIS") else {
                throw NSError(domain: "OpenNOW.NIS", code: 1)
            }
            text = try String(contentsOf: url, encoding: .utf8)
        }
        let options = MTLCompileOptions()
        options.preprocessorMacros = ["NIS_HDR_MODE": NSNumber(value: hdr ? 2 : 0)]
        if #available(iOS 18.0, macOS 15.0, *) { options.mathMode = .safe }
        return try device.makeLibrary(source: text, options: options)
    }
    init(device: any MTLDevice, source: String? = nil) throws {
        func pipeline(_ hdr: Bool) throws -> any MTLComputePipelineState {
            let library = try Self.library(device: device, hdr: hdr, source: source)
            return try Self.checked(device.makeComputePipelineState(function: library.makeFunction(name: "nisScale")!), device: device)
        }
        sdr = try pipeline(false); pq = try pipeline(true)
    }
    #if !targetEnvironment(simulator)
    @available(iOS 26.0, macOS 26.0, *)
    init(device: any MTLDevice, compiler: any MTL4Compiler, source: String? = nil) throws {
        func pipeline(_ hdr: Bool) throws -> any MTLComputePipelineState {
            let library = try Self.library(device: device, hdr: hdr, source: source)
            let descriptor = MTL4ComputePipelineDescriptor()
            let function = MTL4LibraryFunctionDescriptor()
            function.library = library; function.name = "nisScale"
            descriptor.computeFunctionDescriptor = function
            return try Self.checked(compiler.makeComputePipelineState(descriptor: descriptor), device: device)
        }
        sdr = try pipeline(false); pq = try pipeline(true)
    }
    #endif
    static func groups(width: Int, height: Int) -> MTLSize {
        MTLSize(width: (width + 31) / 32, height: (height + 15) / 16, depth: 1)
    }
    static let threads = MTLSize(width: 128, height: 1, depth: 1)
    static func colorSpace(hdr: Bool) -> CGColorSpace {
        CGColorSpace(name: hdr ? CGColorSpace.itur_2100_PQ : CGColorSpace.sRGB)!
    }
}

/// Compatible Metal path. The serial GPU queue and three-frame admission limit
/// order slot reuse; completions retain resources across settings/size changes.
final class NativeStreamNISUpscaler {
    private struct Key: Equatable { let width, height, outputWidth, outputHeight: Int; let hdr: Bool }
    private struct Slot { let input, output: any MTLTexture; let config: any MTLBuffer }
    private struct Resources { let kernel: NativeStreamNISKernel; let slots: [Slot] }
    private let device: any MTLDevice
    private let setupQueue = DispatchQueue(label: "OpenNOW.NIS.setup", qos: .userInitiated)
    private var kernel: NativeStreamNISKernel?
    private var key: Key?
    private var resources: Resources?
    private var generation = 0
    private var slot = 0
    private(set) var status = "Off"
    init(device: any MTLDevice) { self.device = device }
    func reset() { generation += 1; key = nil; resources = nil; status = "Off" }
    func encode(image: CIImage, sourceSize: CGSize, destinationSize: CGSize, hdr: Bool,
                sharpness: Float, context: CIContext, commandBuffer: any MTLCommandBuffer) -> CIImage? {
        guard let size = StreamUpscalingMethod.nis.outputSize(source: sourceSize, destination: destinationSize) else {
            status = "No upscale: \(Int(sourceSize.width))×\(Int(sourceSize.height)) → \(Int(destinationSize.width))×\(Int(destinationSize.height))"
            return nil
        }
        let next = Key(width: Int(sourceSize.width), height: Int(sourceSize.height),
                       outputWidth: Int(size.width), outputHeight: Int(size.height), hdr: hdr)
        if next != key {
            key = next; resources = nil; generation += 1
            let token = generation, device = device, cachedKernel = kernel
            status = "Preparing"
            setupQueue.async { [weak self] in
                var result: Resources?
                if let kernel = cachedKernel ?? (try? NativeStreamNISKernel(device: device)) {
                    func texture(_ width: Int, _ height: Int) -> (any MTLTexture)? {
                        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
                        d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite, .renderTarget]
                        return device.makeTexture(descriptor: d)
                    }
                    let slots: [Slot] = (0..<3).compactMap { _ in
                        guard let input = texture(next.width, next.height), let output = texture(next.outputWidth, next.outputHeight),
                              let config = device.makeBuffer(length: 256, options: .storageModeShared) else { return nil }
                        return Slot(input: input, output: output, config: config)
                    }
                    if slots.count == 3 { result = Resources(kernel: kernel, slots: slots) }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.resources = result; self.kernel = result?.kernel ?? self.kernel
                    self.status = result == nil ? "Unavailable on this device" : "Ready"
                }
            }
        }
        guard let resources, let key else { return nil }
        let selected = resources.slots[slot]; slot = (slot + 1) % resources.slots.count
        let space = NativeStreamNISKernel.colorSpace(hdr: hdr)
        context.render(image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)),
                       to: selected.input, commandBuffer: commandBuffer,
                       bounds: CGRect(x: 0, y: 0, width: key.width, height: key.height), colorSpace: space)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        NativeStreamNISConfig.write(to: selected.config, width: key.width, height: key.height,
                                   outputWidth: key.outputWidth, outputHeight: key.outputHeight, hdr: hdr, sharpness: sharpness)
        encoder.setComputePipelineState(hdr ? resources.kernel.pq : resources.kernel.sdr)
        encoder.setTexture(selected.input, index: 0); encoder.setTexture(selected.output, index: 1)
        encoder.setBuffer(selected.config, offset: 0, index: 0)
        encoder.dispatchThreadgroups(NativeStreamNISKernel.groups(width: key.outputWidth, height: key.outputHeight),
                                     threadsPerThreadgroup: NativeStreamNISKernel.threads)
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { [resources] _ in _ = resources }
        status = "\(key.width)×\(key.height) → \(key.outputWidth)×\(key.outputHeight)"
        return CIImage(mtlTexture: selected.output, options: [.colorSpace: space])
    }
}
