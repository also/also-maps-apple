import Foundation
import Metal
import simd

/// Draws the hand controls' overlay in the Metal immersive space: the
/// pointing ray, its hit marker and grabbing hands (HandControlController).
/// Lines are flat ribbons turned to face each eye, drawn after the tiles
/// with alpha blending: once faintly through everything, so the ray and
/// marker stay visible behind terrain, and once at full strength where
/// they're in front.
final class MetalHandOverlay {
    /// A line from `a` to `b` in the immersive space.
    struct Segment {
        var a: SIMD3<Float>
        var b: SIMD3<Float>
        /// Linear RGB and alpha.
        var colour: SIMD4<Float>
        /// Metres.
        var width: Float
    }

    /// Must match HandOverlayUniforms.
    private struct Uniforms {
        var viewProjection: simd_float4x4
        var alpha: Float
    }

    private struct Vertex {
        var position: SIMD4<Float>
        var colour: SIMD4<Float>
    }

    private let device: MTLDevice
    private let library: MTLLibrary
    private let throughState: MTLDepthStencilState
    private let frontState: MTLDepthStencilState
    private var pipelines: [SIMD2<UInt>: MTLRenderPipelineState] = [:]

    init?(device: MTLDevice) {
        self.device = device
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil) else { return nil }
        self.library = library
        let through = MTLDepthStencilDescriptor()
        through.depthCompareFunction = .always
        through.isDepthWriteEnabled = false
        // Reverse Z: nearer is greater.
        let front = MTLDepthStencilDescriptor()
        front.depthCompareFunction = .greaterEqual
        front.isDepthWriteEnabled = false
        guard let throughState = device.makeDepthStencilState(descriptor: through),
              let frontState = device.makeDepthStencilState(descriptor: front)
        else { return nil }
        self.throughState = throughState
        self.frontState = frontState
    }

    private func pipeline(colour: MTLPixelFormat, depth: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = SIMD2(colour.rawValue, depth.rawValue)
        if let pipeline = pipelines[key] { return pipeline }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "handOverlayVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "handOverlayFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = colour
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = depth
        do {
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = pipeline
            return pipeline
        } catch {
            print("[AlsoMaps] hand overlay pipeline failed: \(error)")
            return nil
        }
    }

    /// Draws `segments` for one view: `viewProjection` takes the immersive
    /// space to clip space, and `eye` is that view's position in it.
    func encode(_ encoder: MTLRenderCommandEncoder, colour: MTLPixelFormat, depth: MTLPixelFormat,
                viewProjection: simd_float4x4, eye: SIMD3<Float>, segments: [Segment]) {
        guard !segments.isEmpty, let pipeline = pipeline(colour: colour, depth: depth) else { return }
        var vertices: [Vertex] = []
        vertices.reserveCapacity(segments.count * 6)
        for segment in segments {
            let along = segment.b - segment.a
            let toEye = eye - (segment.a + segment.b) / 2
            var side = simd_cross(along, toEye)
            guard simd_length(side) > 1e-9 else { continue }
            side = simd_normalize(side) * segment.width / 2
            let corners = [segment.a - side, segment.a + side, segment.b + side, segment.b - side]
            for i in [0, 1, 2, 0, 2, 3] {
                vertices.append(Vertex(position: SIMD4(corners[i], 1), colour: segment.colour))
            }
        }
        guard !vertices.isEmpty,
              let buffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<Vertex>.stride)
        else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        for (state, alpha) in [(throughState, Float(0.3)), (frontState, Float(1))] {
            var uniforms = Uniforms(viewProjection: viewProjection, alpha: alpha)
            encoder.setDepthStencilState(state)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }
    }

    // MARK: Shapes

    /// A ring of `radius` metres about `centre`, in the plane normal to `up`.
    static func ring(centre: SIMD3<Float>, up: SIMD3<Float>, radius: Float, colour: SIMD4<Float>,
                     width: Float, sides: Int = 32) -> [Segment] {
        let n = simd_normalize(up)
        let helper: SIMD3<Float> = abs(n.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
        let u = simd_normalize(simd_cross(n, helper)), v = simd_cross(n, u)
        func point(_ i: Int) -> SIMD3<Float> {
            let angle = Float(i) / Float(sides) * 2 * .pi
            return centre + (u * cos(angle) + v * sin(angle)) * radius
        }
        return (0..<sides).map { Segment(a: point($0), b: point($0 + 1), colour: colour, width: width) }
    }

    /// A small three-axis cross at `centre`.
    static func cross(centre: SIMD3<Float>, size: Float, colour: SIMD4<Float>, width: Float) -> [Segment] {
        let axes: [SIMD3<Float>] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        return axes.map { Segment(a: centre - $0 * size, b: centre + $0 * size, colour: colour, width: width) }
    }

    private static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct HandOverlayVertex {
    float4 position;
    float4 colour;
};

struct HandOverlayUniforms {
    float4x4 viewProjection;
    float alpha;
};

struct HandOverlayOut {
    float4 position [[position]];
    float4 colour;
};

vertex HandOverlayOut handOverlayVertex(uint vid [[vertex_id]],
                                        const device HandOverlayVertex *vertices [[buffer(0)]],
                                        constant HandOverlayUniforms &uniforms [[buffer(1)]]) {
    HandOverlayOut out;
    out.position = uniforms.viewProjection * vertices[vid].position;
    out.colour = vertices[vid].colour;
    out.colour.a *= uniforms.alpha;
    return out;
}

fragment float4 handOverlayFragment(HandOverlayOut in [[stage_in]]) {
    return in.colour;
}
"""
}
