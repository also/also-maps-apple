/*
Adapted from Apple's sample "Creating a spatial drawing app with RealityKit"
(RealityKitDrawingApp/Brushes/Solid/CurveExtruder.swift): a 2D circle swept
along polylines into a growable LowLevelMesh. Changed for AlsoMaps: several
polylines per mesh with no faces between them, frames computed from the
points (no SmoothCurveSampler), mitred corners, constant radius, and only
position and normal per vertex (no color, material properties or curve
distance). The sample's license follows.

    Copyright 2024 Apple Inc. All Rights Reserved.

    IMPORTANT:  This Apple software is supplied to you by Apple
    Inc. ("Apple") in consideration of your agreement to the following
    terms, and your use, installation, modification or redistribution of
    this Apple software constitutes acceptance of these terms.  If you do
    not agree with these terms, please do not use, install, modify or
    redistribute this Apple software.

    In consideration of your agreement to abide by the following terms, and
    subject to these terms, Apple grants you a personal, non-exclusive
    license, under Apple's copyrights in this original Apple software (the
    "Apple Software"), to use, reproduce, modify and redistribute the Apple
    Software, with or without modifications, in source and/or binary forms;
    provided that if you redistribute the Apple Software in its entirety and
    without modifications, you must retain this notice and the following
    text and disclaimers in all such redistributions of the Apple Software.
    Neither the name, trademarks, service marks or logos of Apple Inc. may
    be used to endorse or promote products derived from the Apple Software
    without specific prior written permission from Apple.  Except as
    expressly stated in this notice, no other rights or licenses, express or
    implied, are granted by Apple herein, including but not limited to any
    patent rights that may be infringed by your derivative works or by other
    works in which the Apple Software may be incorporated.

    The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
    MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
    THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
    OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.

    IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
    OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
    SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
    INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
    MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
    AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
    STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/

import RealityKit
import simd

/// Sweeps a circle along polylines into a LowLevelMesh: one tube per
/// polyline, open at the ends. The mesh grows (doubling) as needed and is
/// otherwise rewritten in place.
struct TubeExtruder {
    private(set) var lowLevelMesh: LowLevelMesh?

    /// The unit circle swept along each polyline, counter-clockwise.
    let shape: [SIMD2<Float>]

    /// Triangles joining one ring to the next, as offsets from the first
    /// ring's first vertex: two per side, facing out.
    let topology: [UInt32]

    private struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    init(sides: Int) {
        shape = (0..<sides).map { i in
            let angle = 2 * Float.pi * Float(i) / Float(sides)
            return SIMD2(cos(angle), sin(angle))
        }
        let n = UInt32(sides)
        topology = (0..<n).flatMap { a -> [UInt32] in
            let b = (a + 1) % n
            return [a, b, n + a, b, n + b, n + a]
        }
    }

    /// Replaces the mesh's contents with a tube of `radius` along each
    /// polyline (polylines with fewer than two distinct points are skipped).
    ///
    /// - Returns: A new `LowLevelMesh` if one had to be allocated; callers
    ///   must then make a new `MeshResource` from it. Nil otherwise.
    @MainActor
    mutating func update(polylines: [[SIMD3<Float>]], radius: Float) throws -> LowLevelMesh? {
        let rings = polylines.map { rings(along: $0, radius: radius) }.filter { $0.count > 1 }
        let ringCount = rings.reduce(0) { $0 + $1.count }
        let indexCount = rings.reduce(0) { $0 + ($1.count - 1) * topology.count }
        let didReallocate = try reallocateMeshIfNeeded(vertexCount: ringCount * shape.count, indexCount: indexCount)
        guard let lowLevelMesh else { return nil }

        var bounds = BoundingBox.empty
        lowLevelMesh.withUnsafeMutableBytes(bufferIndex: 0) { rawBuffer in
            let vertices = rawBuffer.bindMemory(to: Vertex.self)
            var v = 0
            for ring in rings.joined() {
                for (u, stretch) in zip(shape, ring.offsets) {
                    let normal = ring.frame * SIMD3<Float>(u, 0)
                    vertices[v] = Vertex(position: ring.center + stretch, normal: normal)
                    v += 1
                }
                bounds.formUnion(ring.center)
            }
        }
        lowLevelMesh.withUnsafeMutableIndices { rawBuffer in
            let indices = rawBuffer.bindMemory(to: UInt32.self)
            var i = 0
            var firstVertex: UInt32 = 0
            for tube in rings {
                for _ in 0..<(tube.count - 1) {
                    for offset in topology {
                        indices[i] = firstVertex + offset
                        i += 1
                    }
                    firstVertex += UInt32(shape.count)
                }
                firstVertex += UInt32(shape.count)  // The tube's last ring.
            }
        }

        lowLevelMesh.parts.removeAll()
        if indexCount > 0 {
            // Mitred corners reach past the radius; twice it is plenty.
            let margin = SIMD3<Float>(repeating: 2 * radius)
            lowLevelMesh.parts.append(LowLevelMesh.Part(indexOffset: 0, indexCount: indexCount,
                                                        topology: .triangle, materialIndex: 0,
                                                        bounds: BoundingBox(min: bounds.min - margin,
                                                                            max: bounds.max + margin)))
        }
        return didReallocate ? lowLevelMesh : nil
    }

    /// One cross-section: its center, its frame (x and y across the tube, z
    /// along it) and each shape vertex's offset from the center.
    private struct Ring {
        var center: SIMD3<Float>
        var frame: simd_float3x3
        var offsets: [SIMD3<Float>]
    }

    /// Rings at each point of a polyline. Each frame turns the last one's by
    /// the least rotation (so the tube doesn't twist), and at a corner the
    /// ring lies on the bisecting plane, stretched across the bend so the
    /// tube keeps its radius through it.
    private func rings(along polyline: [SIMD3<Float>], radius: Float) -> [Ring] {
        // Points closer than this add nothing and have no direction.
        var points: [SIMD3<Float>] = []
        for p in polyline where points.last.map({ simd_distance($0, p) > 0.01 * radius }) ?? true {
            points.append(p)
        }
        guard points.count > 1 else { return [] }
        let directions = zip(points, points.dropFirst()).map { simd_normalize($1 - $0) }

        var rings: [Ring] = []
        rings.reserveCapacity(points.count)
        var up: SIMD3<Float> = abs(directions[0].y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
        for (i, center) in points.enumerated() {
            let before = directions[max(i - 1, 0)]
            let after = directions[min(i, directions.count - 1)]
            var tangent = before + after
            tangent = simd_length(tangent) > 1e-3 ? simd_normalize(tangent) : after

            // Parallel transport: the last up, made perpendicular again.
            var x = simd_cross(up, tangent)
            if simd_length(x) < 1e-4 {
                x = simd_cross(abs(tangent.y) < 0.9 ? [0, 1, 0] : [1, 0, 0], tangent)
            }
            x = simd_normalize(x)
            up = simd_cross(tangent, x)
            let frame = simd_float3x3(x, up, tangent)

            // Across the bend, the ring is 1/cos(half the turn) wider.
            let cosine = max(simd_dot(tangent, after), 0.5)
            var bend = after - before
            bend -= simd_dot(bend, tangent) * tangent
            let bendLength = simd_length(bend)
            let bendAxis = bendLength > 1e-4 ? bend / bendLength : .zero
            let offsets = shape.map { u -> SIMD3<Float> in
                let across = frame * SIMD3<Float>(u, 0)
                return radius * (across + (1 / cosine - 1) * simd_dot(across, bendAxis) * bendAxis)
            }
            rings.append(Ring(center: center, frame: frame, offsets: offsets))
        }
        return rings
    }

    /// If needed, allocates a bigger `lowLevelMesh` (doubling) for this many
    /// vertices and indices. Returns true if it did.
    @MainActor
    private mutating func reallocateMeshIfNeeded(vertexCount: Int, indexCount: Int) throws -> Bool {
        let vertexCapacity = lowLevelMesh?.vertexCapacity ?? 0
        let indexCapacity = lowLevelMesh?.indexCapacity ?? 0
        guard lowLevelMesh == nil || vertexCount > vertexCapacity || indexCount > indexCapacity else {
            return false
        }
        var newVertexCapacity = max(vertexCapacity, 1024 * shape.count)
        while newVertexCapacity < vertexCount { newVertexCapacity *= 2 }
        var newIndexCapacity = max(indexCapacity, 1024 * topology.count)
        while newIndexCapacity < indexCount { newIndexCapacity *= 2 }
        lowLevelMesh = try Self.makeLowLevelMesh(vertexCapacity: newVertexCapacity, indexCapacity: newIndexCapacity)
        return true
    }

    @MainActor
    private static func makeLowLevelMesh(vertexCapacity: Int, indexCapacity: Int) throws -> LowLevelMesh {
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = vertexCapacity
        descriptor.indexCapacity = indexCapacity
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, layoutIndex: 0,
                  offset: MemoryLayout.offset(of: \Vertex.position)!),
            .init(semantic: .normal, format: .float3, layoutIndex: 0,
                  offset: MemoryLayout.offset(of: \Vertex.normal)!),
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)]
        return try LowLevelMesh(descriptor: descriptor)
    }
}
