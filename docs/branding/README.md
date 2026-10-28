# Tile app icon

## Regenerate artwork

With Node.js 22 or later, from the repository root:

```sh
npm ci --prefix Scripts/branding
npm run generate --prefix Scripts/branding
```

This regenerates the SVG sources, PNG assets, and asset catalog manifests for
all four platforms and both Top Shelf sizes. It does not require a website
checkout, a running browser, or Xcode. Xcode uses the checked-in PNGs; these
scripts are not part of the app build.

The generators in `Scripts/branding/` run in order: tile icons, visionOS icon,
then Top Shelf. The tile generator contains the icon's projection and geometry;
visionOS reuses its building paths. Top Shelf records canvas paths from the
checked-in `splash-source.js` snapshot of the site at commit `27273c5`, then adds
the title. Update that snapshot deliberately when changing the site's artwork.
The scripts retain other entries in the TV brand manifest when run separately.

Sharp is pinned in `package-lock.json`. Top Shelf's title uses Georgia, falling
back to Times New Roman or the system serif; use macOS with Georgia installed
to reproduce the current typography. PNG bytes can vary across rasterizer or
font versions, so review regenerated artwork before committing it.

## Assets

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
