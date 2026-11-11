import Metal
import simd

/// Draws a TrackOverlay's tube with Metal (experimental renderer): the
/// overlay's CPU geometry, uploaded to buffers whenever it's rebuilt, drawn
/// after the tiles and depth-tested against them (reverse Z, as
/// MetalTileRenderer). One per host, since each host's map has its own
/// track; the shaders and pipelines are shared.
@MainActor
final class MetalTrackRenderer {
    private let device: MTLDevice
    private var vertices: MTLBuffer?
    private var indices: MTLBuffer?
    private var indexCount = 0
    /// The overlay generation the buffers hold.
    private var uploaded: (overlay: ObjectIdentifier, generation: Int)?

    nonisolated init(device: MTLDevice) {
        self.device = device
    }

    /// Draws `overlay`'s tube, if it's shown, at `model` (the overlay root's
    /// frame → scene) after `viewProjection` (scene → clip, reverse Z).
    func encode(_ encoder: MTLRenderCommandEncoder, colour: MTLPixelFormat, depth: MTLPixelFormat,
                viewProjection: simd_float4x4, model: simd_float4x4, overlay: TrackOverlay) {
        guard overlay.isEnabled else { return }
        upload(overlay)
        guard indexCount > 0, let vertices, let indices,
              let shared = Self.shared(device), let pipeline = shared.pipeline(colour: colour, depth: depth)
        else { return }
        let c = TrackOverlay.colour
        var uniforms = Uniforms(modelViewProjection: viewProjection * model, model: model,
                                colour: SIMD4(pow(c.x, 2.2), pow(c.y, 2.2), pow(c.z, 2.2), 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(shared.depthState)
        encoder.setCullMode(.none)  // The tube's ends are open.
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint32,
                                      indexBuffer: indices, indexBufferOffset: 0)
    }

    /// New buffers when the tube has been rebuilt. Fresh buffers each time
    /// (rather than rewriting in place) so frames still on the GPU keep
    /// theirs; rebuilds are a few a second at most (TrackOverlay).
    private func upload(_ overlay: TrackOverlay) {
        let key = (ObjectIdentifier(overlay), overlay.generation)
        if let uploaded, uploaded == key { return }
        uploaded = key
        let geometry = overlay.geometry
        indexCount = geometry.indices.count
        guard indexCount > 0 else {
            vertices = nil
            indices = nil
            return
        }
        vertices = geometry.vertices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        indices = geometry.indices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        if vertices == nil || indices == nil { indexCount = 0 }
    }

    // MARK: Shared state

    /// Must match TrackUniforms in `shaderSource`.
    private struct Uniforms {
        var modelViewProjection: simd_float4x4
        var model: simd_float4x4
        var colour: SIMD4<Float>
    }

    /// The library, depth state and pipelines, made once per device.
    private final class Shared {
        let device: MTLDevice
        let library: MTLLibrary
        let depthState: MTLDepthStencilState
        private var pipelines: [SIMD2<UInt>: MTLRenderPipelineState] = [:]

        init?(device: MTLDevice) {
            self.device = device
            let depth = MTLDepthStencilDescriptor()
            depth.depthCompareFunction = .greater
            depth.isDepthWriteEnabled = true
            do {
                library = try device.makeLibrary(source: MetalTrackRenderer.shaderSource, options: nil)
            } catch {
                print("[AlsoMaps] Metal track shaders failed: \(error)")
                return nil
            }
            guard let depthState = device.makeDepthStencilState(descriptor: depth) else { return nil }
            self.depthState = depthState
        }

        func pipeline(colour: MTLPixelFormat, depth: MTLPixelFormat) -> MTLRenderPipelineState? {
            let key = SIMD2(colour.rawValue, depth.rawValue)
            if let pipeline = pipelines[key] { return pipeline }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "trackVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "trackFragment")
            descriptor.colorAttachments[0].pixelFormat = colour
            descriptor.depthAttachmentPixelFormat = depth
            do {
                let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                pipelines[key] = pipeline
                return pipeline
            } catch {
                print("[AlsoMaps] Metal track pipeline failed: \(error)")
                return nil
            }
        }
    }

    private static var sharedByDevice: [ObjectIdentifier: Shared] = [:]

    private static func shared(_ device: MTLDevice) -> Shared? {
        let key = ObjectIdentifier(device)
        if let shared = sharedByDevice[key] { return shared }
        guard let shared = Shared(device: device) else { return nil }
        sharedByDevice[key] = shared
        return shared
    }

    // Lit like TrackOverlay's material: its colour shaded by a light from
    // above, plus some of it as emission so the side away from the light
    // isn't dark.
    private static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

// Must match MetalTrackRenderer.Uniforms.
struct TrackUniforms {
    float4x4 modelViewProjection;
    float4x4 model;
    float4 colour;
};

// Must match TubeExtruder.Vertex.
struct TrackVertex {
    float3 position;
    float3 normal;
};

struct TrackVertexOut {
    float4 position [[position]];
    float3 normal;
};

vertex TrackVertexOut trackVertex(uint vid [[vertex_id]],
                                  const device TrackVertex *vertices [[buffer(0)]],
                                  constant TrackUniforms &uniforms [[buffer(1)]]) {
    TrackVertexOut out;
    out.position = uniforms.modelViewProjection * float4(vertices[vid].position, 1);
    out.normal = (uniforms.model * float4(vertices[vid].normal, 0)).xyz;
    return out;
}

fragment float4 trackFragment(TrackVertexOut in [[stage_in]],
                              constant TrackUniforms &uniforms [[buffer(0)]]) {
    float light = max(dot(normalize(in.normal), normalize(float3(0.3, 1, 0.2))), 0.0);
    return float4(uniforms.colour.rgb * (0.45 + 0.55 * light), 1);
}
"""
}
