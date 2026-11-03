import Testing

struct RenderOptionsTests {
    @Test
    func defaultIsNetworkFreeAndDeterministic() throws {
        let options = try RenderOptions.parse([])
        #expect(!options.google)
        #expect(options.frames == 30)
        #expect(options.width == 1280)
    }

    @Test
    func acceptsGoogleCameraAndOutputOverrides() throws {
        let options = try RenderOptions.parse(["--google", "--latitude", "40.75", "--longitude", "-73.98",
                                               "--altitude", "300", "--pitch", "-20", "--frames", "5",
                                               "--width", "640", "--output", "build/test-render"])
        #expect(options.google)
        #expect(options.latitude == 40.75)
        #expect(options.longitude == -73.98)
        #expect(options.altitude == 300)
        #expect(options.pitch == -20)
        #expect(options.frames == 5)
        #expect(options.width == 640)
        #expect(options.output == "build/test-render")
    }

    @Test(arguments: [["--width", "0"], ["--height", "1000000000"], ["--frames", "-1"],
                      ["--frames", "1000000000"], ["--latitude", "NaN"], ["--timeout", "inf"],
                      ["--longitude", "181"], ["--radius", "-100"], ["--detail", "0"],
                      ["--pitch", "-91"], ["--heading", "1e308"], ["--output", ""], ["--width"], ["--unknown", "1"]])
    func rejectsInvalidOrUnboundedInputs(arguments: [String]) {
        #expect(throws: RenderCLIError.self) { try RenderOptions.parse(arguments) }
    }
}
