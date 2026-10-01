#!/usr/bin/env python3
"""Validate actual Metal 4 MetalFX/CI interop pixels on Apple Silicon."""
from pathlib import Path
import os,subprocess,tempfile
root=Path(__file__).resolve().parents[3]
source="\n".join((root/"ios/OpenNOWiOS/OpenNOWiOS"/name).read_text() for name in ["NativeStreamVideoEffects.swift","NativeStreamHDRMetal.swift","NativeStreamMetal4Effects.swift"])
CHECK = r"""
@main struct EffectsCheck {
 @MainActor static func main() async throws {
  setbuf(stdout,nil)
  let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
  let context = CIContext(mtlDevice: device,options: [.cacheIntermediates:false])
  let renderer = NativeStreamMetal4EffectsRenderer(device: device)!
  func fixture(format:OSType,transfer:CFString,phase:Int = 0) -> CVPixelBuffer {
   var allocation: CVPixelBuffer?
   precondition(CVPixelBufferCreate(nil,64,32,format,
    [kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary,&allocation) == kCVReturnSuccess)
   let result = allocation!
   CVPixelBufferLockBaseAddress(result,[])
   for plane in 0..<2 {
    let pointer = CVPixelBufferGetBaseAddressOfPlane(result,plane)!.assumingMemoryBound(to:UInt16.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(result,plane)/2
    let width = CVPixelBufferGetWidthOfPlane(result,plane),height = CVPixelBufferGetHeightOfPlane(result,plane)
    for y in 0..<height { for x in 0..<width {
     if plane == 0 { pointer[y*stride+x] = UInt16((y < height/2 ? 320 : 640)+phase) << 6 }
     else { pointer[y*stride+2*x] = 512 << 6; pointer[y*stride+2*x+1] = UInt16(x.isMultiple(of:2) ? 512 : 640) << 6 }
    } }
   }
   CVPixelBufferUnlockBaseAddress(result,[])
   CVBufferSetAttachment(result,kCVImageBufferTransferFunctionKey,transfer,.shouldPropagate)
   CVBufferSetAttachment(result,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_2020,.shouldPropagate)
   CVBufferSetAttachment(result,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_2020,.shouldPropagate)
   return result
  }
  func target() -> any MTLTexture {
   let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgr10a2Unorm,width:128,height:64,mipmapped:false)
   descriptor.storageMode = .shared; descriptor.usage = [.renderTarget,.shaderRead]
   return device.makeTexture(descriptor:descriptor)!
  }

  func pixels(_ texture: any MTLTexture) -> [UInt32] {
   var v = [UInt32](repeating:0,count:texture.width*texture.height)
   v.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*4,from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0) }
   return v
  }
  let formats:[OSType] = [kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
    kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
    kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange]
  for format in formats { for transfer in [1,2] { for upscale in [false,true] { for native in (transfer == 1 ? [false,true] : [false]) {
   let input = fixture(format: format,transfer: transfer == 1 ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_2100_HLG)
   let image = CIImage(cvPixelBuffer:input)
   let output = target(), reference = { () -> any MTLTexture in
    let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:128,height:64,mipmapped:false)
    d.storageMode = .shared; d.usage = [.shaderRead,.renderTarget,.shaderWrite]; return device.makeTexture(descriptor:d)!
   }()
   let destination = upscale ? CGRect(x:16,y:8,width:96,height:48) : CGRect(x:32,y:16,width:64,height:32)
   let space = CGColorSpace(name:CGColorSpace.itur_2100_PQ)!
   let legacy = NativeStreamSpatialUpscaler(device:device)
   var scaled:CIImage?
   for _ in 0..<500 {
    let c=queue.makeCommandBuffer()!
    scaled = upscale ? legacy.encode(image:image,sourceSize:image.extent.size,destinationSize:destination.size,hdr:true,context:context,commandBuffer:c) : image
    if let scaled {
     let result = scaled.transformed(by:CGAffineTransform(translationX:destination.minX,y:destination.minY).scaledBy(x:destination.width/scaled.extent.width,y:destination.height/scaled.extent.height))
     context.render(result,to:reference,commandBuffer:c,bounds:CGRect(x:0,y:0,width:128,height:64),colorSpace:space)
    }
    c.commit(); await c.completed(); precondition(c.status == .completed)
    if scaled != nil { break }; try await Task.sleep(nanoseconds:10_000_000)
   }
   precondition(scaled != nil)
   var success=false
   for _ in 0..<500 {
    let producer=queue.makeCommandBuffer()!
    let pair=AsyncStream<Bool>.makeStream()
    let finished: @Sendable (Double,NSError?) -> Void = { _,error in
     if let error { print(error) }; pair.continuation.yield(error == nil); pair.continuation.finish()
    }
    success = native
      ? renderer.submit(buffer:input,destination:destination,upscale:upscale,target:output,completion:finished)
      : renderer.submit(image:image,destination:destination,transfer:transfer,upscale:upscale,context:context,producer:producer,target:output,completion:finished)
    if success { for await ok in pair.stream { precondition(ok) }; break }
    producer.commit(); await producer.completed(); try await Task.sleep(nanoseconds:10_000_000)
   }
   precondition(success,renderer.status)
   let actual=pixels(output)
   var ref=[UInt16](repeating:0,count:128*64*4)
   ref.withUnsafeMutableBytes { reference.getBytes($0.baseAddress!,bytesPerRow:128*8,from:MTLRegionMake2D(0,0,128,64),mipmapLevel:0) }
   var expected=[UInt32](repeating:0,count:128*64)
   for y in 0..<64 { for x in 0..<128 {
    let i=((63-y)*128+x)*4
    let r=UInt32(min(1023,max(0,(Float(Float16(bitPattern:ref[i]))*1023).rounded())))
    let g=UInt32(min(1023,max(0,(Float(Float16(bitPattern:ref[i+1]))*1023).rounded())))
    let b=UInt32(min(1023,max(0,(Float(Float16(bitPattern:ref[i+2]))*1023).rounded())))
    expected[y*128+x]=r<<20|g<<10|b
   } }
   // CI drawable rendering and Metal fragment output must agree in orientation,
   // encoded transfer, gamut, range and chroma detail. Exclude fit boundaries.
   var maximum=0
   for y in Int(destination.minY+4)..<Int(destination.maxY-4) { for x in Int(destination.minX+4)..<Int(destination.maxX-4) { for shift in [0,10,20] {
    maximum=max(maximum,abs(Int((actual[y*128+x]>>shift)&1023)-Int((expected[y*128+x]>>shift)&1023)))
   } } }
   print("compare",native ? "native PQ" : "CI",String(format:"%08x",format),transfer,upscale,"maximum",maximum,"top",actual[16*128+40]&1023,expected[16*128+40]&1023,"bottom",actual[48*128+40]&1023,expected[48*128+40]&1023)
   precondition(maximum<=4,"Metal 4 effects transfer/orientation differs")
   precondition(actual[0]&0x3fffffff==0,"Fit border not black")
   print(native ? "PASS: Metal 4 native PQ effects" : "PASS: Metal 4 effects",format,transfer,upscale)
  } } } }

  let nativeDestination = CGRect(x:16,y:8,width:96,height:48)
  let timeline = NativeStreamMetalFrameTimeline(device:device)!
  func renderSwitch(_ input:CVPixelBuffer,_ output:any MTLTexture,native:Bool,
                    ticket:NativeStreamMetalFrameTimeline.Ticket? = nil) async throws {
   for _ in 0..<500 {
    let producer=queue.makeCommandBuffer()!
    if let ticket, ticket.previous > 0 { producer.encodeWaitForEvent(ticket.event,value:ticket.previous) }
    let pair=AsyncStream<Bool>.makeStream()
    let done: @Sendable (Double,NSError?) -> Void = { _,error in
     if let error { print(error) }; pair.continuation.yield(error == nil);pair.continuation.finish()
    }
    let accepted = native
      ? renderer.submit(buffer:input,destination:nativeDestination,upscale:true,target:output,ticket:ticket,completion:done)
      : renderer.submit(image:CIImage(cvPixelBuffer:input),destination:nativeDestination,transfer:1,upscale:true,
          context:context,producer:producer,target:output,ticket:ticket,completion:done)
    if accepted { for await success in pair.stream { precondition(success) }; return }
    try await Task.sleep(nanoseconds:10_000_000)
   }
   fatalError("Effects setup unavailable: \(renderer.status)")
  }
  let warm=fixture(format:kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,transfer:kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
  let switched=target(),switchReference=target()
  try await renderSwitch(warm,switched,native:true)
  for phase in 0..<40 {
   let input=fixture(format:kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
     transfer:kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,phase:phase)
   let ticket=timeline.next()
   try await renderSwitch(input,switched,native:phase.isMultiple(of:2),ticket:ticket)
   timeline.accept(ticket)
   try await renderSwitch(input,switchReference,native:false)
   let actual=pixels(switched),reference=pixels(switchReference)
   for i in actual.indices { for shift in [0,10,20] {
    precondition(abs(Int((actual[i]>>shift)&1023)-Int((reference[i]>>shift)&1023))<=4,
      "Native/CI switching lost HDR chroma, synchronization or orientation")
   } }
  }
  print("PASS: 40 native PQ ↔ CI MetalFX switches retain pixels and shared timeline")
  let gate=device.makeSharedEvent()!, pending=AsyncStream<Bool>.makeStream()
  let done: @Sendable (Double,NSError?) -> Void = { _,error in pending.continuation.yield(error == nil) }
  precondition(renderer.submit(buffer:warm,destination:nativeDestination,upscale:true,target:switched,
    ticket:NativeStreamMetalFrameTimeline.Ticket(event:gate,previous:1,value:2),completion:done))
  precondition(renderer.submit(buffer:warm,destination:nativeDestination,upscale:true,target:switched,
    ticket:NativeStreamMetalFrameTimeline.Ticket(event:gate,previous:2,value:3),completion:done))
  precondition(!renderer.submit(buffer:warm,destination:nativeDestination,upscale:true,target:switched,completion:done),
    "Native effects exceeded two slots")
  gate.signaledValue=1;var finished=0
  for await success in pending.stream { precondition(success);finished+=1;if finished==2 { break } }
  pending.continuation.finish()
  print("PASS: native PQ effects bound GPU work to two retained slots")
  for transfer in [kCVImageBufferTransferFunction_ITU_R_2100_HLG,kCVImageBufferTransferFunction_ITU_R_709_2] {
   let invalid=fixture(format:kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,transfer:transfer)
   precondition(!renderer.submit(buffer:invalid,destination:nativeDestination,upscale:true,target:switched) { _,_ in fatalError("Invalid transfer submitted") })
  }
  CVBufferSetAttachment(warm,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
  precondition(!renderer.submit(buffer:warm,destination:nativeDestination,upscale:true,target:switched) { _,_ in fatalError("Invalid gamut submitted") })
  print("PASS: non-PQ or non-BT.2020 inputs retain the supported fallback")

  for upscale in [false,true] { for sharpen in [false,true] {
   let space = CGColorSpace(name:CGColorSpace.sRGB)!
   let linear = NativeStreamVideoEffectsPolicy.workingColorSpace(hdr:false)
   var rgba=[Float](repeating:0,count:64*32*4)
   for y in 0..<32 { for x in 0..<64 {
    let i=(y*64+x)*4; rgba[i] = y<16 ? 0.05 : 0.7
    rgba[i+1] = x<32 ? 0.3 : 0.1; rgba[i+2]=0.4; rgba[i+3]=1
   } }
   var image=rgba.withUnsafeBytes { CIImage(bitmapData:Data($0),bytesPerRow:64*16,size:CGSize(width:64,height:32),format:.RGBAf,colorSpace:linear) }
   if sharpen { image=image.applyingFilter("CISharpenLuminance",parameters:[kCIInputSharpnessKey:0.6]).cropped(to:image.extent) }
   func texture(_ format:MTLPixelFormat)->any MTLTexture {
    let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:128,height:64,mipmapped:false)
    d.storageMode = .shared; d.usage = [.renderTarget,.shaderRead,.shaderWrite]; return device.makeTexture(descriptor:d)!
   }
   let output=texture(.bgra8Unorm), reference=texture(.rgba16Float)
   let destination = upscale ? CGRect(x:16,y:8,width:96,height:48) : CGRect(x:32,y:16,width:64,height:32)
   let legacy=NativeStreamSpatialUpscaler(device:device)
   for _ in 0..<500 {
    let command=queue.makeCommandBuffer()!
    let scaled=upscale ? legacy.encode(image:image,sourceSize:image.extent.size,destinationSize:destination.size,hdr:false,context:context,commandBuffer:command) : image
    if let scaled {
     context.render(scaled.transformed(by:CGAffineTransform(translationX:destination.minX,y:destination.minY).scaledBy(x:destination.width/scaled.extent.width,y:destination.height/scaled.extent.height)),
       to:reference,commandBuffer:command,bounds:CGRect(x:0,y:0,width:128,height:64),colorSpace:space)
    }
    command.commit(); await command.completed(); precondition(command.status == .completed)
    if scaled != nil { break }; try await Task.sleep(nanoseconds:10_000_000)
   }
   var success=false
   for _ in 0..<500 {
    let command=queue.makeCommandBuffer()!, pair=AsyncStream<Bool>.makeStream()
    success=renderer.submit(image:image,destination:destination,transfer:0,upscale:upscale,context:context,producer:command,target:output) { _,error in
     pair.continuation.yield(error == nil); pair.continuation.finish()
    }
    if success { for await ok in pair.stream { precondition(ok) }; break }
    command.commit(); await command.completed(); try await Task.sleep(nanoseconds:10_000_000)
   }
   precondition(success)
   let actual=pixels(output)
   var ref=[UInt16](repeating:0,count:128*64*4)
   ref.withUnsafeMutableBytes { reference.getBytes($0.baseAddress!,bytesPerRow:128*8,from:MTLRegionMake2D(0,0,128,64),mipmapLevel:0) }
   var maximum=0
   for y in Int(destination.minY+4)..<Int(destination.maxY-4) { for x in Int(destination.minX+4)..<Int(destination.maxX-4) { for (c,shift) in [16,8,0].enumerated() {
    let expected=min(255,max(0,Int((Float(Float16(bitPattern:ref[((63-y)*128+x)*4+c]))*255).rounded())))
    maximum=max(maximum,abs(Int((actual[y*128+x]>>shift)&255)-expected))
   } } }
   print("SDR compare",upscale,sharpen,"maximum",maximum)
   precondition(maximum<=2,"SDR/sharpen/MetalFX color or orientation changed")
   print("PASS: Metal 4 SDR/sharpen",upscale,sharpen,"maximum",maximum)
  } }
 }
}
"""
with tempfile.TemporaryDirectory(prefix="opennow-metal4-effects-") as temporary:
    swift=Path(temporary)/"Check.swift"; executable=Path(temporary)/"Check"
    swift.write_text(source+"""
enum NativeStreamHDRTransfer { case sdr,pq,hlg; static func detect(in buffer:CVPixelBuffer)->Self { let v=CVBufferCopyAttachment(buffer,kCVImageBufferTransferFunctionKey,nil) as? String; return v == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String ? .pq : v == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String ? .hlg : .sdr } }
enum NativeStreamVideoPerformanceLog { static func record(_ text:String) { print(text) } }
"""+CHECK)
    subprocess.run(["xcrun","swiftc","-parse-as-library","-target","arm64-apple-macos26.0",str(swift),"-o",str(executable)],check=True)
    subprocess.run([str(executable)],check=True,env=dict(os.environ,MTL_DEBUG_LAYER="1",MTL_SHADER_VALIDATION="1"),timeout=90)
