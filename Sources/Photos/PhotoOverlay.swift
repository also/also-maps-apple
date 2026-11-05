import CoreGraphics
import Foundation
import RealityKit

/// The user's photos in the scene, in the map frame:
///
/// - **Markers:** each photo's thumbnail on a short post at its position,
///   facing back toward where the photographer stood, so it reads as it
///   did through the viewfinder from behind. The host picks each marker's
///   size in the world: in a room, the same size in the room at any map
///   scale (like the track's tube); on a screen, in proportion to its
///   distance, so it stays a readable size.
/// - **The frame:** the photo being stood in, at its true angular size
///   straight ahead of the eye, faded by the opacity slider, so photo and
///   world line up. Used in the immersive space; the Mac draws it in
///   SwiftUI over the view instead.
///
/// Everything is placed each frame from the georeference composed in
/// double, so the Float transforms stay small and move with the tiles.
@MainActor
final class PhotoOverlay {
    let root = Entity()
    /// The frame's root: straight ahead of the eye, facing it. Its children
    /// are the picture and, in the immersive space, the photo controls.
    let frame = Entity()
    private let framePicture = ModelEntity(mesh: PhotoOverlay.plane, materials: [PhotoOverlay.placeholder])
    /// Which photo's image the frame's material holds.
    private var frameImage: PlacedPhoto.ID?
    private var controls: Entity?
    private var markers: [PlacedPhoto.ID: Marker] = [:]

    /// The post's height and radius, as fractions of the marker's width.
    private static let postHeight: Float = 0.8
    private static let postRadius: Float = 0.02

    /// A unit square in x and y, facing +z.
    private static let plane = MeshResource.generatePlane(width: 1, height: 1)
    private static let post = MeshResource.generateCylinder(height: 1, radius: 1)
    private static let placeholder: Material = UnlitMaterial(color: .gray)
    private static let backMaterial: Material = UnlitMaterial(color: .darkGray)
    private static let postMaterial: Material = UnlitMaterial(color: .white)

    @MainActor
    private final class Marker {
        let entity = Entity()
        let picture = ModelEntity(mesh: PhotoOverlay.plane, materials: [PhotoOverlay.placeholder])
        let back = ModelEntity(mesh: PhotoOverlay.plane, materials: [PhotoOverlay.backMaterial])
        let post = ModelEntity(mesh: PhotoOverlay.post, materials: [PhotoOverlay.postMaterial])

        init(aspect: Double) {
            let height = Float(1 / max(aspect, 0.1))
            let centre = PhotoOverlay.postHeight + height / 2
            picture.scale = [1, height, 1]
            picture.position = [0, centre, 0]
            // The back faces the way the camera looked, a hair behind.
            back.scale = [1, height, 1]
            back.position = [0, centre, -0.002]
            back.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
            post.scale = [PhotoOverlay.postRadius, PhotoOverlay.postHeight, PhotoOverlay.postRadius]
            post.position = [0, PhotoOverlay.postHeight / 2, 0]
            entity.addChild(picture)
            entity.addChild(back)
            entity.addChild(post)
        }
    }

    init() {
        root.addChild(frame)
        frame.addChild(framePicture)
        frame.isEnabled = false
    }

    var isEnabled: Bool {
        get { root.isEnabled }
        set { root.isEnabled = newValue }
    }

    // MARK: Markers

    /// Places a marker for each photo, `width` world metres across at its
    /// base (ECEF), hiding `hidden` (the one being stood in, which would be
    /// in your face) and any without a height yet.
    func updateMarkers(_ photos: [PlacedPhoto], hiding hidden: PlacedPhoto.ID?,
                       georeference: Georeference, width: (SIMD3<Double>) -> Double) {
        guard root.isEnabled, georeference.scale > 0 else { return }
        var seen = Set<PlacedPhoto.ID>()
        for photo in photos {
            seen.insert(photo.id)
            let marker = markers[photo.id] ?? makeMarker(photo)
            guard photo.id != hidden, let coordinate = photo.coordinate,
                  let baseHeight = photo.ground ?? photo.metadata.altitude
            else {
                marker.entity.isEnabled = false
                continue
            }
            let base = Geodesy.ecef(coordinate, height: baseHeight)
            let size = width(base) * georeference.scale
            let rotation = georeference.rotation
                * PhotoPose.markerRotation(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                           heading: photo.heading)
            marker.entity.isEnabled = size.isFinite && size > 0
            marker.entity.transform = Transform(scale: SIMD3(repeating: Float(size)),
                                                rotation: simd_quatf(vector: SIMD4<Float>(rotation.vector)),
                                                translation: SIMD3<Float>(georeference.map(base)))
        }
        for (id, marker) in markers where !seen.contains(id) {
            marker.entity.removeFromParent()
            markers[id] = nil
        }
    }

    private func makeMarker(_ photo: PlacedPhoto) -> Marker {
        let marker = Marker(aspect: photo.fieldOfView.aspect)
        markers[photo.id] = marker
        root.addChild(marker.entity)
        let thumbnail = photo.thumbnail
        Task { [weak marker] in
            guard let material = await Self.material(for: thumbnail) else { return }
            marker?.picture.model?.materials = [material]
        }
        return marker
    }

    // MARK: Frame

    /// The entity the immersive space's photo controls attachment hangs
    /// from, under the frame.
    func attachControls(_ entity: Entity) {
        controls = entity
        frame.addChild(entity)
    }

    /// Shows `photo` `distance` metres (map frame) straight ahead of the eye
    /// at `camera`, facing it, sized to subtend the photo's field of view,
    /// at `opacity`.
    func showFrame(_ photo: PlacedPhoto, camera: CameraPose, georeference: Georeference,
                   distance: Double, opacity: Double) {
        let basis = camera.basis
        let rotation = georeference.rotation
        let forward = simd_normalize(rotation.act(basis.forward))
        let right = simd_normalize(rotation.act(basis.right))
        let up = simd_normalize(rotation.act(basis.up))
        let eye = georeference.map(camera.position)
        frame.position = SIMD3<Float>(eye + forward * distance)
        frame.orientation = simd_quatf(vector: SIMD4<Float>(
            simd_quatd(simd_double3x3(columns: (right, up, -forward))).vector))
        let size = PhotoPose.frameSize(photo.fieldOfView, distance: distance)
        framePicture.scale = [Float(size.width), Float(size.height), 1]
        framePicture.components.set(OpacityComponent(opacity: Float(min(max(opacity, 0), 1))))
        controls?.position = [0, -Float(size.height) / 2 - 0.12, 0.02]
        frame.isEnabled = true

        guard frameImage != photo.id else { return }
        frameImage = photo.id
        framePicture.model?.materials = [Self.placeholder]
        let id = photo.id, image = photo.image
        Task { [weak self] in
            guard let material = await Self.material(for: image), self?.frameImage == id else { return }
            self?.framePicture.model?.materials = [material]
        }
    }

    func hideFrame() {
        frame.isEnabled = false
    }

    // MARK: Materials

    /// Unlit, so the photo shows its own colours whatever the scene's light.
    private static func material(for image: CGImage) async -> Material? {
        do {
            // UNVERIFIED: the async TextureResource(image:withName:options:)
            // initialiser (visionOS 2 / macOS 15 and later).
            let texture = try await TextureResource(image: image, options: .init(semantic: .color))
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(texture))
            return material
        } catch {
            print("[AlsoMaps] couldn't make a photo texture: \(error)")
            return nil
        }
    }
}
