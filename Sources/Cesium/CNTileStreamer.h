// Objective-C face of the cesium-native bridge. Nothing C++ leaks through this
// header, so Swift sees plain classes; CNTileStreamer.mm owns the Tileset.
//
// Coordinates: there is no global origin. Each tile's vertices are small
// offsets from its own center; every frame the bridge hands Swift a transform
// per drawn tile that places it in the anchor's level frame, in meters and
// RealityKit axes (x = east, y = up, z = south, the anchor at 0).

#import <Foundation/Foundation.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

/// One glTF primitive flattened for RealityKit's MeshDescriptor.
@interface CNPrimitive : NSObject
/// float4 per vertex (xyz + padding) so it binds directly to SIMD3<Float>:
/// ECEF-axis offsets in meters from the tile's center; place with the
/// matching CNFrame.tileTransforms entry.
@property (nonatomic, readonly) NSData *positions;
/// float2 per vertex, v already flipped for RealityKit; nil if untextured.
@property (nonatomic, readonly, nullable) NSData *texcoords;
/// uint32 triangle list.
@property (nonatomic, readonly) NSData *indices;
/// RGBA8 base color, textureWidth * textureHeight * 4 bytes; nil if none.
@property (nonatomic, readonly, nullable) NSData *rgba;
@property (nonatomic, readonly) NSInteger textureWidth;
@property (nonatomic, readonly) NSInteger textureHeight;
/// The texture's glTF sampler: wrap modes (REPEAT when the glTF gives
/// none), and filters (0 when unspecified, leaving the choice to the app).
@property (nonatomic, readonly) NSInteger textureWrapS;
@property (nonatomic, readonly) NSInteger textureWrapT;
@property (nonatomic, readonly) NSInteger textureMagFilter;
@property (nonatomic, readonly) NSInteger textureMinFilter;
/// float4 per vertex: unit normals in ECEF axes. Present for untextured
/// content (drawn lit); nil for textured photogrammetry (drawn unlit). Flat
/// normals are computed when the glTF has none.
@property (nonatomic, readonly, nullable) NSData *normals;
/// glTF base color factor (linear RGBA); multiplies the texture if any.
@property (nonatomic, readonly) simd_float4 baseColor;
/// float2 per vertex: where the vertex falls in the tileset's raster
/// overlay, for untextured content in a tileset with imagery (terrain).
/// cesium-native's convention, not flipped: (0, 0) at the south-west corner
/// of the tile's projected rectangle, (1, 1) at the north-east. Sample the
/// attached CNOverlay's image at `uv * scale + translation` (v up, so row 0
/// of the image is v = 1). Nil without an overlay.
@property (nonatomic, readonly, nullable) NSData *overlayTexcoords;
@end

/// One raster overlay image (a piece of imagery covering one or more
/// geometry tiles). Lives until cesium-native frees it.
@interface CNRaster : NSObject
/// RGBA8, width * height * 4 bytes, row 0 northmost.
@property (atomic, readonly) NSData *rgba;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
/// Whatever the app built to draw this image (a texture), attached by the
/// raster load handler, possibly after it has returned.
@property (atomic, strong, nullable) id renderObject;
/// Drops the pixels once they've been uploaded.
- (void)discardCPUData;
@end

/// A raster attached to a geometry tile, and the mapping from the tile's
/// overlayTexcoords into it: `uv * scale + translation`. A tile may first
/// get an ancestor's raster (scaled to its part of it) until its own loads.
@interface CNOverlay : NSObject
@property (nonatomic, readonly) CNRaster *raster;
@property (nonatomic, readonly) simd_float2 translation;
@property (nonatomic, readonly) simd_float2 scale;
@end

/// One attribution to show: its text, and its logo if the provider gave one
/// (e.g. the Cesium ion logo).
@interface CNCredit : NSObject
@property (nonatomic, readonly) NSString *text;
@property (nonatomic, readonly, nullable) NSString *imageURL;
@end

/// A loaded tile's renderable content. Lives until cesium-native frees the
/// tile, at which point its identifier shows up in CNFrame.freedTileIDs.
@interface CNTileMesh : NSObject
@property (nonatomic, readonly) uint64_t identifier;
@property (atomic, readonly, nullable) NSArray<CNPrimitive *> *primitives;
/// Whatever the app built to draw this tile (a RealityKit entity), attached
/// by the tile load handler before it completes.
@property (atomic, strong, nullable) id renderObject;
/// Where the tile's vertices are measured from, ECEF meters.
@property (nonatomic, readonly) simd_double3 centerECEF;
/// Distance from centerECEF to the farthest vertex, meters.
@property (nonatomic, readonly) double radius;
/// The lowest and highest vertex, meters above the WGS84 ellipsoid
/// (measured radially, which is within meters of geodetic height).
@property (nonatomic, readonly) double minimumHeight;
@property (nonatomic, readonly) double maximumHeight;
/// The imagery currently attached to this tile, if its tileset has an
/// overlay. Changes on the main thread during updateWithDeltaTime:, as
/// better imagery loads; a new object each time.
@property (atomic, readonly, nullable) CNOverlay *overlay;
/// Drops the CPU-side buffers once they've been uploaded.
- (void)discardCPUData;
@end

/// Called on a background thread for each newly loaded tile, before
/// cesium-native counts it as loaded: build its renderer resources, attach
/// them as `renderObject`, then call `completion` exactly once, from any
/// thread. Until then the tile isn't drawable, so with forbidHoles cesium-
/// native keeps its parent instead of leaving a gap.
typedef void (^CNTileLoadHandler)(CNTileMesh *tile, void (^completion)(void));

/// Called on a background thread for each overlay image as it loads. Start
/// building its texture and attach it as `renderObject` when done; nothing
/// waits for it, so until then tiles keep the imagery they had.
typedef void (^CNRasterLoadHandler)(CNRaster *raster);

/// One Cesium ion tileset to stream, optionally draped with an ion imagery
/// asset.
@interface CNIonLayer : NSObject
- (instancetype)initWithAssetID:(int64_t)assetID
                 imageryAssetID:(int64_t)imageryAssetID
                  smoothNormals:(BOOL)smoothNormals NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) int64_t assetID;
/// 0 for none.
@property (nonatomic, readonly) int64_t imageryAssetID;
/// Have cesium-native generate smooth normals for content without any
/// (terrain); otherwise flat ones are computed (buildings).
@property (nonatomic, readonly) BOOL smoothNormals;
@end

/// How tile requests have been satisfied since the streamer started, from
/// URLSessionTaskMetrics.
@interface CNFetchStats : NSObject
/// Served from the HTTP cache with no network.
@property (nonatomic, readonly) uint64_t cacheHits;
/// Cache entry was stale; the server answered 304 and the cached body was used.
@property (nonatomic, readonly) uint64_t revalidated;
/// Full downloads (no usable cache entry).
@property (nonatomic, readonly) uint64_t networkLoads;
@property (nonatomic, readonly) uint64_t other;
/// Response body bytes received over the network.
@property (nonatomic, readonly) uint64_t networkBytes;
- (instancetype)initWithCacheHits:(uint64_t)cacheHits
                      revalidated:(uint64_t)revalidated
                     networkLoads:(uint64_t)networkLoads
                            other:(uint64_t)other
                     networkBytes:(uint64_t)networkBytes NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// A drawn tile's bounding volume as cesium-native sees it: an oriented
/// box in the tile's own frame, like its vertices (ECEF-axis offsets from
/// its center; place it with the tile's CNFrame.tileTransforms entry).
typedef struct {
  simd_float3 center;
  simd_float3 halfAxisA;
  simd_float3 halfAxisB;
  simd_float3 halfAxisC;
  /// Whether the box is inside the LOD camera's view (refined to
  /// maximumScreenSpaceError) or outside it (culledScreenSpaceError).
  bool inView;
} CNTileBounds;

@interface CNFrame : NSObject
@property (nonatomic, readonly) NSArray<CNTileMesh *> *tilesToRender;
/// One simd_float4x4 per tilesToRender entry, same order: the tile's
/// placement in the anchor's level frame (see the coordinates note above).
@property (nonatomic, readonly) NSData *tileTransforms;
@property (nonatomic, readonly) NSArray<NSNumber *> *freedTileIDs;
/// One CNTileBounds per tilesToRender entry, same order, when
/// reportsTileBounds is set; otherwise nil.
@property (nonatomic, readonly, nullable) NSData *tileBounds;
/// Attributions that must be shown on screen.
@property (nonatomic, readonly) NSArray<CNCredit *> *credits;
/// 0–100.
@property (nonatomic, readonly) float loadProgress;
@end

@interface CNTileStreamer : NSObject

- (instancetype)initWithTilesetURL:(NSString *)url;
/// A Cesium ion asset, e.g. 96188 (Cesium OSM Buildings). The token needs
/// only the assets:read scope.
- (instancetype)initWithIonAssetID:(int64_t)assetID
                       accessToken:(NSString *)accessToken
                     smoothNormals:(BOOL)smoothNormals;
/// smoothNormals: have cesium-native generate smooth normals for content
/// without any (terrain); otherwise flat ones are computed (buildings).
/// Several ion tilesets drawn together (e.g. terrain and buildings), sharing
/// the view, area of interest and settings. The first is the ground: height
/// samples come from it alone.
- (instancetype)initWithIonLayers:(NSArray<CNIonLayer *> *)layers
                      accessToken:(NSString *)accessToken;
- (instancetype)init NS_UNAVAILABLE;

/// The anchor: the origin of the frame tiles are placed in, and the center
/// of the area of interest. Degrees.
@property (nonatomic) double anchorLatitude;
@property (nonatomic) double anchorLongitude;
/// Meters above the WGS84 ellipsoid.
@property (nonatomic) double anchorHeight;
/// Half-width of the area of interest: the square, centered on the anchor,
/// whose tiles may stream. Meters.
@property (nonatomic) double streamingRadius;
/// Rotation of that square, radians clockwise from north.
@property (nonatomic) double regionHeading;

/// The LOD camera (the frustum detail is selected for), in the anchor's
/// frame (x east, y up, z south, meters). Direction and up should be
/// perpendicular unit vectors; the bridge normalizes them and skips the
/// view update if they're degenerate.
@property (nonatomic) simd_double3 viewPosition;
@property (nonatomic) simd_double3 viewDirection;
@property (nonatomic) simd_double3 viewUp;
/// Vertical field of view, radians. Default π/3.
@property (nonatomic) double viewFieldOfView;
/// Width over height. Default 1.
@property (nonatomic) double viewAspect;

/// Prepares each tile's renderer resources off the main thread. Set it before
/// the first update; without one, tiles count as loaded immediately.
@property (nonatomic, copy, nullable) CNTileLoadHandler tileLoadHandler;
/// Builds each overlay image's texture. Set it before the first update.
@property (nonatomic, copy, nullable) CNRasterLoadHandler rasterLoadHandler;

// Live cesium-native TilesetOptions; changes apply on the next update.
/// SSE threshold for tiles the LOD camera sees; lower = more detail. Default 16.
@property (nonatomic) double maximumScreenSpaceError;
/// SSE threshold for tiles outside the LOD camera's view. Default 64.
@property (nonatomic) double culledScreenSpaceError;
/// Concurrent tile requests. Default 20.
@property (nonatomic) NSInteger maximumSimultaneousTileLoads;
/// Loaded-tile cache budget in bytes. Default 512 MB.
@property (nonatomic) int64_t maximumCachedBytes;
/// Keep parents until all children have loaded. Default NO.
@property (nonatomic) BOOL forbidHoles;
/// Report each drawn tile's bounding volume in CNFrame.tileBounds, for
/// debugging. Default NO.
@property (nonatomic) BOOL reportsTileBounds;

/// Request counters since this streamer started; safe from any thread.
- (CNFetchStats *)fetchStats;

/// The latest 400, 401, 403 or 429 from any tile request since the last
/// call, or 0: the service may be rejecting or throttling the key.
- (NSInteger)takeKeyFailureStatus;

/// Runs one selection + load pass. Call once per frame on the main thread.
- (CNFrame *)updateWithDeltaTime:(float)deltaTime;

/// Samples the most detailed surface on a 3×3 grid spanning 0.8 × `radius`
/// meters around a point (degrees) and reports the lowest hit in meters
/// above the ellipsoid, or NAN if every sample failed. May load tiles.
/// Completion runs on the main thread during a later updateWithDeltaTime:
/// call.
- (void)sampleGroundHeightAroundLatitude:(double)latitude
                               longitude:(double)longitude
                                  radius:(double)radius
                              completion:(void (^)(double height))completion
    NS_SWIFT_NAME(sampleGroundHeight(latitude:longitude:radius:completion:));

@end

NS_ASSUME_NONNULL_END
