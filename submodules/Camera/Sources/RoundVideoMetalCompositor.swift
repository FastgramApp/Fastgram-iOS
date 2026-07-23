import Foundation
import Metal
import CoreVideo
import CoreMedia
import AVFoundation

// Converts camera NV12 into a 400x400 round-video frame in one Metal pass without RGB.
// Current limitations are hard-cut switching, synchronous rendering, and portrait iPhone only.
final class RoundVideoMetalCompositor {
    private struct Params {
        var inputWidth: UInt32
        var inputHeight: UInt32
        var outputSize: UInt32
        var isFront: UInt32
    }

    // Compile once; instances keep only per-recording mutable resources.
    static let sharedPipeline: (device: MTLDevice, pipeline: MTLComputePipelineState)? = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return nil
        }
        do {
            let library = try device.makeLibrary(source: RoundVideoMetalCompositor.shaderSource, options: nil)
            guard let function = library.makeFunction(name: "roundVideoComposite") else {
                return nil
            }
            let pipeline = try device.makeComputePipelineState(function: function)
            return (device, pipeline)
        } catch {
            return nil
        }
    }()

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?

    private let outputPool: CVPixelBufferPool
    private(set) var outputFormatDescription: CMFormatDescription?

    private let outputSize: Int = 400

    init?() {
        guard let shared = RoundVideoMetalCompositor.sharedPipeline, let commandQueue = shared.device.makeCommandQueue() else {
            return nil
        }
        self.device = shared.device
        self.commandQueue = commandQueue
        self.commandQueue.label = "RoundVideoMetalCompositor.Queue"
        self.pipelineState = shared.pipeline

        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, shared.device, nil, &textureCache) == kCVReturnSuccess, let textureCache else {
            return nil
        }
        self.textureCache = textureCache

        let poolAttributes: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 6]
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: self.outputSize,
            kCVPixelBufferHeightKey as String: self.outputSize,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as NSDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as NSDictionary, pixelBufferAttributes as NSDictionary, &pool) == kCVReturnSuccess, let pool else {
            return nil
        }
        self.outputPool = pool
    }

    func render(pixelBuffer: CVPixelBuffer, isFront: Bool) -> CVPixelBuffer? {
        guard let textureCache = self.textureCache else {
            return nil
        }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            return nil
        }

        let inputWidth = CVPixelBufferGetWidth(pixelBuffer)
        let inputHeight = CVPixelBufferGetHeight(pixelBuffer)

        var outputPixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self.outputPool, &outputPixelBuffer) == kCVReturnSuccess, let output = outputPixelBuffer else {
            return nil
        }

        // Preserve source color metadata; pooled buffers may retain prior attachments.
        // CameraOutput guarantees that both cameras use the same YCbCr matrix.
        for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey] {
            if let value = CVBufferGetAttachment(pixelBuffer, key, nil)?.takeUnretainedValue() {
                CVBufferSetAttachment(output, key, value, .shouldPropagate)
            } else {
                CVBufferRemoveAttachment(output, key)
            }
        }
        if self.outputFormatDescription == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: output, formatDescriptionOut: &self.outputFormatDescription)
        }

        // Hold the CVMetalTexture wrappers alive until the GPU work completes.
        var textureRefs: [CVMetalTexture] = []
        guard let inputY = self.planeTexture(pixelBuffer, textureCache, 0, .r8Unorm, &textureRefs),
              let inputCbCr = self.planeTexture(pixelBuffer, textureCache, 1, .rg8Unorm, &textureRefs),
              let outputY = self.planeTexture(output, textureCache, 0, .r8Unorm, &textureRefs),
              let outputCbCr = self.planeTexture(output, textureCache, 1, .rg8Unorm, &textureRefs) else {
            return nil
        }

        guard let commandBuffer = self.commandQueue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        commandBuffer.label = "RoundVideoMetalCompositor.Frame"
        encoder.label = "RoundVideoMetalCompositor.Composite"
        encoder.setComputePipelineState(self.pipelineState)
        encoder.setTexture(inputY, index: 0)
        encoder.setTexture(inputCbCr, index: 1)
        encoder.setTexture(outputY, index: 2)
        encoder.setTexture(outputCbCr, index: 3)
        var params = Params(inputWidth: UInt32(inputWidth), inputHeight: UInt32(inputHeight), outputSize: UInt32(self.outputSize), isFront: isFront ? 1 : 0)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)

        // One thread writes a 2x2 luma block and its shared chroma sample.
        let chroma = self.outputSize / 2
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupCount = MTLSize(width: (chroma + 15) / 16, height: (chroma + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        textureRefs.removeAll()

        return output
    }

    private func planeTexture(_ pixelBuffer: CVPixelBuffer, _ cache: CVMetalTextureCache, _ plane: Int, _ format: MTLPixelFormat, _ refs: inout [CVMetalTexture]) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, format, width, height, plane, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        refs.append(cvTexture)
        return texture
    }

    private static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        uint inputWidth;
        uint inputHeight;
        uint outputSize;
        uint isFront;
    };

    // Rotate the uncorrected capture buffer to portrait, mirror the front camera, and sample
    // its center square.
    static float2 sourceCoord(float2 outCoord, constant Params& p) {
        float outSize = float(p.outputSize);
        float u = outCoord.x / outSize;
        float v = outCoord.y / outSize;

        if (p.isFront != 0u) {
            u = 1.0 - u;
        }

        float ru = v;
        float rv = 1.0 - u;

        float W = float(p.inputWidth);
        float H = float(p.inputHeight);
        float su;
        float sv;
        if (W >= H) {
            su = (W - H) / (2.0 * W) + ru * (H / W);
            sv = rv;
        } else {
            su = ru;
            sv = (H - W) / (2.0 * H) + rv * (W / H);
        }
        return float2(su, sv);
    }

    // Use four taps above 1.5x decimation, where one bilinear tap visibly aliases.
    static float3 sampleSource(float2 lumaCoord, bool multiTap, constant Params& p,
                               texture2d<float, access::sample> inY,
                               texture2d<float, access::sample> inCbCr,
                               sampler s) {
        if (multiTap) {
            float3 sum = float3(0.0);
            for (int ty = 0; ty < 2; ty++) {
                for (int tx = 0; tx < 2; tx++) {
                    float2 tapCoord = lumaCoord + float2(float(tx) - 0.5, float(ty) - 0.5) * 0.5;
                    float2 src = sourceCoord(tapCoord, p);
                    sum.x += inY.sample(s, src).r;
                    float2 cc = inCbCr.sample(s, src).rg;
                    sum.y += cc.x;
                    sum.z += cc.y;
                }
            }
            return sum * 0.25;
        } else {
            float2 src = sourceCoord(lumaCoord, p);
            float2 cc = inCbCr.sample(s, src).rg;
            return float3(inY.sample(s, src).r, cc.x, cc.y);
        }
    }

    kernel void roundVideoComposite(
        texture2d<float, access::sample> inY [[texture(0)]],
        texture2d<float, access::sample> inCbCr [[texture(1)]],
        texture2d<float, access::write> outY [[texture(2)]],
        texture2d<float, access::write> outCbCr [[texture(3)]],
        constant Params& p [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        uint chromaSize = p.outputSize / 2u;
        if (gid.x >= chromaSize || gid.y >= chromaSize) {
            return;
        }

        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);

        float outSize = float(p.outputSize);
        // Match legacy's radius-202 mask and feather its edge by about 1.5 pixels.
        float radius = outSize * 0.5 + 2.0;
        float2 center = float2(outSize * 0.5, outSize * 0.5);

        bool multiTap = (min(float(p.inputWidth), float(p.inputHeight)) / outSize) > 1.5;

        // White in video-range YUV.
        const float whiteY = 235.0 / 255.0;
        const float whiteC = 128.0 / 255.0;

        float cbSum = 0.0;
        float crSum = 0.0;
        for (uint dy = 0u; dy < 2u; dy++) {
            for (uint dx = 0u; dx < 2u; dx++) {
                uint2 lumaPos = uint2(gid.x * 2u + dx, gid.y * 2u + dy);
                float2 lumaCoord = float2(float(lumaPos.x) + 0.5, float(lumaPos.y) + 0.5);
                float whiteMix = smoothstep(radius - 0.75, radius + 0.75, distance(lumaCoord, center));
                float yVal;
                float cbVal;
                float crVal;
                if (whiteMix >= 1.0) {
                    yVal = whiteY;
                    cbVal = whiteC;
                    crVal = whiteC;
                } else {
                    float3 yuv = sampleSource(lumaCoord, multiTap, p, inY, inCbCr, s);
                    yVal = mix(yuv.x, whiteY, whiteMix);
                    cbVal = mix(yuv.y, whiteC, whiteMix);
                    crVal = mix(yuv.z, whiteC, whiteMix);
                }
                outY.write(float4(yVal, 0.0, 0.0, 1.0), lumaPos);
                cbSum += cbVal;
                crSum += crVal;
            }
        }
        outCbCr.write(float4(cbSum * 0.25, crSum * 0.25, 0.0, 1.0), gid);
    }
    """
}
