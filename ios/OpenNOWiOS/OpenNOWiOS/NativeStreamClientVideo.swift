import CoreImage
import Foundation
import Metal

enum StreamFramePacing: String, Codable, CaseIterable, Identifiable {
  case lowLatency, balanced
  var id: String { rawValue }
  var label: String { self == .balanced ? "Balanced" : "Lowest latency" }
}

struct StreamClientVideoOptions: Codable, Equatable {
  var pacing: StreamFramePacing = .lowLatency
  var interpolation = false
  var adaptiveHDR = false
}

/// Timing/eligibility has one owner; optional features never change the stream profile.
enum NativeStreamClientVideoPolicy {
  static func interpolationReason(size: CGSize, sourceFPS: Int, displayFPS: Double) -> String? {
    guard sourceFPS > 0, sourceFPS <= 60 else { return "Requires a stream at 60 FPS or below" }
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      size.width < CGFloat(Int.max - 7), size.height < CGFloat(Int.max - 7)
    else { return "Waiting for valid frame dimensions" }
    guard displayFPS.isFinite, displayFPS >= Double(sourceFPS) * 1.5 else {
      return "Display needs at least 1.5× stream FPS"
    }
    return nil
  }
  static func shouldPresentBalanced(now: Double, last: Double?, fps: Int) -> Bool {
    guard now.isFinite, let last, last.isFinite, now > last else { return true }
    return now - last >= 0.8 / Double(max(fps, 1))
  }
  static func validPair(gap: Double, fps: Int) -> Bool {
    gap.isFinite && gap > 0 && gap <= 1.5 / Double(max(fps, 1))
  }
  static func headroom(_ value: Double) -> Float {
    Float(value.isFinite ? min(max(value, 1), 32) : 1)
  }
}

/// Compatible producer queue computes optional effects before the existing Metal 4
/// input-copy/event handoff. History and outputs are never read by the display queue
/// directly. Serial queue ordering and three-frame admission bound slot reuse.
final class NativeStreamClientVideoProcessor {
  private struct Pipelines {
    let easu, rcas, flow, warp: any MTLComputePipelineState
  }
  private struct Scaling {
    let width, height, outputWidth, outputHeight: Int
    let sharpen: Bool
    let slots: [(input: any MTLTexture, scaled: any MTLTexture, sharp: (any MTLTexture)?)]
  }
  private struct History {
    let width, height: Int
    let hdr: Bool
    let images: [any MTLTexture]
    let outputs: [any MTLTexture]
    let flow: any MTLTexture
  }
  private let device: any MTLDevice
  private let setup = DispatchQueue(label: "OpenNOW.ClientVideo.setup", qos: .userInitiated)
  private var pipelines: Pipelines?
  private var scaling: Scaling?
  private var history: History?
  private var historyIndex = 0, historyCount = 0, outputIndex = 0, scaleIndex = 0
  private(set) var interpolationSuspended = false
  private(set) var interpolationStatus = "Preparing"
  private(set) var fsrStatus = "Preparing"
  var interpolationReady: Bool { historyCount >= 2 && !interpolationSuspended }

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
        let interpolation = try library("Interpolation")
        func pipeline(_ library: any MTLLibrary, _ name: String) throws
          -> any MTLComputePipelineState
        {
          guard let function = library.makeFunction(name: name) else {
            throw NSError(domain: "OpenNOW.ClientVideo", code: 2)
          }
          return try device.makeComputePipelineState(function: function)
        }
        let result = try Pipelines(
          easu: pipeline(fsr, "fsrEasu"), rcas: pipeline(fsr, "fsrRcas"),
          flow: pipeline(interpolation, "videoFlow"), warp: pipeline(interpolation, "videoWarp"))
        DispatchQueue.main.async { [weak self] in self?.pipelines = result }
      } catch {
        DispatchQueue.main.async { [weak self] in
          self?.interpolationStatus = "Unavailable on this device"
          self?.fsrStatus = "Unavailable on this device"
        }
      }
    }
  }
  func resetHistory(retry: Bool = false) {
    historyCount = 0
    if retry {
      interpolationSuspended = false
      interpolationStatus = "Warming up"
    }
  }
  func resetScaling() {
    scaling = nil
    fsrStatus = "Preparing"
  }
  func observeGPU(failed: Bool) {
    guard historyCount > 0, !interpolationSuspended else { return }
    if failed {
      interpolationSuspended = true
      resetHistory()
      interpolationStatus = "Paused: GPU error"
    }
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
  func interpolate(
    image: CIImage, newReal: Bool, phase: Float, hdr: Bool,
    context: CIContext, command: any MTLCommandBuffer
  ) -> CIImage? {
    guard let pipelines, !interpolationSuspended else { return nil }
    let size = image.extent.size
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      size.width < CGFloat(Int.max - 7), size.height < CGFloat(Int.max - 7)
    else { return nil }
    let width = Int(size.width)
    let height = Int(size.height)
    if history?.width != width || history?.height != height || history?.hdr != hdr {
      guard let a = texture(width, height), let b = texture(width, height),
        let flow = texture((width + 7) / 8, (height + 7) / 8)
      else { return nil }
      let outputs = (0..<3).compactMap { _ in texture(width, height) }
      guard outputs.count == 3 else { return nil }
      history = History(
        width: width, height: height, hdr: hdr, images: [a, b], outputs: outputs, flow: flow)
      resetHistory()
    }
    guard let history else { return nil }
    let space = NativeStreamNISKernel.colorSpace(hdr: hdr)
    if newReal {
      historyIndex = 1 - historyIndex
      context.render(
        image.transformed(
          by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)),
        to: history.images[historyIndex], commandBuffer: command,
        bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: space)
      historyCount = min(historyCount + 1, 2)
    }
    guard historyCount > 0 else { return nil }
    let current = history.images[historyIndex]
    command.addCompletedHandler { [history] _ in _ = history }
    guard historyCount >= 2 else {
      interpolationStatus = "Warming up"
      return CIImage(mtlTexture: current, options: [.colorSpace: space])
    }
    let previous = history.images[1 - historyIndex]
    if newReal {
      guard let encoder = command.makeComputeCommandEncoder() else { return nil }
      encoder.setTexture(previous, index: 0)
      encoder.setTexture(current, index: 1)
      encoder.setTexture(history.flow, index: 2)
      dispatch(
        pipelines.flow, encoder: encoder, width: history.flow.width, height: history.flow.height)
      encoder.endEncoding()
    }
    let output = history.outputs[outputIndex]
    outputIndex = (outputIndex + 1) % 3
    guard let encoder = command.makeComputeCommandEncoder() else { return nil }
    encoder.setTexture(previous, index: 0)
    encoder.setTexture(current, index: 1)
    encoder.setTexture(history.flow, index: 2)
    encoder.setTexture(output, index: 3)
    var phase = phase.isFinite ? min(max(phase, 0), 1) : 1
    encoder.setBytes(&phase, length: MemoryLayout<Float>.size, index: 0)
    dispatch(pipelines.warp, encoder: encoder, width: width, height: height)
    encoder.endEncoding()
    interpolationStatus = "Active · one intermediate frame"
    return CIImage(mtlTexture: output, options: [.colorSpace: space])
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
