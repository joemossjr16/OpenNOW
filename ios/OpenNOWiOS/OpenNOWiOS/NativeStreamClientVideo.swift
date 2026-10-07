import CoreImage
import Foundation
import Metal

enum StreamUpscalingTarget: String, Codable, CaseIterable, Identifiable {
  case screen, oneAndHalf, double
  var id: String { rawValue }
  var label: String {
    switch self {
    case .screen: return "Screen resolution"
    case .oneAndHalf: return "1.5× stream resolution"
    case .double: return "2× stream resolution"
    }
  }
  func size(source: CGSize, screen: CGSize) -> CGSize {
    guard self != .screen else { return screen }
    let factor: CGFloat = self == .oneAndHalf ? 1.5 : 2
    return CGSize(width: (source.width * factor).rounded(), height: (source.height * factor).rounded())
  }
}

struct StreamClientVideoOptions: Codable, Equatable {
  var adaptiveHDR = false
  var upscalingTarget: StreamUpscalingTarget = .screen
  init(adaptiveHDR: Bool = false, upscalingTarget: StreamUpscalingTarget = .screen) {
    self.adaptiveHDR = adaptiveHDR
    self.upscalingTarget = upscalingTarget
  }
  private enum CodingKeys: String, CodingKey { case adaptiveHDR, upscalingTarget }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    adaptiveHDR = try values.decodeIfPresent(Bool.self, forKey: .adaptiveHDR) ?? false
    upscalingTarget = try values.decodeIfPresent(StreamUpscalingTarget.self, forKey: .upscalingTarget) ?? .screen
  }
}

/// Optional HDR policy never changes the negotiated stream profile.
enum NativeStreamClientVideoPolicy {
  static func headroom(_ value: Double) -> Float {
    Float(value.isFinite ? min(max(value, 1), 32) : 1)
  }
}

/// Compatible producer queue computes optional effects before the existing Metal 4
/// input-copy/event handoff. Producer outputs are never read by the display queue
/// directly. Serial queue ordering and three-frame admission bound slot reuse.
final class NativeStreamClientVideoProcessor {
  private struct Pipelines {
    let easu, rcas: any MTLComputePipelineState
  }
  private struct Scaling {
    let width, height, outputWidth, outputHeight: Int
    let sharpen: Bool
    let slots: [(input: any MTLTexture, scaled: any MTLTexture, sharp: (any MTLTexture)?)]
  }
  private let device: any MTLDevice
  private let setup = DispatchQueue(label: "OpenNOW.ClientVideo.setup", qos: .userInitiated)
  private var pipelines: Pipelines?
  private var scaling: Scaling?
  private var scaleIndex = 0
  private(set) var fsrStatus = "Preparing"

  private var preparationStarted = false
  init(device: any MTLDevice) { self.device = device }
  func prepareIfNeeded() {
    guard !preparationStarted else { return }
    preparationStarted = true
    let device = device
    setup.async { [weak self] in
      do {
        func library(_ name: String) throws -> any MTLLibrary {
          guard
            let url = Bundle.main.url(
              forResource: name, withExtension: "metal", subdirectory: "StreamVideo")
          else {
            throw NSError(domain: "OpenNOW.ClientVideo", code: 1)
          }
          let options = MTLCompileOptions()
          if #available(iOS 18.0, macOS 15.0, *) { options.mathMode = .safe }
          return try device.makeLibrary(
            source: String(contentsOf: url, encoding: .utf8), options: options)
        }
        let fsr = try library("FSR1")
        func pipeline(_ library: any MTLLibrary, _ name: String) throws
          -> any MTLComputePipelineState
        {
          guard let function = library.makeFunction(name: name) else {
            throw NSError(domain: "OpenNOW.ClientVideo", code: 2)
          }
          return try device.makeComputePipelineState(function: function)
        }
        let result = try Pipelines(
          easu: pipeline(fsr, "fsrEasu"), rcas: pipeline(fsr, "fsrRcas"))
        DispatchQueue.main.async { [weak self] in self?.pipelines = result }
      } catch {
        DispatchQueue.main.async { [weak self] in
          self?.fsrStatus = "Unavailable on this device"
        }
      }
    }
  }
  func resetScaling() {
    scaling = nil
    fsrStatus = "Preparing"
  }
  private func texture(_ width: Int, _ height: Int) -> (any MTLTexture)? {
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
    d.storageMode = .private
    d.usage = [.shaderRead, .shaderWrite, .renderTarget]
    return device.makeTexture(descriptor: d)
  }
  private func dispatch(
    _ pipeline: any MTLComputePipelineState, encoder: any MTLComputeCommandEncoder, width: Int,
    height: Int
  ) {
    encoder.setComputePipelineState(pipeline)
    encoder.dispatchThreads(
      MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
  }
  func upscaleFSR(
    image: CIImage, destination: CGSize, hdr: Bool, sharpness: Float,
    context: CIContext, command: any MTLCommandBuffer
  ) -> CIImage? {
    guard
      let size = StreamUpscalingMethod.fsr1.outputSize(
        source: image.extent.size, destination: destination)
    else {
      fsrStatus = "No upscale"
      return nil
    }
    guard let pipelines else { return nil }
    let w = Int(image.extent.width)
    let h = Int(image.extent.height)
    let ow = Int(size.width)
    let oh = Int(size.height)
    let sharpen = sharpness.isFinite && sharpness > 0.001
    if scaling?.width != w || scaling?.height != h || scaling?.outputWidth != ow
      || scaling?.outputHeight != oh || scaling?.sharpen != sharpen
    {
      let slots = (0..<3).compactMap {
        _ -> (input: any MTLTexture, scaled: any MTLTexture, sharp: (any MTLTexture)?)? in
        guard let input = texture(w, h), let scaled = texture(ow, oh) else { return nil }
        let sharp = sharpen ? texture(ow, oh) : nil
        if sharpen && sharp == nil { return nil }
        return (input, scaled, sharp)
      }
      guard slots.count == 3 else {
        fsrStatus = "Unavailable: allocation"
        return nil
      }
      scaling = Scaling(
        width: w, height: h, outputWidth: ow, outputHeight: oh, sharpen: sharpen, slots: slots)
    }
    guard let scaling else { return nil }
    let slot = scaling.slots[scaleIndex]
    scaleIndex = (scaleIndex + 1) % 3
    let space = NativeStreamNISKernel.colorSpace(hdr: hdr)
    context.render(
      image.transformed(
        by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)),
      to: slot.input, commandBuffer: command, bounds: CGRect(x: 0, y: 0, width: w, height: h),
      colorSpace: space)
    guard let encoder = command.makeComputeCommandEncoder() else { return nil }
    encoder.setTexture(slot.input, index: 0)
    encoder.setTexture(slot.scaled, index: 1)
    dispatch(pipelines.easu, encoder: encoder, width: ow, height: oh)
    encoder.endEncoding()
    var sharpness = sharpness.isFinite ? min(max(sharpness, 0), 1) : 0
    var output = slot.scaled
    if let sharp = slot.sharp {
      guard let encoder = command.makeComputeCommandEncoder() else { return nil }
      encoder.setTexture(slot.scaled, index: 0)
      encoder.setTexture(sharp, index: 1)
      encoder.setBytes(&sharpness, length: MemoryLayout<Float>.size, index: 0)
      dispatch(pipelines.rcas, encoder: encoder, width: ow, height: oh)
      encoder.endEncoding()
      output = sharp
    }
    command.addCompletedHandler { [scaling] _ in _ = scaling }
    fsrStatus = "\(w)×\(h) → \(ow)×\(oh)"
    return CIImage(mtlTexture: output, options: [.colorSpace: space])
  }
  static func toneMap(image: CIImage, headroom: Float) -> CIImage? {
    if #available(iOS 18.0, macOS 15.0, *), image.contentHeadroom.isFinite,
      image.contentHeadroom > 1,
      let filter = CIFilter(name: "CIToneMapHeadroom")
    {
      filter.setValue(image, forKey: kCIInputImageKey)
      filter.setValue(
        NativeStreamClientVideoPolicy.headroom(Double(headroom)), forKey: "inputTargetHeadroom")
      return filter.outputImage?.cropped(to: image.extent)
    }
    return nil
  }
}
