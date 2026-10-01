#!/usr/bin/env python3
"""Validate the shared video-effects implementations on a physical Mac GPU.

MetalFX is absent from the iOS simulator SDK. These synthetic checks exercise
real MetalFX HDR upscaling/readback and native video interpolation separately.
They do not establish iPhone/iPad capabilities or real-time performance.
Run from the repository root on an Apple Silicon Mac with Xcode providing the macOS 27 SDK.
"""
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[3]
source = (root / 'ios/OpenNOWiOS/OpenNOWiOS/NativeStreamVideoEffects.swift').read_text()
if platform.system() != 'Darwin' or platform.machine() != 'arm64':
    raise SystemExit('These checks require an Apple Silicon Mac.')

METALFX = r"""
@main struct MetalFXCheck {
 @MainActor static func main() async throws {
  setbuf(stdout, nil)
  guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("No Metal device") }
  precondition(MTLFXSpatialScalerDescriptor.supportsDevice(device), "MetalFX spatial unsupported")
  let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
  let space = NativeStreamVideoEffectsPolicy.workingColorSpace(hdr: true)
  let scaler = NativeStreamSpatialUpscaler(device: device)
  var pixels = [Float](repeating: 0, count: 64 * 32 * 4)
  for y in 0..<32 { for x in 0..<64 {
   let i = (y * 64 + x) * 4
   pixels[i] = x < 32 ? 4 : 0.1
   pixels[i+1] = y < 16 ? 0.1 : 2
   pixels[i+2] = 0.25; pixels[i+3] = 1
  } }
  let image = pixels.withUnsafeBytes { CIImage(bitmapData: Data($0), bytesPerRow: 64 * 16,
   size: CGSize(width: 64, height: 32), format: .RGBAf, colorSpace: space) }
  var result: CIImage?
  for _ in 0..<500 {
   let command = queue.makeCommandBuffer()!
   result = scaler.encode(image: image, sourceSize: image.extent.size, destinationSize: CGSize(width: 128, height: 64),
    hdr: true, context: context, commandBuffer: command)
   command.commit(); await command.completed()
   precondition(command.status == .completed, "GPU command failed")
   if result != nil { break }
   try await Task.sleep(nanoseconds: 10_000_000)
  }
  guard let output = result else { fatalError(scaler.status) }
  let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 128, height: 64, mipmapped: false)
  td.storageMode = .shared; td.usage = [.renderTarget, .shaderRead, .shaderWrite]
  let texture = device.makeTexture(descriptor: td)!, command = queue.makeCommandBuffer()!
  context.render(output, to: texture, commandBuffer: command, bounds: output.extent, colorSpace: space)
  command.commit(); await command.completed()
  precondition(command.status == .completed)
  var values = [Float](repeating: 0, count: 128 * 64 * 4)
  values.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 128*16,
   from: MTLRegionMake2D(0,0,128,64), mipmapLevel: 0) }
  let reference = device.makeTexture(descriptor: td)!, referenceCommand = queue.makeCommandBuffer()!
  context.render(image.transformed(by: CGAffineTransform(scaleX: 2, y: 2)), to: reference,
   commandBuffer: referenceCommand, bounds: CGRect(x:0,y:0,width:128,height:64), colorSpace: space)
  referenceCommand.commit(); await referenceCommand.completed()
  var baseline = [Float](repeating: 0, count: 128 * 64 * 4)
  baseline.withUnsafeMutableBytes { reference.getBytes($0.baseAddress!, bytesPerRow: 128*16,
   from: MTLRegionMake2D(0,0,128,64), mipmapLevel: 0) }
  print("Orientation reference green vs MetalFX green:", [baseline[4129],baseline[28705]], [values[4129],values[28705]])
  let reds = [values[4128], values[4576]]
  let greens = [values[4129], values[28705]]
  print("MetalFX HDR output", output.extent.size, "red", reds, "green", greens)
  precondition(reds[0] > 3 && reds[1] < 0.5 && abs(greens[0]-baseline[4129]) < 0.1 && abs(greens[1]-baseline[28705]) < 0.1,
   "HDR highlight or orientation regression")
  print("PASS: real MetalFX spatial GPU encode, HDR highlights >1, orientation matches ordinary playback")
  // Compare actual decoded-buffer layouts against ordinary playback as well.
  for hdr in [false, true] {
   var allocation: CVPixelBuffer?
   precondition(CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &allocation) == kCVReturnSuccess)
   let buffer = allocation!
   CVPixelBufferLockBaseAddress(buffer, [])
   let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer,0)!.assumingMemoryBound(to: UInt8.self)
   let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer,0)
   for y in 0..<32 { for x in 0..<64 { yBase[y*stride+x] = y < 16 ? (x < 32 ? 40 : 90) : (x < 32 ? 160 : 220) } }
   memset(CVPixelBufferGetBaseAddressOfPlane(buffer,1)!,128,CVPixelBufferGetBytesPerRowOfPlane(buffer,1)*16)
   CVPixelBufferUnlockBaseAddress(buffer, [])
   CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
   CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,hdr ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
   CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
   let inputImage = CIImage(cvPixelBuffer: buffer)
   let sampleSpace = NativeStreamVideoEffectsPolicy.workingColorSpace(hdr: hdr)
   var effect: CIImage?
   for _ in 0..<500 {
    let command = queue.makeCommandBuffer()!
    effect = scaler.encode(image: inputImage, sourceSize: inputImage.extent.size,
     destinationSize: CGSize(width:128,height:64),hdr:hdr,context:context,commandBuffer:command)
    command.commit(); await command.completed(); precondition(command.status == .completed)
    if effect != nil { break }; try await Task.sleep(nanoseconds:10_000_000)
   }
   precondition(effect != nil,scaler.status)
   func pixels(_ image: CIImage) async -> [Float] {
    let target = device.makeTexture(descriptor:td)!, command = queue.makeCommandBuffer()!
    context.render(image,to:target,commandBuffer:command,bounds:CGRect(x:0,y:0,width:128,height:64),colorSpace:sampleSpace)
    command.commit(); await command.completed(); precondition(command.status == .completed)
    var value = [Float](repeating:0,count:128*64*4)
    value.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow:128*16,from:MTLRegionMake2D(0,0,128,64),mipmapLevel:0) }
    return value
   }
   let expected = await pixels(inputImage.transformed(by:CGAffineTransform(scaleX:2,y:2)))
   let actual = await pixels(effect!)
   for offset in [4128,4576,28704,29152] {
    precondition(abs(actual[offset]-expected[offset]) < max(0.05,expected[offset]*0.05),"NV12 MetalFX orientation/color differs from normal playback")
   }
   print("PASS: NV12",hdr ? "PQ HDR" : "SDR","MetalFX drawable orientation matches normal playback")
  }
  if VTLowLatencyFrameInterpolationConfiguration.isSupported,
   let config = VTLowLatencyFrameInterpolationConfiguration(frameWidth: 1920, frameHeight: 1080, numberOfInterpolatedFrames: 1) {
   print("Mac interpolation formats:", config.supportedPixelFormats.map { String(format: "%08x", $0) })
  }
 }
}
"""

FRAME_GENERATION = r"""
enum NativeStreamHDRTransfer { case sdr, pq; static func detect(in buffer: CVPixelBuffer) -> Self { CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String ? .pq : .sdr } }
enum NativeStreamVideoPerformanceLog { static func record(_ text: String) { print(text) } }
@main struct InterpolationCheck {
 @MainActor static func main() async throws {
  setbuf(stdout, nil)
  let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
  let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
  let generator = NativeStreamFrameGenerator()
  let limits = NativeStreamVideoEffectsPolicy.frameGenerationLimits()
  print("Mac interpolation limits:", limits.label)
  var oversized: CVPixelBuffer?
  precondition(CVPixelBufferCreate(nil,limits.maximumDimension+2,1080,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
   [kCVPixelBufferIOSurfacePropertiesKey: [:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary,&oversized) == kCVReturnSuccess)
  let rejectedCommand = queue.makeCommandBuffer()!
  precondition(generator.encode(buffer:oversized!,timestamp:1,device:device,context:context,commandBuffer:rejectedCommand) == nil)
  precondition(generator.status.hasPrefix("Resolution unsupported"))
  rejectedCommand.commit(); await rejectedCommand.completed()
  generator.reset()
  print("PASS: oversized interpolation surface rejected before producing an unwritten frame")
  func source(offset: Int, hdr: Bool) -> CVPixelBuffer {
   var allocation: CVPixelBuffer?
   precondition(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &allocation) == kCVReturnSuccess)
   let value = allocation!
   CVPixelBufferLockBaseAddress(value, [])
   memset(CVPixelBufferGetBaseAddressOfPlane(value, 0)!, 32, CVPixelBufferGetBytesPerRowOfPlane(value, 0)*1080)
   memset(CVPixelBufferGetBaseAddressOfPlane(value, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(value, 1)*540)
   let base = CVPixelBufferGetBaseAddressOfPlane(value, 0)!.assumingMemoryBound(to: UInt8.self)
   let stride = CVPixelBufferGetBytesPerRowOfPlane(value, 0)
   for y in 300..<700 { for x in (600+offset)..<(900+offset) { base[y*stride+x] = 220 } }
   CVPixelBufferUnlockBaseAddress(value, [])
   CVBufferSetAttachment(value, kCVImageBufferColorPrimariesKey, hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
   CVBufferSetAttachment(value, kCVImageBufferTransferFunctionKey, hdr ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
   CVBufferSetAttachment(value, kCVImageBufferYCbCrMatrixKey, hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
   return value
  }
  for hdr in [false, true] {
  let first = source(offset: 0, hdr: hdr), second = source(offset: 12, hdr: hdr)
  var result: CIImage?
  for i in 0..<500 {
   let command = queue.makeCommandBuffer()!
   let timestamp = Int64(1_000_000_000) + Int64(i)*16_666_667
   result = generator.encode(buffer: i.isMultiple(of: 2) ? first : second, timestamp: timestamp,
    device: device, context: context, commandBuffer: command)
   command.commit(); await command.completed()
   precondition(command.status == .completed, "Interpolation GPU error")
   if result != nil {
    print("Native interpolation status:", generator.status, "GPU ms:", (command.gpuEndTime-command.gpuStartTime)*1000)
    break
   }
   try await Task.sleep(nanoseconds: 10_000_000)
  }
  precondition(result != nil, generator.status)
  precondition(result!.extent.size == CGSize(width: 1920, height: 1080))
  var bitmap = [UInt8](repeating: 0, count: 1920 * 1080 * 4)
  bitmap.withUnsafeMutableBytes { raw in
   context.render(result!, toBitmap: raw.baseAddress!, rowBytes: 1920*4,
    bounds: result!.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
  }
  var brightCount = 0, sumX = 0
  for y in 0..<1080 { for x in 0..<1920 {
   if bitmap[(y*1920+x)*4] > 180 { brightCount += 1; sumX += x }
  } }
  let centroid = Double(sumX) / Double(max(1, brightCount))
  print("Generated-frame bright pixels:", brightCount, "motion midpoint centroid:", centroid)
  precondition(brightCount > 100_000 && abs(centroid-755.5) < 4, "Generated motion midpoint image missing or incorrect")
  if hdr {
   func highlight(_ image: CIImage) -> Float {
    var rgba = [Float](repeating: 0, count: 4)
    rgba.withUnsafeMutableBytes { raw in
     context.render(image, toBitmap: raw.baseAddress!, rowBytes: 16,
      bounds: CGRect(x: 750, y: 500, width: 1, height: 1), format: .RGBAf,
      colorSpace: NativeStreamVideoEffectsPolicy.workingColorSpace(hdr: true))
    }
    return rgba[0]
   }
   let inputHighlight = highlight(CIImage(cvPixelBuffer: second)), outputHighlight = highlight(result!)
   print("PQ linear HDR highlight input/output:", inputHighlight, outputHighlight)
   precondition(outputHighlight > 1 && outputHighlight / inputHighlight > 0.8 && outputHighlight / inputHighlight < 1.2,
    "HDR highlight lost or incorrectly range-mapped during interpolation")
  }
  let scaler = NativeStreamSpatialUpscaler(device:device)
  let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:2112,height:1188,mipmapped:false)
  td.storageMode = .shared; td.usage = [.renderTarget,.shaderRead,.shaderWrite]
  let target = device.makeTexture(descriptor:td)!
  var combinedFrames = 0
  for i in 0..<120 {
   let command = queue.makeCommandBuffer()!
   let image = generator.encode(buffer:i.isMultiple(of:2) ? first : second,
    timestamp:10_000_000_000+Int64(i)*16_666_667,device:device,context:context,commandBuffer:command)
   var combined = false
   if let image,let scaled = scaler.encode(image:image,sourceSize:image.extent.size,destinationSize:CGSize(width:2112,height:1188),
    hdr:hdr,context:context,commandBuffer:command) {
    context.render(scaled,to:target,commandBuffer:command,bounds:CGRect(x:0,y:0,width:2112,height:1188),
     colorSpace:NativeStreamVideoEffectsPolicy.workingColorSpace(hdr:hdr))
    combined = true
   }
   command.commit(); await command.completed(); precondition(command.status == .completed)
   if combined {
    combinedFrames += 1
    var sample = [Float](repeating:0,count:4)
    sample.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow:16,from:MTLRegionMake2D(825,550,1,1),mipmapLevel:0) }
    precondition(sample[0] > (hdr ? 1 : 0.5),"Combined generated/upscaled image was unwritten")
    precondition(abs(sample[1]-sample[0]) < 0.1 && abs(sample[2]-sample[0]) < 0.1,"Green flash in neutral generated/upscaled frame")
   } else { try await Task.sleep(nanoseconds:10_000_000) }
  }
  precondition(combinedFrames >= 60)
  print("PASS: combined interpolation + MetalFX",hdr ? "PQ" : "SDR",combinedFrames,"frames without unwritten/green output")
  // A budget cooldown drops history but must retain the initialized processor.
  generator.clearHistory()
  let restartFirst = queue.makeCommandBuffer()!
  precondition(generator.encode(buffer:first,timestamp:20_000_000_000,device:device,context:context,
   commandBuffer:restartFirst) == nil && generator.status != "Preparing")
  restartFirst.commit(); await restartFirst.completed(); precondition(restartFirst.status == .completed)
  let restartSecond = queue.makeCommandBuffer()!
  precondition(generator.encode(buffer:second,timestamp:20_016_666_667,device:device,context:context,
   commandBuffer:restartSecond) != nil,"Cooldown unexpectedly reloads interpolation model")
  restartSecond.commit(); await restartSecond.completed(); precondition(restartSecond.status == .completed)
  print("PASS: interpolation resumes after history-only cooldown without ML session reload")
  generator.reset()
  print("PASS: real Apple low-latency interpolation with GPU full/video-range conversion", hdr ? "8-bit PQ HDR" : "8-bit SDR", "generated midpoint image, GPU completion, session reset")
  }
 }
}
"""

with tempfile.TemporaryDirectory(prefix='opennow-video-effects-') as temporary:
    for name, body in [('MetalFX', METALFX), ('FrameGeneration', FRAME_GENERATION)]:
        text = source.split('/// Apple video interpolation')[0] if name == 'MetalFX' else source
        swift = Path(temporary) / (name + '.swift')
        executable = Path(temporary) / name
        swift.write_text(text + body)
        subprocess.run(['xcrun', 'swiftc', '-module-name', 'OpenNOWVideoEffectsCheck', '-parse-as-library', '-target',
                        'arm64-apple-macos26.0', str(swift), '-o', str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=60)
