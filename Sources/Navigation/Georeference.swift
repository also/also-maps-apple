import Foundation
import simd

/// A uniform scale, rotation and translation: y = translation + scale · rotation · x.
struct Similarity: Equatable {
    var scale = 1.0
    var rotation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    var translation = SIMD3<Double>.zero

    static let identity = Similarity()

    func apply(_ x: SIMD3<Double>) -> SIMD3<Double> {
        translation + scale * rotation.act(x)
    }

    var inverse: Similarity {
        let inverseRotation = rotation.inverse
        return Similarity(scale: 1 / scale,
                          rotation: inverseRotation,
                          translation: -inverseRotation.act(translation) / scale)
    }

    /// `self` after `inner`: x ↦ self.apply(inner.apply(x)).
    func after(_ inner: Similarity) -> Similarity {
        Similarity(scale: scale * inner.scale,
                   rotation: rotation * inner.rotation,
                   translation: apply(inner.translation))
    }
}

/// Which world point sits where in the map frame, at what scale and
/// rotation: map = translation + scale · rotation · ecef. Produced by the
/// presentation style; always ours, whether tiles are live or held.
struct Georeference: Equatable {
    var scale: Double
    /// ECEF → map frame.
    var rotation: simd_quatd
    var translation: SIMD3<Double>

    var similarity: Similarity {
        Similarity(scale: scale, rotation: rotation, translation: translation)
    }

    init(scale: Double, rotation: simd_quatd, translation: SIMD3<Double>) {
        self.scale = scale
        self.rotation = rotation
        self.translation = translation
    }

    init(_ similarity: Similarity) {
        self.init(scale: similarity.scale, rotation: similarity.rotation, translation: similarity.translation)
    }

    func map(_ ecef: SIMD3<Double>) -> SIMD3<Double> {
        similarity.apply(ecef)
    }

    func ecef(map point: SIMD3<Double>) -> SIMD3<Double> {
        similarity.inverse.apply(point)
    }

    /// Anchor frame → map frame: where the tiles root goes when the bridge
    /// places tiles relative to `anchor`. Composed in double, so the large
    /// ECEF terms cancel before anything is rounded to Float.
    func placement(of anchor: StreamingAnchor) -> Similarity {
        similarity.after(anchor.ecefFromAnchor)
    }
}

/// Map frame → reference space (the host's origin). Rigid: translation and
/// yaw. Only the user and the system change it, never navigation.
struct RoomPlacement: Codable, Equatable {
    var translation = SIMD3<Double>.zero
    /// Radians about the reference space's up.
    var yaw = 0.0

    static let identity = RoomPlacement()

    var similarity: Similarity {
        Similarity(scale: 1,
                   rotation: simd_quatd(angle: yaw, axis: SIMD3(0, 1, 0)),
                   translation: translation)
    }
}
