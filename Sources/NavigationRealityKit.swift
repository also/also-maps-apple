import RealityKit
import simd

extension Transform {
    /// A RealityKit transform from a double-precision similarity. Compose in
    /// double first (see Georeference.placement(of:)) so only small numbers
    /// reach Float.
    init(_ similarity: Similarity) {
        self.init(scale: SIMD3(repeating: Float(similarity.scale)),
                  rotation: simd_quatf(vector: SIMD4<Float>(similarity.rotation.vector)),
                  translation: SIMD3<Float>(similarity.translation))
    }
}
