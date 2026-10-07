#!/usr/bin/env python3
"""Validate NIS against upstream constants and actual Metal 3/4 GPU output."""
from pathlib import Path
import json
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
app = root / "OpenNOWiOS"
source = "\n".join((app / name).read_text() for name in [
    "NativeStreamVideoEffects.swift", "NativeStreamNIS.swift", "NativeStreamHDRMetal.swift",
    "NativeStreamMetal4Effects.swift", "NativeStreamMetal4Presentation.swift"])
check = r'''
enum NativeStreamHDRTransfer {
 case sdr, pq, hlg
 static func detect(in buffer: CVPixelBuffer) -> Self {
  let v = CVBufferCopyAttachment(buffer,kCVImageBufferTransferFunctionKey,nil) as? String
  return v == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String ? .pq
    : v == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String ? .hlg : .sdr
 }
}
@main struct NISCheck {
 @MainActor static func main() async throws {
  setbuf(stdout,nil)
  let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[NSNumber]]
  var row = 0
  for hdr in [false,true] { for sharpness: Float in [0,0.25,0.5,1] {
   let actual = NativeStreamNISConfig.words(width:37,height:29,outputWidth:43,outputHeight:33,hdr:hdr,sharpness:sharpness)!
   precondition(actual.count == 28)
   for index in 0..<28 {
    let value = expected[row][index].uint32Value
    if index < 18 {
     precondition(abs(Float(bitPattern:actual[index])-Float(bitPattern:value)) < 0.00001, "Upstream NIS constant mismatch")
    } else { precondition(actual[index] == value) }
   }; row += 1
  } }
  print("PASS: Swift config matches NVIDIA C++ for SDR/PQ at four sharpening levels")
  let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
  let context = CIContext(mtlDevice:device, options:[.cacheIntermediates:false])
  let kernel = try NativeStreamNISKernel(device:device)
  func texture(_ width:Int,_ height:Int,_ format:MTLPixelFormat = .rgba16Float) -> any MTLTexture {
   let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
   d.storageMode = .shared; d.usage = [.renderTarget,.shaderRead,.shaderWrite]
   return device.makeTexture(descriptor:d)!
  }
  func floats(_ texture:any MTLTexture) -> [Float] {
   var data = [UInt16](repeating:0,count:texture.width*texture.height*4)
   data.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow:texture.width*8,from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0) }
   return data.map { Float(Float16(bitPattern:$0)) }
  }
  for hdr in [false,true] { for sharpness:Float in [0,0.25,1] {
   let sizes = [(37,29,43,33),(64,32,128,64),(37,29,37,29)]
     + (hdr && sharpness == 0.25 ? [(2560,1080,2868,1320),(2560,1080,3840,1620),(2560,1080,5120,2160)] : [])
   for size in sizes {
    let (w,h,ow,oh) = size, input=texture(w,h), output=texture(ow,oh)
    let config=device.makeBuffer(length:256,options:.storageModeShared)!
    NativeStreamNISConfig.write(to:config,width:w,height:h,outputWidth:ow,outputHeight:oh,hdr:hdr,sharpness:sharpness)
    for phase in 0..<(w > 1024 ? 2 : 4) {
     var pixels = [UInt16](repeating:0,count:w*h*4)
     for y in 0..<h { for x in 0..<w {
      let v:Float = phase == 0 ? 0.4 : Float((x+phase*3)%w)/Float(w)*0.6+0.1
      let values:[Float] = phase == 0 ? [0.2,0.4,0.7,1] : [v,v,v,1]
      for c in 0..<4 { pixels[(y*w+x)*4+c]=Float16(values[c]).bitPattern }
     } }
     pixels.withUnsafeBytes { input.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*8) }
     let command=queue.makeCommandBuffer()!, encoder=command.makeComputeCommandEncoder()!
     encoder.setComputePipelineState(hdr ? kernel.pq : kernel.sdr)
     encoder.setTexture(input,index:0);encoder.setTexture(output,index:1);encoder.setBuffer(config,offset:0,index:0)
     encoder.dispatchThreadgroups(NativeStreamNISKernel.groups(width:ow,height:oh),threadsPerThreadgroup:NativeStreamNISKernel.threads)
     encoder.endEncoding();command.commit();await command.completed()
     precondition(command.status == .completed,"NIS GPU error")
     let actual=floats(output)
     precondition(actual.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },"Invalid NIS pixels")
     for i in 0..<ow*oh {
      precondition(actual[i*4+3] == 1,"Partial block left unwritten/stale")
      if phase == 0 {
       for (c,v): (Int,Float) in [(0,0.2),(1,0.4),(2,0.7)] { precondition(abs(actual[i*4+c]-v)<0.003,"Constant color changed") }
      }
     }
     if ow == w && oh == h && sharpness == 0 {
      let ref=pixels.map { Float(Float16(bitPattern:$0)) }
      precondition(zip(actual,ref).allSatisfy { abs($0-$1)<0.004 },"1:1 filter shifted/flipped pixels")
     }
     if phase > 0 {
      let expected=Float(phase*3)/Float(w)*0.6+0.1
      precondition(abs(actual[(oh/2*ow)*4]-expected)<0.05,"Signed border coordinates wrapped to opposite edge")
     }
    }
   }
  } }
  print("PASS: SDR/PQ near-native, 2x and 1:1 plus 2560x1080→2868x1320; complete edge blocks, motion, finite pixels, DC color")
  let renderer=NativeStreamMetal4EffectsRenderer(device:device)!
  func fixture(_ transfer:CFString,_ phase:Int,_ format:OSType) -> CVPixelBuffer {
   var allocation:CVPixelBuffer?
   precondition(CVPixelBufferCreate(nil,64,32,format,[kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary,&allocation)==kCVReturnSuccess)
   let buffer=allocation!
   CVPixelBufferLockBaseAddress(buffer,[])
   for plane in 0..<2 {
    let p=CVPixelBufferGetBaseAddressOfPlane(buffer,plane)!.assumingMemoryBound(to:UInt16.self)
    let stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,plane)/2
    let w=CVPixelBufferGetWidthOfPlane(buffer,plane),h=CVPixelBufferGetHeightOfPlane(buffer,plane)
    for y in 0..<h { for x in 0..<w {
     if plane == 0 { p[y*stride+x]=UInt16((y<h/2 ? 300 : 640)+phase)<<6 }
     else { p[y*stride+2*x]=512<<6;p[y*stride+2*x+1]=UInt16(x%2 == 0 ? 512 : 620)<<6 }
    } }
   }
   CVPixelBufferUnlockBaseAddress(buffer,[])
   CVBufferSetAttachment(buffer,kCVImageBufferTransferFunctionKey,transfer,.shouldPropagate)
   CVBufferSetAttachment(buffer,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_2020,.shouldPropagate)
   CVBufferSetAttachment(buffer,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_2020,.shouldPropagate)
   return buffer
  }
  for transfer in [kCVImageBufferTransferFunction_ITU_R_709_2,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,kCVImageBufferTransferFunction_ITU_R_2100_HLG] {
   let hdr=transfer != kCVImageBufferTransferFunction_ITU_R_709_2
   for format in [kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,kCVPixelFormatType_444YpCbCr10BiPlanarFullRange] {
    let legacy=NativeStreamNISUpscaler(device:device)
    for native in [true,false] { for phase in [0,80,0,120] {
     let input=fixture(transfer,phase,format), image=CIImage(cvPixelBuffer:input)
     let output=texture(96,48,hdr ? .bgr10a2Unorm : .bgra8Unorm), reference=texture(96,48)
     var scaled:CIImage?
     for _ in 0..<500 {
      let command=queue.makeCommandBuffer()!
      scaled=legacy.encode(image:image,sourceSize:CGSize(width:64,height:32),destinationSize:CGSize(width:96,height:48),hdr:hdr,sharpness:0.25,context:context,commandBuffer:command)
      if let scaled { context.render(scaled,to:reference,commandBuffer:command,bounds:CGRect(x:0,y:0,width:96,height:48),colorSpace:NativeStreamNISKernel.colorSpace(hdr:hdr)) }
      command.commit();await command.completed();precondition(command.status == .completed)
      if scaled != nil { break };try await Task.sleep(nanoseconds:10_000_000)
     }
     precondition(scaled != nil,legacy.status)
     var success=false
     for _ in 0..<500 {
      let pair=AsyncStream<Bool>.makeStream()
      let complete: @Sendable (Double,NSError?) -> Void = { _,error in
       if let error { print(error) };pair.continuation.yield(error == nil);pair.continuation.finish()
      }
      if native {
       success=renderer.submit(buffer:input,destination:CGRect(x:0,y:0,width:96,height:48),upscale:true,target:output,sharpening:0.25,method:.nis,completion:complete)
      } else {
       let producer=queue.makeCommandBuffer()!
       success=renderer.submit(image:image,destination:CGRect(x:0,y:0,width:96,height:48),transfer:transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG ? 2 : hdr ? 1 : 0,
        upscale:true,context:context,producer:producer,target:output,method:.nis,sharpening:0.25,completion:complete)
       if !success { producer.commit();await producer.completed() }
      }
      if success { for await ok in pair.stream { precondition(ok) };break };try await Task.sleep(nanoseconds:10_000_000)
     }
     precondition(success,renderer.status)
     var actual=[UInt32](repeating:0,count:96*48)
     actual.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:96*4,from:MTLRegionMake2D(0,0,96,48),mipmapLevel:0) }
     let ref=floats(reference);var maximum=0
     for y in 4..<44 { for x in 4..<92 { for c in 0..<3 {
      let shift=hdr ? [20,10,0][c] : [16,8,0][c],limit=hdr ? 1023 : 255
      let expected=min(limit,max(0,Int((ref[((47-y)*96+x)*4+c]*Float(limit)).rounded())))
      maximum=max(maximum,abs(Int((actual[y*96+x]>>shift)&UInt32(limit))-expected))
     } } }
     print("NIS renderer compare",native ? "native" : "CI",transfer,format,phase,"max",maximum)
     precondition(maximum<=3,"NIS Metal3/4 color/orientation mismatch")
    } }
   }
  }
  print("PASS: NIS Metal3/4 SDR/PQ/HLG colors, orientation and repeated frames")
 }
}
'''

with tempfile.TemporaryDirectory(prefix="opennow-nis-") as directory:
    temporary = Path(directory)
    shutil.copytree(app / "NIS", temporary / "NIS")
    cpp = temporary / "Reference.cpp"
    cpp.write_text('''#include "NIS_Config.h"
#include <cstdio>
#include <cstring>
int main() { bool first=true; printf("[");
 for (auto hdr : {NISHDRMode::None,NISHDRMode::PQ}) for (float s : {0.f,.25f,.5f,1.f}) {
  NISConfig c{}; if (!NVScalerUpdateConfig(c,s,0,0,37,29,37,29,0,0,43,33,43,33,hdr)) return 1;
  uint32_t words[28]; memcpy(words,&c,sizeof(words)); printf(first ? "[" : ",["); first=false;
  for(int i=0;i<28;i++) printf(i ? ",%u" : "%u",words[i]); printf("]");
 } printf("]"); }
''')
    subprocess.run(["xcrun", "clang++", "-std=c++17", "-I", str(app / "NIS"), str(cpp), "-o", str(temporary / "Reference")], check=True)
    reference = subprocess.check_output([str(temporary / "Reference")])
    json.loads(reference)
    (temporary / "reference.json").write_bytes(reference)
    (temporary / "Check.swift").write_text(source + check)
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-target", "arm64-apple-macos26.0",
                    str(temporary / "Check.swift"), "-o", str(temporary / "Check")], check=True)
    subprocess.run([str(temporary / "Check"), str(temporary / "reference.json")], check=True,
                   env=dict(os.environ, MTL_DEBUG_LAYER="1", MTL_SHADER_VALIDATION="1"), timeout=120)
