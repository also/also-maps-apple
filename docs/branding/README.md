# Tile app icon

`tile-icon.svg` preserves the geometry, colors, and padding of
the maps site's `?icon` preview, with strokes doubled to 2.2 logical units.
It uses the light appearance and an
opaque warm background. The SVG is the resolution-independent source for the
PNG assets; the small on-screen preview has not been upscaled.

- iOS: one 1024×1024 PNG in `SourcesPhone/Assets.xcassets/AppIcon.appiconset`.
- macOS: 16, 32, 128, 256, and 512 point slots at 1× and 2× in
  `SourcesMac/Assets.xcassets/AppIcon.appiconset`.
- tvOS: 400×240 and 800×480 home-screen images, plus 1280×768 store images,
  in `SourcesTV/Assets.xcassets/AppIcon.brandassets`. Each image stack has
  separate transparent artwork and opaque background layers. The square
  artwork is centered in the wider TV canvas without stretching.

- visionOS: a 1024×1024 layered icon in
  `Sources/VisionIcon.xcassets/AppIcon.solidimagestack`, with the three buildings
  on a transparent front layer and a full pale background behind them. No tile
  outline; the system applies the circular mask. `vision-icon.svg` is the flat
  source preview. This catalog is included only in the visionOS target.

`project.yml` selects `AppIcon` for all four targets. Run `xcodegen generate`
after changing project settings.

The tvOS brand catalog also includes standard (1920×720) and wide (2320×720)
static Top Shelf images at 1× and 2×. These use the original full grid and
`maps.also.dev` title, centered on the warm background. `top-shelf.svg` preserves
the wide source artwork.
