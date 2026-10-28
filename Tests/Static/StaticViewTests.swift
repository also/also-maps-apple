import Foundation
import simd
import Testing

struct StaticViewTests {
    @Test(arguments: [CGSize(width: 1920, height: 1080), CGSize(width: 800, height: 1200)])
    func placeCameraFramesItsFocus(in viewport: CGSize) {
        let place = Place(id: "ronda", name: "Ronda", latitude: 36.7418,
                          longitude: -5.167, radius: 500, heading: 90)
        var settings = StreamingSettings.default
        settings.detail = 27
        settings.uploadConcurrency = 2
        let view = StaticView.place(place, viewportSize: viewport, settings: settings)
        let camera = view.inputs.lod
        // In the anchor frame the focus is the origin. It must lie on the
        // camera's forward axis, within clipping range, at every aspect ratio.
        let toFocus = -camera.position
        let depth = simd_dot(toFocus, camera.direction)
        let right = simd_cross(camera.direction, camera.up)
        #expect(abs(simd_dot(toFocus, right)) < 1e-9)
        #expect(abs(simd_dot(toFocus, camera.up)) < 1e-9)
        #expect(depth > Double(view.near) && depth < Double(view.far))
        #expect(abs(simd_length(camera.direction) - 1) < 1e-12)
        #expect(abs(simd_length(camera.up) - 1) < 1e-12)
        #expect(camera.aspect == viewport.width / viewport.height)
        #expect(view.inputs.anchor.coordinate == place.coordinate)
        #expect(view.settings == settings)
        #expect(view.samplesGround)
    }

    @Test func savedHeadingRotatesTheViewClockwiseFromNorth() {
        func camera(heading: Double) -> LODCamera {
            StaticView.place(Place(id: "test", name: "Test", latitude: 0,
                                   longitude: 0, radius: 600, heading: heading),
                             viewportSize: CGSize(width: 1200, height: 800),
                             settings: .default).inputs.lod
        }
        let north = camera(heading: 0)
        let east = camera(heading: 90)
        // RealityKit anchor axes: x east, y up, z south.
        #expect(north.direction.z < 0 && abs(north.direction.x) < 1e-12)
        #expect(east.direction.x > 0 && abs(east.direction.z) < 1e-12)
        #expect(north.direction.y < 0 && east.direction.y < 0)
        #expect(abs(simd_length(north.position) - simd_length(east.position)) < 1e-9)
    }
}
