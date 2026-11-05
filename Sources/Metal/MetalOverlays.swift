import CoreGraphics
import CoreText
import Foundation
import Metal
import simd

/// Small extras drawn over the Metal renderer's tiles: wireframe bounds boxes
/// (a debug view) and a textured quad (the credits in the immersive space).
/// It has its own shader library and pipelines so MetalTileRenderer's stay
/// untouched. Like the renderer, it compiles its shaders from source at launch.
final class MetalOverlayRenderer: @unchecked Sendable {
    /// `ALSOMAPS_METAL_DEBUG=bounds`: wireframe boxes round each submitted
    /// tile (and each part of a multi-part tile, fainter), coloured by the
    /// tile's size: blue for the largest (coarsest) to red for the smallest
    /// (finest). The tiles carry no level of their own, so size stands in for
    /// it. Read once. The boxes show through the tiles.
    static let drawsBounds: Bool = {
        let value = ProcessInfo.processInfo.environment["ALSOMAPS_METAL_DEBUG"] ?? ""
        return value.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "bounds" }
    }()

    private let device: MTLDevice
    private let library: MTLLibrary
    /// Always passes, writes nothing: boxes show through the tiles.
    private let boxDepthState: MTLDepthStencilState
    /// Always passes and writes the quad's depth, for a compositor's reprojection.
    private let quadDepthState: MTLDepthStencilState
    private var pipelines: [SIMD3<UInt>: MTLRenderPipelineState] = [:]
    private let pipelinesLock = NSLock()

    /// Must match BoxUniforms in `shaderSource`.
    private struct BoxUniforms {
        var modelViewProjection: simd_float4x4
        var minimum: SIMD4<Float>
        var maximum: SIMD4<Float>
        var colour: SIMD4<Float>
    }

    /// Must match QuadUniforms in `shaderSource`.
    private struct QuadUniforms {
        var modelViewProjection: simd_float4x4
        var halfSize: SIMD4<Float>
    }

    enum Kind: UInt { case boxes, quad }

    init?(device: MTLDevice) {
        self.device = device
        let always = MTLDepthStencilDescriptor()
        always.depthCompareFunction = .always
        always.isDepthWriteEnabled = false
        let alwaysWriting = MTLDepthStencilDescriptor()
        alwaysWriting.depthCompareFunction = .always
        alwaysWriting.isDepthWriteEnabled = true
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let boxDepthState = device.makeDepthStencilState(descriptor: always),
              let quadDepthState = device.makeDepthStencilState(descriptor: alwaysWriting)
        else {
            print("[AlsoMaps] Metal overlays unavailable")
            return nil
        }
        self.library = library
        self.boxDepthState = boxDepthState
        self.quadDepthState = quadDepthState
    }

    private func pipeline(_ kind: Kind, colour: MTLPixelFormat, depth: MTLPixelFormat) -> MTLRenderPipelineState? {
        let key = SIMD3(kind.rawValue, colour.rawValue, depth.rawValue)
        pipelinesLock.lock()
        defer { pipelinesLock.unlock() }
        if let pipeline = pipelines[key] { return pipeline }
        let descriptor = MTLRenderPipelineDescriptor()
        switch kind {
        case .boxes:
            descriptor.vertexFunction = library.makeFunction(name: "boxVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "boxFragment")
        case .quad:
            descriptor.vertexFunction = library.makeFunction(name: "quadVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "quadFragment")
        }
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = colour
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = kind == .boxes ? .sourceAlpha : .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = depth
        do {
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelines[key] = pipeline
            return pipeline
        } catch {
            print("[AlsoMaps] Metal overlay pipeline failed: \(error)")
            return nil
        }
    }

    // MARK: Bounds boxes

    struct Box {
        let bounds: MetalBounds
        /// Tile-local → clip.
        let modelViewProjection: simd_float4x4
        let colour: SIMD4<Float>
    }

    /// Blue (largest) to red (smallest) by the box's diagonal, from about
    /// 16 m to 16 km on a log scale.
    static func colour(forDiagonal diagonal: Float, alpha: Float) -> SIMD4<Float> {
        let t = min(max((log2(max(diagonal, 1)) - 4) / 10, 0), 1)
        // Hue 240° (t = 1) down to 0° (t = 0).
        let hue = t * 4 // 0...4 sextants, red → blue
        let x = 1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1)
        let rgb: SIMD3<Float>
        switch Int(hue) {
        case 0: rgb = [1, x, 0]
        case 1: rgb = [x, 1, 0]
        case 2: rgb = [0, 1, x]
        case 3: rgb = [0, x, 1]
        default: rgb = [0, 0, 1]
        }
        return SIMD4(rgb, alpha)
    }

    /// 12 edges of each box as lines. Call after the tiles.
    func encodeBoxes(_ encoder: MTLRenderCommandEncoder, colour: MTLPixelFormat, depth: MTLPixelFormat, boxes: [Box]) {
        guard !boxes.isEmpty, let pipeline = pipeline(.boxes, colour: colour, depth: depth) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(boxDepthState)
        encoder.setCullMode(.none)
        for box in boxes {
            var uniforms = BoxUniforms(modelViewProjection: box.modelViewProjection,
                                       minimum: SIMD4(box.bounds.minimum, 0),
                                       maximum: SIMD4(box.bounds.maximum, 0),
                                       colour: box.colour)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<BoxUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 24)
        }
    }

    // MARK: Credits quad

    /// The credits as a bitmap, with the quad's size in metres, kept until
    /// the text changes.
    private var creditsTexture: MTLTexture?
    private var creditsKey: String?

    /// Metres. The aspect matches the bitmap.
    static let creditsWidth: Float = 0.64
    static let creditsPixels = (width: 1024, height: 160)

    /// Rebuilds the credits bitmap when `text` or the logo's presence
    /// changes. Main-thread use only (as the immersive frame loop does).
    /// With nothing to show, `encodeCredits` draws nothing.
    func updateCredits(text: String, logo: CGImage?) {
        let key = "\(logo != nil)|\(text)"
        guard key != creditsKey else { return }
        creditsKey = key
        guard !text.isEmpty || logo != nil,
              let bitmap = Self.creditsBitmap(text: text, logo: logo)
        else {
            creditsTexture = nil
            return
        }
        let (width, height) = Self.creditsPixels
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            creditsTexture = nil
            return
        }
        bitmap.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: base, bytesPerRow: width * 4)
        }
        creditsTexture = texture
    }

    /// Premultiplied RGBA rows, top first (as a CGContext stores them, and
    /// as Metal's texture origin reads them): a translucent dark backing
    /// (Google's logo is white), the logo at the left, and the text wrapped
    /// beside it in the largest size from 34 to 18 points that fits.
    static func creditsBitmap(text: String, logo: CGImage?) -> Data? {
        let (width, height) = creditsPixels
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(bounds)
        context.setFillColor(CGColor(gray: 0, alpha: 0.65))
        let backing = CGPath(roundedRect: bounds, cornerWidth: 28, cornerHeight: 28, transform: nil)
        context.addPath(backing)
        context.fillPath()

        let margin: CGFloat = 24
        var textLeft = margin
        if let logo {
            let logoHeight = CGFloat(height) - 2 * margin
            let logoWidth = logoHeight * CGFloat(logo.width) / CGFloat(max(logo.height, 1))
            context.draw(logo, in: CGRect(x: margin, y: margin, width: logoWidth, height: logoHeight))
            textLeft = margin + logoWidth + margin
        }
        if !text.isEmpty {
            let area = CGRect(x: textLeft, y: margin, width: CGFloat(width) - textLeft - margin,
                              height: CGFloat(height) - 2 * margin)
            var size: CGFloat = 34
            var frame: CTFrame?
            while size >= 18 {
                let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
                let string = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
                ])
                let setter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
                let fitted = CTFramesetterSuggestFrameSizeWithConstraints(
                    setter, CFRange(location: 0, length: 0), nil,
                    CGSize(width: area.width, height: .greatestFiniteMagnitude), nil)
                if fitted.height <= area.height || size == 18 {
                    // Vertically centred in the area; anything beyond the
                    // smallest size is clipped.
                    let top = min(fitted.height, area.height)
                    let box = CGRect(x: area.minX, y: area.midY - top / 2, width: area.width, height: top)
                    frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                                     CGPath(rect: box, transform: nil), nil)
                    break
                }
                size -= 2
            }
            if let frame { CTFrameDraw(frame, context) }
        }
        guard let data = context.data else { return nil }
        return Data(bytes: data, count: width * 4 * height)
    }

    /// Draws the credits quad, if there is one, over everything (it ignores
    /// depth, so geometry nearer than the quad can't hide it). `model` places
    /// the quad's centre and orientation (scene frame); it faces +z.
    func encodeCredits(_ encoder: MTLRenderCommandEncoder, colour: MTLPixelFormat, depth: MTLPixelFormat,
                       viewProjection: simd_float4x4, model: simd_float4x4) {
        guard let texture = creditsTexture, let pipeline = pipeline(.quad, colour: colour, depth: depth) else { return }
        let (width, height) = Self.creditsPixels
        let half = Self.creditsWidth / 2
        var uniforms = QuadUniforms(modelViewProjection: viewProjection * model,
                                    halfSize: SIMD4(half, half * Float(height) / Float(width), 0, 0))
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(quadDepthState)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<QuadUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private static let shaderSource = """
#include <metal_stdlib>
using namespace metal;

// Must match MetalOverlayRenderer.BoxUniforms.
struct BoxUniforms {
    float4x4 modelViewProjection;
    float4 minimum;
    float4 maximum;
    float4 colour;
};

struct BoxOut {
    float4 position [[position]];
    float4 colour;
};

/// Vertex i of 24 is one end of edge i / 2 of a box. Corner bits are x, y, z
/// (0 = minimum, 1 = maximum); an edge along `axis` joins the two corners
/// that differ in that bit, the other two bits counting through `edge % 4`.
vertex BoxOut boxVertex(uint vid [[vertex_id]], constant BoxUniforms &uniforms [[buffer(0)]]) {
    uint edge = vid / 2;
    uint axis = edge / 4;
    uint k = edge % 4;
    uint lowMask = (1u << axis) - 1;
    uint corner = (k & lowMask) | ((k & ~lowMask) << 1) | ((vid & 1) << axis);
    float3 point = float3((corner & 1) ? uniforms.maximum.x : uniforms.minimum.x,
                          (corner & 2) ? uniforms.maximum.y : uniforms.minimum.y,
                          (corner & 4) ? uniforms.maximum.z : uniforms.minimum.z);
    BoxOut out;
    out.position = uniforms.modelViewProjection * float4(point, 1);
    out.colour = uniforms.colour;
    return out;
}

fragment float4 boxFragment(BoxOut in [[stage_in]]) {
    return in.colour;
}

// Must match MetalOverlayRenderer.QuadUniforms.
struct QuadUniforms {
    float4x4 modelViewProjection;
    float4 halfSize;
};

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

/// A triangle strip of four corners: (-1,-1) (1,-1) (-1,1) (1,1).
vertex QuadOut quadVertex(uint vid [[vertex_id]], constant QuadUniforms &uniforms [[buffer(0)]]) {
    float2 corner = float2((vid & 1) ? 1 : -1, (vid & 2) ? 1 : -1);
    QuadOut out;
    out.position = uniforms.modelViewProjection * float4(corner * uniforms.halfSize.xy, 0, 1);
    // The bitmap's first row is the top.
    out.uv = float2((corner.x + 1) * 0.5, (1 - corner.y) * 0.5);
    return out;
}

/// The bitmap is premultiplied; blending is one / one-minus-source-alpha.
fragment float4 quadFragment(QuadOut in [[stage_in]], texture2d<float> texture [[texture(0)]]) {
    constexpr sampler textureSampler(filter::linear, address::clamp_to_edge);
    return texture.sample(textureSampler, in.uv);
}
"""
}
