import CoreGraphics
import Foundation
import RealityKit

/// A tile's entity, with what it takes to put an overlay on its parts and
/// take it off again.
final class TileEntity: Entity {
    struct TexturedPart {
        var model: ModelEntity
        var material: UnlitMaterial
        var texture: TextureResource
    }

    var texturedParts: [TexturedPart] = []
    /// Counts overlay changes, so a texture that finishes late for an overlay
    /// the tile has since lost is dropped.
    var overlayGeneration = 0
    var isDraped = false
}

/// Paints cesium-native's raster overlays onto tiles: lines become part of the
/// surface's texture, so they need no heights and can't float above it or
/// sink into it. Tiles with something to show swap their UnlitMaterial for a
/// shader graph that composites the overlay over the photo texture; every
/// other tile is drawn as usual.
@MainActor
final class TraceDrape {
    private let material = Task { @MainActor () -> ShaderGraphMaterial? in
        do {
            return try await ShaderGraphMaterial(named: "/Root/DrapedTile", from: Data(TraceDrape.materialUSDA.utf8))
        } catch {
            print("[AlsoMaps] couldn't load the draped tile material: \(error)")
            return nil
        }
    }
    /// Tiles that lost their overlay this frame. Cesium-native detaches one
    /// raster just before attaching a better one, so these wait for the end
    /// of the frame rather than flash the bare tile.
    private var detached: [TileEntity] = []
    /// For the debug log: rasters attached, those with nothing to show, those
    /// for tiles with no drapable parts, and tiles draped.
    private(set) var attachedRasters = 0
    private(set) var emptyRasters = 0
    private(set) var undrapableTiles = 0
    private(set) var drapedTiles = 0

    func attach(_ tile: CNTileMesh, raster: CNRasterImage, translation: SIMD2<Float>, scale: SIMD2<Float>) {
        attachedRasters += 1
        guard let entity = tile.renderObject as? TileEntity, !entity.texturedParts.isEmpty else {
            undrapableTiles += 1
            return
        }
        // Tiles no line touches get a single transparent pixel.
        guard raster.width > 1, raster.height > 1,
              let image = TileUploader.image(rgba: raster.rgba, width: raster.width, height: raster.height) else {
            emptyRasters += 1
            detach(tile)
            return
        }
        detached.removeAll { $0 === entity }
        entity.overlayGeneration += 1
        let generation = entity.overlayGeneration
        Task {
            guard let material = await material.value,
                  let texture = try? await TextureResource(image: image, options: .init(semantic: .color,
                                                                                        mipmapsMode: .allocateAndGenerateAll)),
                  entity.overlayGeneration == generation else { return }
            do {
                for part in entity.texturedParts {
                    var draped = material
                    try draped.setParameter(name: "Base", value: .textureResource(part.texture))
                    try draped.setParameter(name: "Overlay", value: .textureResource(texture))
                    try draped.setParameter(name: "OverlayTranslation", value: .simd2Float(translation))
                    try draped.setParameter(name: "OverlayScale", value: .simd2Float(scale))
                    part.model.model?.materials = [draped]
                }
                entity.isDraped = true
                drapedTiles += 1
            } catch {
                print("[AlsoMaps] couldn't drape tile \(tile.identifier): \(error)")
            }
        }
    }

    func detach(_ tile: CNTileMesh) {
        guard let entity = tile.renderObject as? TileEntity else { return }
        detached.append(entity)
    }

    /// Call once a frame, after the streamer's update.
    func finishFrame() {
        for entity in detached {
            entity.overlayGeneration += 1
            guard entity.isDraped else { continue }
            for part in entity.texturedParts {
                part.model.model?.materials = [part.material]
            }
            entity.isDraped = false
        }
        detached.removeAll()
    }

    /// The overlay over the photo: `overlay.rgb + photo * (1 - overlay.a)`,
    /// the overlay being premultiplied. Unlit, as photogrammetry has its
    /// lighting baked in, and tone mapped like UnlitMaterial, so draped tiles
    /// match the plain ones beside them.
    private static let materialUSDA = #"""
    #usda 1.0
    (
        defaultPrim = "Root"
        metersPerUnit = 1
        upAxis = "Y"
    )

    def Xform "Root"
    {
        def Material "DrapedTile"
        {
            asset inputs:Base (customData = { dictionary realitykit = { bool isParameter = 1 } })
            asset inputs:Overlay (customData = { dictionary realitykit = { bool isParameter = 1 } })
            float2 inputs:OverlayScale = (1, 1)
            float2 inputs:OverlayTranslation = (0, 0)
            token outputs:mtlx:surface.connect = </Root/DrapedTile/Unlit.outputs:out>

            def Shader "Unlit"
            {
                uniform token info:id = "ND_realitykit_unlit_surfaceshader"
                bool inputs:applyPostProcessToneMap = 1
                color3f inputs:color.connect = </Root/DrapedTile/Composite.outputs:out>
                token outputs:out
            }

            def Shader "BaseUV"
            {
                uniform token info:id = "ND_texcoord_vector2"
                int inputs:index = 0
                float2 outputs:out
            }

            def Shader "OverlayUV"
            {
                uniform token info:id = "ND_texcoord_vector2"
                int inputs:index = 1
                float2 outputs:out
            }

            def Shader "Scaled"
            {
                uniform token info:id = "ND_multiply_vector2"
                float2 inputs:in1.connect = </Root/DrapedTile/OverlayUV.outputs:out>
                float2 inputs:in2.connect = </Root/DrapedTile.inputs:OverlayScale>
                float2 outputs:out
            }

            def Shader "Placed"
            {
                uniform token info:id = "ND_add_vector2"
                float2 inputs:in1.connect = </Root/DrapedTile/Scaled.outputs:out>
                float2 inputs:in2.connect = </Root/DrapedTile.inputs:OverlayTranslation>
                float2 outputs:out
            }

            def Shader "BaseImage"
            {
                uniform token info:id = "ND_image_color3"
                asset inputs:file.connect = </Root/DrapedTile.inputs:Base>
                float2 inputs:texcoord.connect = </Root/DrapedTile/BaseUV.outputs:out>
                color3f outputs:out
            }

            def Shader "OverlayImage"
            {
                uniform token info:id = "ND_image_color4"
                asset inputs:file.connect = </Root/DrapedTile.inputs:Overlay>
                float2 inputs:texcoord.connect = </Root/DrapedTile/Placed.outputs:out>
                string inputs:uaddressmode = "clamp"
                string inputs:vaddressmode = "clamp"
                color4f outputs:out
            }

            def Shader "OverlayRGB"
            {
                uniform token info:id = "ND_convert_color4_color3"
                color4f inputs:in.connect = </Root/DrapedTile/OverlayImage.outputs:out>
                color3f outputs:out
            }

            def Shader "OverlayAlpha"
            {
                uniform token info:id = "ND_separate4_color4"
                color4f inputs:in.connect = </Root/DrapedTile/OverlayImage.outputs:out>
                float outputs:outa
            }

            def Shader "Remaining"
            {
                uniform token info:id = "ND_subtract_float"
                float inputs:in1 = 1
                float inputs:in2.connect = </Root/DrapedTile/OverlayAlpha.outputs:outa>
                float outputs:out
            }

            def Shader "Photo"
            {
                uniform token info:id = "ND_multiply_color3FA"
                color3f inputs:in1.connect = </Root/DrapedTile/BaseImage.outputs:out>
                float inputs:in2.connect = </Root/DrapedTile/Remaining.outputs:out>
                color3f outputs:out
            }

            def Shader "Composite"
            {
                uniform token info:id = "ND_add_color3"
                color3f inputs:in1.connect = </Root/DrapedTile/OverlayRGB.outputs:out>
                color3f inputs:in2.connect = </Root/DrapedTile/Photo.outputs:out>
                color3f outputs:out
            }
        }
    }
    """#
}
