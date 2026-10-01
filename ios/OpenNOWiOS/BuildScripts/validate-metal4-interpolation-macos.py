#!/usr/bin/env python3
"""Stress real VT interpolation -> GPU event -> Metal 4 FX -> presentation pixels."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[3]
source="\n".join((root/"ios/OpenNOWiOS/OpenNOWiOS"/name).read_text() for name in ["NativeStreamVideoEffects.swift","NativeStreamHDRMetal.swift","NativeStreamMetal4Effects.swift"])
CHECK = r"""
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
  func source(offset: Int, hdr: Bool, width:Int, height:Int) -> CVPixelBuffer {
   var allocation: CVPixelBuffer?
   precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &allocation) == kCVReturnSuccess)
   let value = allocation!
   CVPixelBufferLockBaseAddress(value, [])
   memset(CVPixelBufferGetBaseAddressOfPlane(value, 0)!, 32, CVPixelBufferGetBytesPerRowOfPlane(value, 0)*height)
   memset(CVPixelBufferGetBaseAddressOfPlane(value, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(value, 1)*(height/2))
   let base = CVPixelBufferGetBaseAddressOfPlane(value, 0)!.assumingMemoryBound(to: UInt8.self)
   let stride = CVPixelBufferGetBytesPerRowOfPlane(value, 0)
   for y in 300..<700 { for x in (600+offset)..<(900+offset) { base[y*stride+x] = 220 } }
   CVPixelBufferUnlockBaseAddress(value, [])
   CVBufferSetAttachment(value, kCVImageBufferColorPrimariesKey, hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
   CVBufferSetAttachment(value, kCVImageBufferTransferFunctionKey, hdr ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
   CVBufferSetAttachment(value, kCVImageBufferYCbCrMatrixKey, hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
   return value
  }
  for inputSize in [CGSize(width:1920,height:1080),CGSize(width:1680,height:720)] {
  let sourceWidth = Int(inputSize.width), sourceHeight = Int(inputSize.height)
  for quality in NativeStreamFrameGenerationQuality.allCases {
  for hdr in [false, true] {
  let size = NativeStreamVideoEffectsPolicy.interpolationSize(source:inputSize,quality:quality)
  let width = Int(size.width), height = Int(size.height)
  let first = source(offset: 0, hdr: hdr,width:sourceWidth,height:sourceHeight), second = source(offset: 12, hdr: hdr,width:sourceWidth,height:sourceHeight)
  var result: CIImage?
  for i in 0..<500 {
   let command = queue.makeCommandBuffer()!
   let timestamp = Int64(1_000_000_000) + Int64(i)*16_666_667
   result = generator.encode(buffer: i.isMultiple(of: 2) ? first : second, timestamp: timestamp,
    device: device, context: context, commandBuffer: command,quality:quality)
   command.commit(); await command.completed()
   precondition(command.status == .completed, "Interpolation GPU error")
   if result != nil {
    print("Native interpolation status:", generator.status, "GPU ms:", (command.gpuEndTime-command.gpuStartTime)*1000)
    break
   }
   try await Task.sleep(nanoseconds: 10_000_000)
  }
  precondition(result != nil, generator.status)
  precondition(result!.extent.size == size)
  precondition(CVPixelBufferGetWidth(first) == sourceWidth && CVPixelBufferGetHeight(first) == sourceHeight)
  var bitmap = [UInt8](repeating: 0, count: width * height * 4)
  bitmap.withUnsafeMutableBytes { raw in
   context.render(result!, toBitmap: raw.baseAddress!, rowBytes: width*4,
    bounds: result!.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
  }
  var brightCount = 0, sumX = 0
  for y in 0..<height { for x in 0..<width {
   if bitmap[(y*width+x)*4] > 180 { brightCount += 1; sumX += x }
  } }
  let centroid = Double(sumX) / Double(max(1, brightCount))
  print("Generated-frame bright pixels:", brightCount, "motion midpoint centroid:", centroid)
  precondition(brightCount > Int(100_000 * size.width/inputSize.width * size.height/inputSize.height) && abs(centroid-(756*size.width/inputSize.width-0.5)) < 4, "Generated motion midpoint image missing or incorrect")
  if hdr {
   func highlight(_ image: CIImage, x:Double = 750,y:Double) -> Float {
    var rgba = [Float](repeating: 0, count: 4)
    rgba.withUnsafeMutableBytes { raw in
     context.render(image, toBitmap: raw.baseAddress!, rowBytes: 16,
      bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf,
      colorSpace: NativeStreamVideoEffectsPolicy.workingColorSpace(hdr: true))
    }
    return rgba[0]
   }
   let inputHighlight = highlight(CIImage(cvPixelBuffer: second),y:inputSize.height-500), outputHighlight = highlight(result!,x:750*size.width/inputSize.width,y:(inputSize.height-500)*size.height/inputSize.height)
   print("PQ linear HDR highlight input/output:", inputHighlight, outputHighlight)
   precondition(outputHighlight > 1 && outputHighlight / inputHighlight > 0.8 && outputHighlight / inputHighlight < 1.2,
    "HDR highlight lost or incorrectly range-mapped during interpolation")
  }
  let renderer = NativeStreamMetal4EffectsRenderer(device:device)!
  let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:hdr ? .bgr10a2Unorm : .bgra8Unorm,width:2112,height:1188,mipmapped:false)
  td.storageMode = .shared; td.usage = [.renderTarget,.shaderRead,.shaderWrite]
  let target = device.makeTexture(descriptor:td)!
  var combinedFrames = 0
  var processingMS: [Double] = []
  for i in 0..<120 {
   let start = ProcessInfo.processInfo.systemUptime
   let command = queue.makeCommandBuffer()!
   let image = generator.encode(buffer:i.isMultiple(of:2) ? first : second,
    timestamp:10_000_000_000+Int64(i)*16_666_667,device:device,context:context,commandBuffer:command,quality:quality)
   var combined = false
   if let image {
    let pair = AsyncStream<Bool>.makeStream()
    combined = renderer.submit(image:image,destination:CGRect(x:0,y:0,width:2112,height:1188),transfer:hdr ? 1 : 0,upscale:true,
      context:context,producer:command,target:target) { _,error in
      if let error { print(error) }; pair.continuation.yield(error == nil); pair.continuation.finish()
    }
    if combined { for await ok in pair.stream { precondition(ok) } }
   }
   if !combined { command.commit(); await command.completed(); precondition(command.status == .completed) }
   if combined {
    combinedFrames += 1
    if i >= 16 { processingMS.append((ProcessInfo.processInfo.systemUptime-start)*1000) }
    var pixel:UInt32 = 0
    withUnsafeMutableBytes(of:&pixel) { target.getBytes($0.baseAddress!,bytesPerRow:4,from:MTLRegionMake2D(Int(750*2112/inputSize.width),550,1,1),mipmapLevel:0) }
    let maxCode = hdr ? 1023 : 255
    let shifts = hdr ? [20,10,0] : [16,8,0]
    let channels=shifts.map { Int((pixel>>$0)&UInt32(maxCode)) }
    precondition(channels[0]>Int(Double(maxCode)*0.7),"Metal 4 generated image was unwritten/dark")
    precondition(channels.max()!-channels.min()!<5,"Green flash in Metal 4 generated image")
   } else { try await Task.sleep(nanoseconds:10_000_000) }
   // Match the app's alternating full-size real / smaller generated path.
   let realCommand = queue.makeCommandBuffer()!
   let realImage = CIImage(cvPixelBuffer:first)
   let pair=AsyncStream<Bool>.makeStream()
   let real = renderer.submit(image:realImage,destination:CGRect(x:0,y:0,width:2112,height:1188),transfer:hdr ? 1 : 0,upscale:true,
      context:context,producer:realCommand,target:target) { _,error in
      if let error { print(error) }; pair.continuation.yield(error == nil); pair.continuation.finish()
   }
   if real { for await ok in pair.stream { precondition(ok) } }
   else { precondition(i<16,"Real-frame Metal 4 upscaler repeatedly reinitializes"); realCommand.commit(); await realCommand.completed() }

  }
  precondition(combinedFrames >= 60)
  let timings = processingMS.sorted()
  print("Measured Mac interpolation + MetalFX wall time",quality.label,inputSize,hdr ? "PQ" : "SDR", "median ms:",timings[timings.count/2])
  print("PASS: interpolation + Metal 4 MetalFX",quality.label,inputSize,hdr ? "PQ" : "SDR",combinedFrames,"frames without unwritten/green output")
  // A budget cooldown drops history but must retain the initialized processor.
  generator.clearHistory()
  let restartFirst = queue.makeCommandBuffer()!
  precondition(generator.encode(buffer:first,timestamp:20_000_000_000,device:device,context:context,
   commandBuffer:restartFirst,quality:quality) == nil && generator.status != "Preparing")
  restartFirst.commit(); await restartFirst.completed(); precondition(restartFirst.status == .completed)
  let restartSecond = queue.makeCommandBuffer()!
  precondition(generator.encode(buffer:second,timestamp:20_016_666_667,device:device,context:context,
   commandBuffer:restartSecond,quality:quality) != nil,"Cooldown unexpectedly reloads interpolation model")
  restartSecond.commit(); await restartSecond.completed(); precondition(restartSecond.status == .completed)
  print("PASS: interpolation resumes after history-only cooldown without ML session reload")
  generator.reset()
  print("PASS: real Apple low-latency interpolation with GPU full/video-range conversion", hdr ? "8-bit PQ HDR" : "8-bit SDR", "generated midpoint image, GPU completion, session reset")
  }
  }
  }
 }
}
"""
with tempfile.TemporaryDirectory(prefix="opennow-metal4-interpolation-") as temporary:
    swift=Path(temporary)/"Check.swift"; executable=Path(temporary)/"Check"
    swift.write_text(source+CHECK)
    subprocess.run(["xcrun","swiftc","-parse-as-library","-target","arm64-apple-macos26.0",str(swift),"-o",str(executable)],check=True)
    subprocess.run([str(executable)],check=True,env=dict(os.environ,MTL_DEBUG_LAYER="1",MTL_SHADER_VALIDATION="1"),timeout=180)
