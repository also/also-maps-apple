# Tile app icon

`tile-icon.svg` preserves the geometry, colors, stroke widths, and padding of
the maps site's initial `?icon` preview. It uses the light appearance and an
opaque warm background. The SVG is the resolution-independent source for the
PNG assets; the small on-screen preview has not been upscaled.

- iOS: one 1024×1024 PNG in `SourcesPhone/Assets.xcassets/AppIcon.appiconset`.
- macOS: 16, 32, 128, 256, and 512 point slots at 1× and 2× in
  `SourcesMac/Assets.xcassets/AppIcon.appiconset`.
- tvOS: 400×240 and 800×480 home-screen images, plus 1280×768 store images,
  in `SourcesTV/Assets.xcassets/AppIcon.brandassets`. Each image stack has
  separate transparent artwork and opaque background layers. The square
  artwork is centered in the wider TV canvas without stretching.

`project.yml` selects `AppIcon` for these three targets. Run `xcodegen generate`
after changing project settings. visionOS retains its existing configuration.
