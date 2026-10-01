import Foundation
import CoreVideo
import Metal

/// Shared interpretation for rendering and actual-output status.
enum NativeStreamTenBitSurface {
    static func chroma(_ format: OSType) -> String? {
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: return "4:2:0"
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: return "4:2:2"
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: return "4:4:4"
        default: return nil
        }
    }

    static func isFullRange(_ format: OSType) -> Bool {
        [kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_444YpCbCr10BiPlanarFullRange].contains(format)
    }

    static func preserves444(_ buffer: CVPixelBuffer) -> Bool {
        chroma(CVPixelBufferGetPixelFormatType(buffer)) == "4:4:4"
            && CVPixelBufferGetPlaneCount(buffer) == 2
            && CVPixelBufferGetWidthOfPlane(buffer, 0) == CVPixelBufferGetWidthOfPlane(buffer, 1)
            && CVPixelBufferGetHeightOfPlane(buffer, 0) == CVPixelBufferGetHeightOfPlane(buffer, 1)
    }
}

/// Zero-copy bi-planar 10-bit YCbCr -> encoded BT.2020 RGB. PQ/HLG remain encoded; the matching
/// CAMetalLayer color space owns display conversion and extended dynamic range.
/// Unrecognized formats/matrices and sharpening retain the Core Image path.
final class NativeStreamHDRMetalRenderer {
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache

    init?(device: MTLDevice) {
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "hdrVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "hdrFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgr10a2Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            textureCache = cache
        } catch { return nil }
    }

    func encode(buffer: CVPixelBuffer, commandBuffer: MTLCommandBuffer,
                descriptor: MTLRenderPassDescriptor, destination: CGRect) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard NativeStreamTenBitSurface.chroma(format) != nil,
              CVPixelBufferGetPlaneCount(buffer) == 2,
              destination.width > 0, destination.height > 0,
              descriptor.colorAttachments[0].texture?.pixelFormat == .bgr10a2Unorm,
              (CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String)
                == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String else { return false }
        let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
        guard transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
                || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String else { return false }
        var yRef: CVMetalTexture?, uvRef: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil,
            .r16Unorm, CVPixelBufferGetWidthOfPlane(buffer, 0), CVPixelBufferGetHeightOfPlane(buffer, 0), 0, &yRef)
        let uvStatus = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil,
            .rg16Unorm, CVPixelBufferGetWidthOfPlane(buffer, 1), CVPixelBufferGetHeightOfPlane(buffer, 1), 1, &uvRef)
        guard yStatus == kCVReturnSuccess, uvStatus == kCVReturnSuccess,
              let yRef, let uvRef, let y = CVMetalTextureGetTexture(yRef),
              let uv = CVMetalTextureGetTexture(uvRef),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
        let full = NativeStreamTenBitSurface.isFullRange(format)
        // These bi-planar formats store 10-bit codes in the high bits of a 16-bit sample.
        // Normalize to code/1023 before applying full/video-range offsets.
        var uniforms = Uniforms(
            range: SIMD4<Float>(full ? 0 : 64.0 / 1023, full ? 1 : 876.0 / 1023,
                               512.0 / 1023, full ? 1 : 896.0 / 1023),
            coefficients: SIMD4<Float>(65535.0 / (64 * 1023), 1.4746, 1.8814, 0),
            green: SIMD4<Float>(-0.16455313, -0.57135313, 0, 0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(MTLViewport(originX: destination.minX, originY: destination.minY,
            width: destination.width, height: destination.height, znear: 0, zfar: 1))
        encoder.setFragmentTexture(y, index: 0)
        encoder.setFragmentTexture(uv, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { [buffer, yRef, uvRef] _ in
            // Keep the IOSurface-backed texture wrappers alive through GPU completion.
            _ = (buffer, yRef, uvRef)
        }
        return true
    }

    private struct Uniforms {
        var range: SIMD4<Float>
        var coefficients: SIMD4<Float>
        var green: SIMD4<Float>
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    struct Uniforms { float4 range; float4 coefficients; float4 green; };
    vertex Vertex hdrVertex(uint id [[vertex_id]]) {
        const float2 positions[] = {float2(-1,1), float2(-1,-1), float2(1,1), float2(1,-1)};
        // Decoder IOSurfaces have a top-left origin. Preserve that orientation
        // on the display; an offscreen Core Image reference has a different Y axis.
        const float2 uv[] = {float2(0,0), float2(0,1), float2(1,0), float2(1,1)};
        return {float4(positions[id],0,1), uv[id]};
    }
    fragment float4 hdrFragment(Vertex v [[stage_in]],
        texture2d<float> y [[texture(0)]], texture2d<float> uv [[texture(1)]],
        constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler sample(filter::linear, address::clamp_to_edge);
        float luma = (y.sample(sample,v.uv).r * u.coefficients.x - u.range.x) / u.range.y;
        float2 chroma = (uv.sample(sample,v.uv).rg * u.coefficients.x - u.range.z) / u.range.w;
        return float4(luma + u.coefficients.y * chroma.y,
                      luma + dot(u.green.xy,chroma),
                      luma + u.coefficients.z * chroma.x, 1);
    }
    """
}
