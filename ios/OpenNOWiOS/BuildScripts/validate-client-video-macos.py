#!/usr/bin/env python3
"""Exercise spatial scaling, HDR headroom and Metal 4 producer handoff."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

app = Path(__file__).resolve().parents[1] / 'OpenNOWiOS'
source = '\n'.join((app / name).read_text() for name in (
    'NativeStreamVideoEffects.swift', 'NativeStreamNIS.swift', 'NativeStreamClientVideo.swift',
    'NativeStreamHDRMetal.swift', 'NativeStreamMetal4Effects.swift', 'NativeStreamMetal4Presentation.swift'))
check = r'''
enum NativeStreamHDRTransfer {
 case sdr, pq, hlg
 static func detect(in buffer: CVPixelBuffer) -> Self {
  let v=CVBufferCopyAttachment(buffer,kCVImageBufferTransferFunctionKey,nil) as? String
  return v == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String ? .pq : v == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String ? .hlg : .sdr
 }
}
@main struct Check {
 @MainActor static func main() async throws {
  setbuf(stdout,nil)
  let device=MTLCreateSystemDefaultDevice()!, queue=device.makeCommandQueue()!
  let context=CIContext(mtlDevice:device,options:[.cacheIntermediates:false])
  func texture(_ w:Int,_ h:Int) -> any MTLTexture {
   let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:w,height:h,mipmapped:false)
   d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite,.renderTarget]
   return device.makeTexture(descriptor:d)!
  }
  func pixels(_ t:any MTLTexture) -> [Float] {
   var b=[UInt16](repeating:0,count:t.width*t.height*4)
   b.withUnsafeMutableBytes { t.getBytes($0.baseAddress!,bytesPerRow:t.width*8,from:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0) }
   return b.map { Float(Float16(bitPattern:$0)) }
  }
  func fill(_ t:any MTLTexture,_ color:[Float]) {
   var b=[UInt16](repeating:0,count:t.width*t.height*4)
   for i in 0..<t.width*t.height { for c in 0..<4 { b[i*4+c]=Float16(color[c]).bitPattern } }
   b.withUnsafeBytes { t.replace(region:MTLRegionMake2D(0,0,t.width,t.height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:t.width*8) }
  }
  let processor=NativeStreamClientVideoProcessor(device:device)
  processor.prepareIfNeeded()
  for hdr in [false,true] {
   let space=NativeStreamNISKernel.colorSpace(hdr:hdr)
   for sharp:Float in [0,0.25,1] { for (w,h,ow,oh) in [(37,29,43,33),(64,32,128,64)] + (hdr && sharp == 0 ? [(2560,1080,2868,1320)] : []) {
    let input=texture(w,h),output=texture(ow,oh)
    for color:[Float] in [[0,0,0,1],[1,1,1,1],[0.2,0.4,0.7,1],[0.6,0.1,0.3,1]] {
     fill(input,color)
     let image=CIImage(mtlTexture:input,options:[.colorSpace:space])!
     var success=false
     for _ in 0..<300 {
      let command=queue.makeCommandBuffer()!
      if let scaled=processor.upscaleFSR(image:image,destination:CGSize(width:ow,height:oh),hdr:hdr,sharpness:sharp,context:context,command:command) {
       context.render(scaled,to:output,commandBuffer:command,bounds:CGRect(x:0,y:0,width:ow,height:oh),colorSpace:space);success=true
      }
      command.commit();await command.completed();precondition(command.status == .completed)
      if success { break };try await Task.sleep(nanoseconds:10_000_000)
     }
     precondition(success,processor.fsrStatus)
     let actual=pixels(output)
     precondition(actual.allSatisfy { $0.isFinite && $0 >= -0.001 && $0 <= 1.001 })
     for i in 0..<ow*oh { for c in 0..<4 { precondition(abs(actual[i*4+c]-color[c])<0.006,"FSR color drift or stale edge") } }
    }
   } }
  }
  print("PASS FSR: SDR/PQ black/white/color, sharpness, 2x/near-native, partial edge groups and repeated surfaces")
  if #available(macOS 26.0,*) {
   let image=CIImage(color:CIColor(red:4,green:2,blue:1,alpha:1,colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)!).cropped(to:CGRect(x:0,y:0,width:16,height:16)).settingContentHeadroom(4)
   let mapped=NativeStreamClientVideoProcessor.toneMap(image:image,headroom:2)!
   let target=texture(16,16),command=queue.makeCommandBuffer()!
   context.render(mapped,to:target,commandBuffer:command,bounds:CGRect(x:0,y:0,width:16,height:16),colorSpace:CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!)
   command.commit();await command.completed();precondition(command.status == .completed)
   let color=pixels(target)
   precondition(color.allSatisfy { $0.isFinite && $0 >= 0 },"Invalid HDR tone map")
   let luma=color[0]*0.2126+color[1]*0.7152+color[2]*0.0722
   print("HDR mapped",Array(color.prefix(4)),"luma",luma)
   precondition(luma<2.05 && luma>1,"HDR compression did not fit headroom")
  }
  print("PASS adaptive HDR headroom filter")
  // Optional producer effects must preserve the existing Metal 4 GPU-event handoff.
  let renderer=NativeStreamMetal4EffectsRenderer(device:device)!
  for hdr in [false,true] { for method in [StreamUpscalingMethod.nis,.fsr1] {
   let space=NativeStreamNISKernel.colorSpace(hdr:hdr)
   let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:hdr ? .bgr10a2Unorm : .bgra8Unorm,width:96,height:48,mipmapped:false)
   desc.storageMode = .shared;desc.usage=[.renderTarget,.shaderRead]
   let target=device.makeTexture(descriptor:desc)!
   let input=texture(64,32)
   for level:Float in [0.2,0.4,0.1,0.6] {
    fill(input,[level,level,level,1])
    let image=CIImage(mtlTexture:input,options:[.colorSpace:space])!
    var success=false
    for _ in 0..<300 {
     let command=queue.makeCommandBuffer()!
     let processed=method == .fsr1 ? processor.upscaleFSR(image:image,destination:CGSize(width:96,height:48),hdr:hdr,sharpness:0.25,context:context,command:command)! : image
     let pair=AsyncStream<Bool>.makeStream()
     success=renderer.submit(image:processed,destination:CGRect(x:0,y:0,width:96,height:48),transfer:hdr ? 1 : 0,upscale:method == .nis,
      context:context,producer:command,target:target,method:method,sharpening:method == .nis ? 0.25 : 0,
      completion:{ _,error in pair.continuation.yield(error == nil);pair.continuation.finish() })
     if success { for await ok in pair.stream { precondition(ok) };break }
     command.commit();await command.completed();try await Task.sleep(nanoseconds:10_000_000)
    }
    precondition(success,renderer.status)
    var data=[UInt32](repeating:0,count:96*48)
    data.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow:96*4,from:MTLRegionMake2D(0,0,96,48),mipmapLevel:0) }
    let values=data.map { Float($0 & (hdr ? 1023 : 255))/Float(hdr ? 1023 : 255) }
    print("Handoff",hdr,method,level,"range",values.min()!,values.max()!)
    for value in data {
     let actual=Float(value & (hdr ? 1023 : 255))/Float(hdr ? 1023 : 255)
     precondition(abs(actual-level)<0.015,"Client effect handoff changed color or read stale frame")
    }
   }
  } }
  print("PASS NIS/FSR1 + Metal4 SDR/PQ event handoff and repeated frame ownership")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='opennow-client-video-') as directory:
    temporary = Path(directory)
    shutil.copytree(app / 'StreamVideo', temporary / 'StreamVideo')
    shutil.copytree(app / 'NIS', temporary / 'NIS')
    (temporary / 'Check.swift').write_text(source + check)
    subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos26.0',
                    str(temporary / 'Check.swift'), '-o', str(temporary / 'Check')], check=True)
    subprocess.run([str(temporary / 'Check')], check=True,
                   env=dict(os.environ, MTL_DEBUG_LAYER='1', MTL_SHADER_VALIDATION='1'), timeout=180)
