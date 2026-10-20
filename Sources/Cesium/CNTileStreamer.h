// Objective-C face of the cesium-native bridge. Nothing C++ leaks through this
// header, so Swift sees plain classes; CNTileStreamer.mm owns the Tileset.
//
// Coordinates: everything handed to Swift is in a fixed local frame anchored at
// the streamer's origin, in metres, already in RealityKit axes
// (x = east, y = up, z = south). Panning moves the focus inside that frame
// rather than re-baking geometry.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One glTF primitive flattened for RealityKit's MeshDescriptor.
@interface CNPrimitive : NSObject
/// float4 per vertex (xyz + padding) so it binds directly to SIMD3<Float>.
@property (nonatomic, readonly) NSData *positions;
/// float2 per vertex, v already flipped for RealityKit; nil if untextured.
@property (nonatomic, readonly, nullable) NSData *texcoords;
/// uint32 triangle list.
@property (nonatomic, readonly) NSData *indices;
/// RGBA8 base colour, textureWidth * textureHeight * 4 bytes; nil if none.
@property (nonatomic, readonly, nullable) NSData *rgba;
@property (nonatomic, readonly) NSInteger textureWidth;
@property (nonatomic, readonly) NSInteger textureHeight;
@end

/// A loaded tile's renderable content. Lives until cesium-native frees the
/// tile, at which point its identifier shows up in CNFrame.freedTileIDs.
@interface CNTileMesh : NSObject
@property (nonatomic, readonly) uint64_t identifier;
@property (nonatomic, readonly, nullable) NSArray<CNPrimitive *> *primitives;
/// Drops the CPU-side buffers once Swift has uploaded them to RealityKit.
- (void)discardCPUData;
@end

@interface CNFrame : NSObject
@property (nonatomic, readonly) NSArray<CNTileMesh *> *tilesToRender;
@property (nonatomic, readonly) NSArray<NSNumber *> *freedTileIDs;
/// Attribution strings (HTML stripped) that must be shown on screen.
@property (nonatomic, readonly) NSArray<NSString *> *credits;
/// 0–100.
@property (nonatomic, readonly) float loadProgress;
@end

@interface CNTileStreamer : NSObject

- (instancetype)initWithTilesetURL:(NSString *)url
                    originLatitude:(double)latitude
                         longitude:(double)longitude
                            height:(double)height NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Centre of the region to stream, metres east/north of the origin.
@property (nonatomic) double focusEast;
@property (nonatomic) double focusNorth;
/// Height of the ground at the focus in the local frame (metres up).
@property (nonatomic) double focusHeight;
/// Half-width of the square region to stream, metres.
@property (nonatomic) double focusRadius;
/// Distance of the synthetic LOD camera from the focus, metres of world.
@property (nonatomic) double viewerDistance;
/// Compass bearing the viewer faces, radians clockwise from north (0 = the
/// volume's front looks north). Steers the LOD camera and streamed region.
@property (nonatomic) double viewHeading;
/// Half-width of the square actually streamed, metres. 0 means use
/// focusRadius; larger streams beyond what the volume shows (ground sampling
/// still uses focusRadius).
@property (nonatomic) double streamingRadius;

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

/// Runs one selection + load pass. Call once per frame on the main thread.
- (CNFrame *)updateWithDeltaTime:(float)deltaTime;

/// Samples the most detailed surface on a 3×3 grid across the focus region
/// and reports the lowest hit as a local-frame height (metres up), or NAN if
/// every sample failed. Completion runs on the main thread during a later
/// updateWithDeltaTime: call.
- (void)sampleGroundHeightInFocusRegion:(void (^)(double height))completion
    NS_SWIFT_NAME(sampleGroundHeightInFocusRegion(completion:));

@end

NS_ASSUME_NONNULL_END
