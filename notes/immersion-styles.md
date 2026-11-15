# Immersion styles: working notes

Notes on the RealityKit immersive space's immersion styles (Settings ›
Immersion), newest first. **Observed** means seen on a device or in logs.
**Inferred** means a hypothesis that fits the evidence but wasn't confirmed.
The Metal space's styles are in [metal-renderer.md](metal-renderer.md).

## Log

### 2026-11-15: progressive portrait, tried and dropped

- Tried `.progressive(aspectRatio: .portrait)` (visionOS 26) as a fourth
  option beside plain `.progressive`, with both listed in the space's
  `.immersionStyle(selection:in:)`.
- **Observed (Vision Pro):** the portrait portal is mostly taller than the
  landscape one, not noticeably narrower, so it doesn't help with motion
  the way a narrower view might.
- **Observed (Vision Pro):** switching between the two progressive
  orientations while the space is open doesn't change the portal.
  Switching through another style does (portrait → full → landscape).
- **Decided:** no portrait option. The space keeps plain `.progressive`.
