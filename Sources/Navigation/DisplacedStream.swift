import Foundation
import simd

/// A second tile stream shown somewhere other than where its tiles are on
/// Earth: its own anchor and area of interest, and a similarity taking its
/// real world to where it's shown in the host's world. Rigid for a guest
/// place set beside or over the map (GuestPlacement); a scaled one would
/// show a world in miniature. Nothing here knows which.
///
/// Frames: the stream's tiles are placed in its own anchor frame by the
/// bridge, as the host's are in the host's. `shownFromReal` is ECEF → ECEF,
/// so the host's georeference then takes the shown stream into the map
/// frame like any other part of the host's world.
struct DisplacedStream: Equatable {
    /// Where this stream's tiles are placed from, and the centre of what it
    /// streams, in its own real world.
    var anchor: StreamingAnchor
    /// Half-width of its area of interest, metres.
    var streamingRadius: Double
    /// Rotation of that square, radians clockwise from north, in its own world.
    var regionHeading = 0.0
    /// Its real world (ECEF) → where it's shown in the host's world (ECEF).
    var shownFromReal: Similarity

    /// Its anchor frame → the host's map frame: where its tiles root goes.
    /// Composed in double, so the large ECEF terms cancel before anything
    /// is rounded to Float, as Georeference.placement does for the host.
    func placement(in georeference: Georeference) -> Similarity {
        georeference.similarity.after(shownFromReal).after(anchor.ecefFromAnchor)
    }

    /// The host's anchor frame → this stream's anchor frame: the inverse of
    /// where it's shown, so a point the host sees at some spot is the point
    /// of this stream's world shown there.
    func ownFromHost(_ hostAnchor: StreamingAnchor) -> Similarity {
        anchor.ecefFromAnchor.inverse.after(shownFromReal.inverse).after(hostAnchor.ecefFromAnchor)
    }

    /// The host's LOD camera carried into this stream's anchor frame, so the
    /// stream refines as if it were looked at where it's shown. Under a
    /// scaled placement the camera's distance scales too, which is what
    /// keeps detail right: a world shown at half size looks, to its tiles,
    /// like a world twice as far away.
    func lodCamera(carrying hostLOD: LODCamera, from hostAnchor: StreamingAnchor) -> LODCamera {
        let toOwn = ownFromHost(hostAnchor)
        var lod = hostLOD
        lod.position = toOwn.apply(hostLOD.position)
        lod.direction = simd_normalize(toOwn.rotation.act(hostLOD.direction))
        lod.up = simd_normalize(toOwn.rotation.act(hostLOD.up))
        return lod
    }

    /// What this stream's cesium-native is told, given the host's inputs.
    func inputs(hostLOD: LODCamera, hostAnchor: StreamingAnchor) -> StreamingInputs {
        StreamingInputs(anchor: anchor,
                        lod: lodCamera(carrying: hostLOD, from: hostAnchor),
                        regionHeading: regionHeading,
                        streamingRadius: streamingRadius)
    }
}
