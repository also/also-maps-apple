#import "CNTileStreamer.h"

#import <os/signpost.h>

#include <Cesium3DTilesContent/registerAllTileContentTypes.h>
#include <Cesium3DTilesSelection/BoundingVolume.h>
#include <Cesium3DTilesSelection/IPrepareRendererResources.h>
#include <Cesium3DTilesSelection/ITileExcluder.h>
#include <Cesium3DTilesSelection/Tile.h>
#include <Cesium3DTilesSelection/TileLoadResult.h>
#include <Cesium3DTilesSelection/Tileset.h>
#include <Cesium3DTilesSelection/TilesetExternals.h>
#include <Cesium3DTilesSelection/TilesetOptions.h>
#include <Cesium3DTilesSelection/ViewState.h>
#include <Cesium3DTilesSelection/ViewUpdateResult.h>
#include <CesiumAsync/AsyncSystem.h>
#include <CesiumAsync/IAssetAccessor.h>
#include <CesiumAsync/IAssetRequest.h>
#include <CesiumAsync/IAssetResponse.h>
#include <CesiumAsync/ITaskProcessor.h>
#include <CesiumGeometry/OrientedBoundingBox.h>
#include <CesiumGeospatial/Cartographic.h>
#include <CesiumGeospatial/Ellipsoid.h>
#include <CesiumGeospatial/GlobeTransforms.h>
#include <CesiumGltf/AccessorView.h>
#include <CesiumGltf/Model.h>
#include <CesiumGltfContent/GltfUtilities.h>
#include <CesiumImage/ImageAsset.h>
#include <CesiumUtility/CreditSystem.h>

#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

using namespace Cesium3DTilesSelection;
using namespace CesiumAsync;
using CesiumGeospatial::Cartographic;
using CesiumGeospatial::Ellipsoid;

// ── Plain data objects handed to Swift ───────────────────────────────────────

@interface CNPrimitive ()
- (instancetype)initWithPositions:(NSData *)positions
                        texcoords:(nullable NSData *)texcoords
                          normals:(nullable NSData *)normals
                          indices:(NSData *)indices
                             rgba:(nullable NSData *)rgba
                            width:(NSInteger)width
                           height:(NSInteger)height
                          sampler:(const CesiumGltf::Sampler&)sampler
                        baseColor:(simd_float4)baseColor;
@end

@implementation CNPrimitive
- (instancetype)initWithPositions:(NSData *)positions
                        texcoords:(NSData *)texcoords
                          normals:(NSData *)normals
                          indices:(NSData *)indices
                             rgba:(NSData *)rgba
                            width:(NSInteger)width
                           height:(NSInteger)height
                          sampler:(const CesiumGltf::Sampler&)sampler
                        baseColor:(simd_float4)baseColor {
  if ((self = [super init])) {
    _positions = positions;
    _texcoords = texcoords;
    _normals = normals;
    _indices = indices;
    _rgba = rgba;
    _textureWidth = width;
    _textureHeight = height;
    _textureWrapS = sampler.wrapS;
    _textureWrapT = sampler.wrapT;
    _textureMagFilter = sampler.magFilter.value_or(0);
    _textureMinFilter = sampler.minFilter.value_or(0);
    _baseColor = baseColor;
  }
  return self;
}
@end

@interface CNCredit ()
- (instancetype)initWithText:(NSString *)text imageURL:(nullable NSString *)imageURL;
@end

@implementation CNCredit
- (instancetype)initWithText:(NSString *)text imageURL:(NSString *)imageURL {
  if ((self = [super init])) {
    _text = text;
    _imageURL = imageURL;
  }
  return self;
}
@end

@interface CNTileMesh ()
- (instancetype)initWithIdentifier:(uint64_t)identifier
                            center:(glm::dvec3)center
                            radius:(double)radius
                     minimumHeight:(double)minimumHeight
                     maximumHeight:(double)maximumHeight
                        primitives:(NSArray<CNPrimitive *> *)primitives;
/// ECEF point the tile's vertices are measured from, full precision.
@property (nonatomic, readonly) glm::dvec3 center;
@property (atomic, readwrite, nullable) NSArray<CNPrimitive *> *primitives;
@end

@implementation CNTileMesh
- (instancetype)initWithIdentifier:(uint64_t)identifier
                            center:(glm::dvec3)center
                            radius:(double)radius
                     minimumHeight:(double)minimumHeight
                     maximumHeight:(double)maximumHeight
                        primitives:(NSArray<CNPrimitive *> *)primitives {
  if ((self = [super init])) {
    _identifier = identifier;
    _center = center;
    _radius = radius;
    _minimumHeight = minimumHeight;
    _maximumHeight = maximumHeight;
    _primitives = primitives;
  }
  return self;
}
- (void)discardCPUData {
  self.primitives = nil;
}
- (simd_double3)centerECEF {
  return simd_make_double3(_center.x, _center.y, _center.z);
}
@end

/// Height of an ECEF point above the WGS84 ellipsoid, measured along its
/// radius: cheap enough per vertex, and within metres of geodetic height.
static double radialHeight(const glm::dvec3& p) {
  const double length = glm::length(p);
  if (!(length > 0.0)) {
    return 0.0;
  }
  const glm::dvec3 u = p / length;
  const double a = 6378137.0, b = 6356752.314245179;
  const double surface =
      1.0 / std::sqrt((u.x * u.x + u.y * u.y) / (a * a) + (u.z * u.z) / (b * b));
  return length - surface;
}

@interface CNFrame ()
@property (nonatomic, readwrite) NSArray<CNTileMesh *> *tilesToRender;
@property (nonatomic, readwrite) NSData *tileTransforms;
@property (nonatomic, readwrite) NSArray<NSNumber *> *freedTileIDs;
@property (nonatomic, readwrite, nullable) NSData *tileBounds;
@property (nonatomic, readwrite) NSArray<CNCredit *> *credits;
@property (nonatomic, readwrite) float loadProgress;
@end

@implementation CNFrame
@end

@implementation CNFetchStats
- (instancetype)initWithCacheHits:(uint64_t)cacheHits
                      revalidated:(uint64_t)revalidated
                     networkLoads:(uint64_t)networkLoads
                            other:(uint64_t)other
                     networkBytes:(uint64_t)networkBytes {
  if ((self = [super init])) {
    _cacheHits = cacheHits;
    _revalidated = revalidated;
    _networkLoads = networkLoads;
    _other = other;
    _networkBytes = networkBytes;
  }
  return self;
}
@end

/// Signposts for Instruments / xctrace (same subsystem and categories as
/// Signposts.swift); see docs/profiling.md.
static os_log_t CNSignpostLog(const char* category) {
  static os_log_t tiles, frame;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    tiles = os_log_create("dev.also.maps", "Tiles");
    frame = os_log_create("dev.also.maps", "Frame");
  });
  return category[0] == 'F' ? frame : tiles;
}

// ── cesium-native externals ──────────────────────────────────────────────────

namespace {

class GCDTaskProcessor final : public ITaskProcessor {
public:
  void startTask(std::function<void()> f) override {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      f();
    });
  }
};

class SessionResponse final : public IAssetResponse {
public:
  uint16_t status = 0;
  std::string type;
  HttpHeaders responseHeaders;
  std::vector<std::byte> body;

  uint16_t statusCode() const override { return status; }
  std::string contentType() const override { return type; }
  const HttpHeaders& headers() const override { return responseHeaders; }
  std::span<const std::byte> data() const override { return body; }
};

class SessionRequest final : public IAssetRequest {
public:
  SessionRequest(std::string method, std::string url, HttpHeaders headers)
      : _method(std::move(method)), _url(std::move(url)),
        _headers(std::move(headers)) {}

  const std::string& method() const override { return _method; }
  const std::string& url() const override { return _url; }
  const HttpHeaders& headers() const override { return _headers; }
  const IAssetResponse* response() const override { return _response.get(); }

  std::unique_ptr<SessionResponse> _response;

private:
  std::string _method;
  std::string _url;
  HttpHeaders _headers;
};

} // namespace

/// How each request was satisfied, counted from URLSessionTaskMetrics.
struct FetchCounters {
  std::atomic<uint64_t> cacheHits{0};      // fresh entry from NSURLCache
  std::atomic<uint64_t> revalidated{0};    // network round trip, answered 304
  std::atomic<uint64_t> networkLoads{0};   // full download
  std::atomic<uint64_t> other{0};
  std::atomic<uint64_t> networkBytes{0};   // response body bytes off the wire
  std::atomic<int> keyFailureStatus{0};    // last 400, 401, 403 or 429
};

/// Google sends `Cache-Control: private, max-age=14400, must-revalidate`.
/// By the HTTP spec must-revalidate only applies once a response is stale, but
/// CFNetwork revalidates on every request (a 304 round trip per tile). Drop
/// the directive as the response is stored, so max-age is honoured as sent:
/// tiles are served from disk for four hours, then revalidated by ETag.
@interface CNTileCache : NSURLCache
@end

@implementation CNTileCache
- (void)storeCachedResponse:(NSCachedURLResponse*)cachedResponse
                 forRequest:(NSURLRequest*)request {
  NSHTTPURLResponse* http = (NSHTTPURLResponse*)cachedResponse.response;
  NSString* control = [http isKindOfClass:NSHTTPURLResponse.class]
                          ? http.allHeaderFields[@"Cache-Control"]
                          : nil;
  if (![control isKindOfClass:NSString.class] ||
      [control rangeOfString:@"must-revalidate"
                     options:NSCaseInsensitiveSearch]
              .location == NSNotFound) {
    [super storeCachedResponse:cachedResponse forRequest:request];
    return;
  }
  NSMutableArray<NSString*>* kept = [NSMutableArray array];
  for (NSString* part in [control componentsSeparatedByString:@","]) {
    NSString* directive =
        [part stringByTrimmingCharactersInSet:NSCharacterSet
                                                  .whitespaceCharacterSet];
    if ([directive caseInsensitiveCompare:@"must-revalidate"] !=
        NSOrderedSame) {
      [kept addObject:directive];
    }
  }
  NSMutableDictionary* headers = [http.allHeaderFields mutableCopy];
  headers[@"Cache-Control"] = [kept componentsJoinedByString:@", "];
  NSHTTPURLResponse* rewritten =
      [[NSHTTPURLResponse alloc] initWithURL:http.URL
                                  statusCode:http.statusCode
                                 HTTPVersion:@"HTTP/1.1"
                                headerFields:headers];
  if (!rewritten) {
    [super storeCachedResponse:cachedResponse forRequest:request];
    return;
  }
  [super storeCachedResponse:[[NSCachedURLResponse alloc]
                                 initWithResponse:rewritten
                                             data:cachedResponse.data
                                         userInfo:cachedResponse.userInfo
                                    storagePolicy:cachedResponse.storagePolicy]
                  forRequest:request];
}
@end

/// The one tile cache, shared by every streamer's session. The app can run
/// more than one streamer at once (a second tileset beside the main one, or
/// a restart while the old streamer drains), and separate NSURLCache
/// instances over the same directory would each keep their own index of it.
/// NSURLCache is thread-safe, so one instance serves every session.
static CNTileCache* CNSharedTileCache(void) {
  static CNTileCache* cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // The system's shared cache is ~10 MB on disk, far less than one scene (~56 MB),
    // so tiles were evicted before the next load. Responses over 5% of the
    // disk capacity aren't stored, so this stays well above the largest tile.
    NSURL* cachesDir = [NSFileManager.defaultManager
        URLForDirectory:NSCachesDirectory
               inDomain:NSUserDomainMask
      appropriateForURL:nil
                 create:YES
                  error:nil];
    // Unsandboxed builds share ~/Library/Caches, so namespace by bundle.
    NSString* bundleName = NSBundle.mainBundle.bundleIdentifier ?: @"AlsoMaps";
    NSURL* tilesDir = [[cachesDir URLByAppendingPathComponent:bundleName
                                                  isDirectory:YES]
        URLByAppendingPathComponent:@"tiles"
                        isDirectory:YES];
    cache = [[CNTileCache alloc] initWithMemoryCapacity:64ull * 1024 * 1024
                                           diskCapacity:1024ull * 1024 * 1024
                                           directoryURL:tilesDir];
  });
  return cache;
}

@interface CNMetricsDelegate : NSObject <NSURLSessionTaskDelegate>
- (instancetype)initWithCounters:(std::shared_ptr<FetchCounters>)counters;
@end

@implementation CNMetricsDelegate {
  std::shared_ptr<FetchCounters> _counters;
}

- (instancetype)initWithCounters:(std::shared_ptr<FetchCounters>)counters {
  if ((self = [super init])) {
    _counters = std::move(counters);
  }
  return self;
}

// Called for completion-handler tasks too.
- (void)URLSession:(NSURLSession*)session
                          task:(NSURLSessionTask*)task
    didFinishCollectingMetrics:(NSURLSessionTaskMetrics*)metrics {
  NSURLSessionTaskTransactionMetrics* last = metrics.transactionMetrics.lastObject;
  if (!last) {
    return;
  }
  switch (last.resourceFetchType) {
    case NSURLSessionTaskMetricsResourceFetchTypeLocalCache:
      ++_counters->cacheHits;
      break;
    case NSURLSessionTaskMetricsResourceFetchTypeNetworkLoad: {
      NSInteger status = [last.response isKindOfClass:NSHTTPURLResponse.class]
                             ? ((NSHTTPURLResponse*)last.response).statusCode
                             : 0;
      if (status == 304) {
        ++_counters->revalidated;
      } else {
        ++_counters->networkLoads;
      }
      _counters->networkBytes += uint64_t(last.countOfResponseBodyBytesReceived);
      break;
    }
    default:
      ++_counters->other;
  }
}
@end

namespace {

/// IAssetAccessor over NSURLSession. cesium-native is built with curl
/// disabled, so this is its only network path. NSURLCache gives us a basic
/// HTTP cache for free (within Google's caching terms).
class URLSessionAssetAccessor final : public IAssetAccessor {
public:
  explicit URLSessionAssetAccessor(std::shared_ptr<FetchCounters> counters)
      : _counters(counters) {
    NSURLSessionConfiguration* config =
        [NSURLSessionConfiguration defaultSessionConfiguration];
    config.HTTPMaximumConnectionsPerHost = 12;
    config.URLCache = CNSharedTileCache();
    config.requestCachePolicy = NSURLRequestUseProtocolCachePolicy;
    _session = [NSURLSession
        sessionWithConfiguration:config
                        delegate:[[CNMetricsDelegate alloc]
                                     initWithCounters:std::move(counters)]
                   delegateQueue:nil];
    // An API key restricted to iOS apps is checked against this header.
    NSString* bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (bundleID) {
      _bundleID = bundleID.UTF8String;
    }
  }

  Future<std::shared_ptr<IAssetRequest>>
  get(const AsyncSystem& asyncSystem,
      const std::string& url,
      const std::vector<THeader>& headers) override {
    return request(asyncSystem, "GET", url, headers, {});
  }

  Future<std::shared_ptr<IAssetRequest>> request(
      const AsyncSystem& asyncSystem,
      const std::string& verb,
      const std::string& url,
      const std::vector<THeader>& headers,
      const std::span<const std::byte>& contentPayload) override {
    auto promise = asyncSystem.createPromise<std::shared_ptr<IAssetRequest>>();

    NSURL* nsURL = [NSURL URLWithString:@(url.c_str())];
    if (!nsURL) {
      promise.reject(std::runtime_error("Invalid URL: " + url));
      return promise.getFuture();
    }

    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:nsURL];
    req.HTTPMethod = @(verb.c_str());
    HttpHeaders requestHeaders;
    for (const THeader& header : headers) {
      requestHeaders[header.first] = header.second;
      [req setValue:@(header.second.c_str())
          forHTTPHeaderField:@(header.first.c_str())];
    }
    if (!_bundleID.empty() &&
        requestHeaders.find("X-Ios-Bundle-Identifier") == requestHeaders.end()) {
      [req setValue:@(_bundleID.c_str())
          forHTTPHeaderField:@"X-Ios-Bundle-Identifier"];
    }
    if (!contentPayload.empty()) {
      req.HTTPBody = [NSData dataWithBytes:contentPayload.data()
                                    length:contentPayload.size()];
    }

    auto pRequest =
        std::make_shared<SessionRequest>(verb, url, std::move(requestHeaders));

    os_log_t log = CNSignpostLog("Tiles");
    const os_signpost_id_t signpostID = os_signpost_id_generate(log);
    os_signpost_interval_begin(log, signpostID, "Fetch");
    std::shared_ptr<FetchCounters> failures = _counters;
    NSURLSessionDataTask* task = [_session
        dataTaskWithRequest:req
          completionHandler:^(
              NSData* data, NSURLResponse* response, NSError* error) {
            const NSInteger status =
                [response isKindOfClass:NSHTTPURLResponse.class]
                    ? ((NSHTTPURLResponse*)response).statusCode
                    : 0;
            os_signpost_interval_end(log,
                                     signpostID,
                                     "Fetch",
                                     "status %ld, %lu bytes%{public}s",
                                     (long)status,
                                     (unsigned long)data.length,
                                     error ? ", failed" : "");
            if (error) {
              promise.reject(
                  std::runtime_error(error.localizedDescription.UTF8String));
              return;
            }
            if (status == 400 || status == 401 || status == 403 ||
                status == 429) {
              failures->keyFailureStatus = int(status);
            }
            auto pResponse = std::make_unique<SessionResponse>();
            if ([response isKindOfClass:NSHTTPURLResponse.class]) {
              NSHTTPURLResponse* http = (NSHTTPURLResponse*)response;
              pResponse->status = static_cast<uint16_t>(http.statusCode);
              HttpHeaders& responseHeaders = pResponse->responseHeaders;
              for (id key in http.allHeaderFields) {
                responseHeaders[[key description].UTF8String] =
                    [http.allHeaderFields[key] description].UTF8String;
              }
            }
            if (response.MIMEType) {
              pResponse->type = response.MIMEType.UTF8String;
            }
            const std::byte* bytes = static_cast<const std::byte*>(data.bytes);
            pResponse->body.assign(bytes, bytes + data.length);
            pRequest->_response = std::move(pResponse);
            promise.resolve(pRequest);
          }];
    [task resume];
    return promise.getFuture();
  }

  void tick() noexcept override {}

private:
  NSURLSession* _session;
  std::string _bundleID;
  std::shared_ptr<FetchCounters> _counters;
};

// RealityKit axes from local east-north-up: x = east, y = up, z = south.
const glm::dmat4 kEnuToRealityKit(
    glm::dvec4(1.0, 0.0, 0.0, 0.0),
    glm::dvec4(0.0, 0.0, -1.0, 0.0),
    glm::dvec4(0.0, 1.0, 0.0, 0.0),
    glm::dvec4(0.0, 0.0, 0.0, 1.0));

NSData* _Nullable
convertImageToRGBA(const CesiumImage::ImageAsset& image) {
  if (image.bytesPerChannel != 1 || image.width <= 0 || image.height <= 0 ||
      (image.channels != 3 && image.channels != 4)) {
    return nil;
  }
  const size_t pixels = size_t(image.width) * size_t(image.height);
  if (image.pixelData.size() < pixels * size_t(image.channels)) {
    return nil;
  }
  if (image.channels == 4) {
    return [NSData dataWithBytes:image.pixelData.data() length:pixels * 4];
  }
  NSMutableData* out = [NSMutableData dataWithLength:pixels * 4];
  uint8_t* dst = static_cast<uint8_t*>(out.mutableBytes);
  const uint8_t* src = reinterpret_cast<const uint8_t*>(image.pixelData.data());
  for (size_t i = 0; i < pixels; ++i) {
    dst[i * 4 + 0] = src[i * 3 + 0];
    dst[i * 4 + 1] = src[i * 3 + 1];
    dst[i * 4 + 2] = src[i * 3 + 2];
    dst[i * 4 + 3] = 255;
  }
  return out;
}

template <typename T>
bool appendIndices(
    const CesiumGltf::Model& model,
    int32_t accessor,
    std::vector<uint32_t>& out) {
  CesiumGltf::AccessorView<T> view(model, accessor);
  if (view.status() != CesiumGltf::AccessorViewStatus::Valid) {
    return false;
  }
  out.reserve(size_t(view.size()));
  for (int64_t i = 0; i < view.size(); ++i) {
    out.push_back(uint32_t(view[i]));
  }
  return true;
}

/// Flattens a tile's glTF into CNPrimitives in the local RealityKit frame.
/// Flattens a tile's glTF into CNPrimitives whose positions are ECEF offsets
/// (metres, ECEF axes) from a centre point on the tile. Offsets stay small,
/// so 32-bit floats keep them precise anywhere on Earth; the centre itself is
/// kept in double and placed relative to the anchor every frame.
CNTileMesh* _Nullable buildTileMesh(
    const CesiumGltf::Model& model,
    const glm::dmat4& tileTransform,
    uint64_t identifier) {
  using namespace CesiumGltf;
  using CesiumGltfContent::GltfUtilities;

  glm::dmat4 rootTransform = GltfUtilities::applyRtcCenter(model, tileTransform);
  rootTransform = GltfUtilities::applyGltfUpAxisTransform(model, rootTransform);
  // The first vertex seen; any point on the tile keeps offsets tile-sized.
  std::optional<glm::dvec3> center;
  // Extent and height range, for ground estimates without the network.
  double radius = 0.0;
  double minimumHeight = INFINITY;
  double maximumHeight = -INFINITY;

  NSMutableArray<CNPrimitive*>* primitives = [NSMutableArray array];

  model.forEachPrimitiveInScene(
      -1,
      [&](const Model& gltf,
          const Node&,
          const Mesh&,
          const MeshPrimitive& primitive,
          const glm::dmat4& nodeTransform) {
        if (primitive.mode != MeshPrimitive::Mode::TRIANGLES) {
          return;
        }
        auto positionIt = primitive.attributes.find("POSITION");
        if (positionIt == primitive.attributes.end()) {
          return;
        }
        AccessorView<glm::vec3> positions(gltf, positionIt->second);
        if (positions.status() != AccessorViewStatus::Valid ||
            positions.size() == 0) {
          return;
        }

        const glm::dmat4 transform = rootTransform * nodeTransform;
        const size_t vertexCount = size_t(positions.size());
        if (!center) {
          center = glm::dvec3(
              transform * glm::dvec4(glm::dvec3(positions[0]), 1.0));
        }
        NSMutableData* positionData =
            [NSMutableData dataWithLength:vertexCount * 4 * sizeof(float)];
        float* p = static_cast<float*>(positionData.mutableBytes);
        for (size_t i = 0; i < vertexCount; ++i) {
          const glm::dvec3 v = glm::dvec3(
              transform * glm::dvec4(glm::dvec3(positions[int64_t(i)]), 1.0)) -
                               *center;
          radius = std::max(radius, glm::length(v));
          const double height = radialHeight(*center + v);
          minimumHeight = std::min(minimumHeight, height);
          maximumHeight = std::max(maximumHeight, height);
          p[i * 4 + 0] = float(v.x);
          p[i * 4 + 1] = float(v.y);
          p[i * 4 + 2] = float(v.z);
          p[i * 4 + 3] = 0.0f;
        }

        // Base colour texture (photogrammetry is unlit; that's all there is).
        int64_t texCoordSet = 0;
        const CesiumImage::ImageAsset* pImage = nullptr;
        Sampler sampler;
        if (const Material* pMaterial =
                Model::getSafe(&gltf.materials, primitive.material)) {
          if (pMaterial->pbrMetallicRoughness &&
              pMaterial->pbrMetallicRoughness->baseColorTexture) {
            const TextureInfo& info =
                *pMaterial->pbrMetallicRoughness->baseColorTexture;
            texCoordSet = info.texCoord;
            if (const Texture* pTexture =
                    Model::getSafe(&gltf.textures, info.index)) {
              if (const Image* pGltfImage =
                      Model::getSafe(&gltf.images, pTexture->source)) {
                pImage = pGltfImage->pAsset.get();
              }
              if (const Sampler* pSampler =
                      Model::getSafe(&gltf.samplers, pTexture->sampler)) {
                sampler = *pSampler;
              }
            }
          }
        }

        NSData* rgba = pImage ? convertImageToRGBA(*pImage) : nil;
        NSMutableData* texcoordData = nil;
        if (rgba) {
          auto uvIt = primitive.attributes.find(
              "TEXCOORD_" + std::to_string(texCoordSet));
          if (uvIt != primitive.attributes.end()) {
            AccessorView<glm::vec2> uvs(gltf, uvIt->second);
            if (uvs.status() == AccessorViewStatus::Valid &&
                size_t(uvs.size()) == vertexCount) {
              texcoordData =
                  [NSMutableData dataWithLength:vertexCount * 2 * sizeof(float)];
              float* t = static_cast<float*>(texcoordData.mutableBytes);
              for (size_t i = 0; i < vertexCount; ++i) {
                const glm::vec2 uv = uvs[int64_t(i)];
                t[i * 2 + 0] = uv.x;
                t[i * 2 + 1] = 1.0f - uv.y;
              }
            }
          }
          if (!texcoordData) {
            rgba = nil;
          }
        }

        std::vector<uint32_t> indices;
        if (const Accessor* pIndices =
                Model::getSafe(&gltf.accessors, primitive.indices)) {
          bool ok = false;
          switch (pIndices->componentType) {
          case Accessor::ComponentType::UNSIGNED_BYTE:
            ok = appendIndices<uint8_t>(gltf, primitive.indices, indices);
            break;
          case Accessor::ComponentType::UNSIGNED_SHORT:
            ok = appendIndices<uint16_t>(gltf, primitive.indices, indices);
            break;
          case Accessor::ComponentType::UNSIGNED_INT:
            ok = appendIndices<uint32_t>(gltf, primitive.indices, indices);
            break;
          default:
            break;
          }
          if (!ok) {
            return;
          }
        } else {
          indices.resize(vertexCount);
          for (size_t i = 0; i < vertexCount; ++i) {
            indices[i] = uint32_t(i);
          }
        }
        if (indices.size() < 3) {
          return;
        }

        simd_float4 baseColor = simd_make_float4(1, 1, 1, 1);
        if (const Material* pMaterial =
                Model::getSafe(&gltf.materials, primitive.material)) {
          if (pMaterial->pbrMetallicRoughness &&
              pMaterial->pbrMetallicRoughness->baseColorFactor.size() == 4) {
            const auto& factor = pMaterial->pbrMetallicRoughness->baseColorFactor;
            baseColor = simd_make_float4(
                float(factor[0]), float(factor[1]), float(factor[2]), float(factor[3]));
          }
        }

        // Untextured content (e.g. OSM buildings) is drawn lit, so it needs
        // normals: the glTF's, rotated into ECEF axes, or else flat ones.
        // Flat normals need each triangle to have its own vertices.
        NSMutableData* normalData = nil;
        if (!rgba) {
          auto normalIt = primitive.attributes.find("NORMAL");
          std::optional<AccessorView<glm::vec3>> normals;
          if (normalIt != primitive.attributes.end()) {
            normals.emplace(gltf, normalIt->second);
            if (normals->status() != AccessorViewStatus::Valid ||
                size_t(normals->size()) != vertexCount) {
              normals.reset();
            }
          }
          if (normals) {
            const glm::dmat3 rotation(transform);
            normalData =
                [NSMutableData dataWithLength:vertexCount * 4 * sizeof(float)];
            float* n = static_cast<float*>(normalData.mutableBytes);
            for (size_t i = 0; i < vertexCount; ++i) {
              const glm::dvec3 v = glm::normalize(
                  rotation * glm::dvec3((*normals)[int64_t(i)]));
              n[i * 4 + 0] = float(v.x);
              n[i * 4 + 1] = float(v.y);
              n[i * 4 + 2] = float(v.z);
              n[i * 4 + 3] = 0.0f;
            }
          } else {
            const float* source = static_cast<const float*>(positionData.bytes);
            const size_t triangles = indices.size() / 3;
            NSMutableData* flatPositions = [NSMutableData
                dataWithLength:triangles * 3 * 4 * sizeof(float)];
            normalData = [NSMutableData
                dataWithLength:triangles * 3 * 4 * sizeof(float)];
            float* fp = static_cast<float*>(flatPositions.mutableBytes);
            float* fn = static_cast<float*>(normalData.mutableBytes);
            std::vector<uint32_t> flatIndices(triangles * 3);
            for (size_t t = 0; t < triangles; ++t) {
              glm::vec3 corner[3];
              for (int k = 0; k < 3; ++k) {
                const float* q = source + size_t(indices[t * 3 + k]) * 4;
                corner[k] = glm::vec3(q[0], q[1], q[2]);
              }
              glm::vec3 normal = glm::cross(corner[1] - corner[0], corner[2] - corner[0]);
              const float length = glm::length(normal);
              normal = length > 0 ? normal / length : glm::vec3(0, 0, 1);
              for (int k = 0; k < 3; ++k) {
                const size_t out = t * 3 + size_t(k);
                fp[out * 4 + 0] = corner[k].x;
                fp[out * 4 + 1] = corner[k].y;
                fp[out * 4 + 2] = corner[k].z;
                fp[out * 4 + 3] = 0.0f;
                fn[out * 4 + 0] = normal.x;
                fn[out * 4 + 1] = normal.y;
                fn[out * 4 + 2] = normal.z;
                fn[out * 4 + 3] = 0.0f;
                flatIndices[out] = uint32_t(out);
              }
            }
            positionData = flatPositions;
            indices = std::move(flatIndices);
          }
        }

        NSData* indexData =
            [NSData dataWithBytes:indices.data()
                           length:indices.size() * sizeof(uint32_t)];
        NSInteger width = rgba && pImage ? pImage->width : 0;
        NSInteger height = rgba && pImage ? pImage->height : 0;
        [primitives addObject:[[CNPrimitive alloc] initWithPositions:positionData
                                                           texcoords:texcoordData
                                                             normals:normalData
                                                             indices:indexData
                                                                rgba:rgba
                                                               width:width
                                                              height:height
                                                             sampler:sampler
                                                           baseColor:baseColor]];
      });

  if (primitives.count == 0 || !center) {
    return nil;
  }
  return [[CNTileMesh alloc] initWithIdentifier:identifier
                                         center:*center
                                         radius:radius
                                  minimumHeight:minimumHeight
                                  maximumHeight:maximumHeight
                                     primitives:primitives];
}

/// Holds each tile's CNTileMesh as a retained void* inside cesium-native and
/// reports frees back to Swift so it can drop the matching entity.
class RealityKitPrepareRendererResources final
    : public IPrepareRendererResources {
public:
  void setTileLoadHandler(CNTileLoadHandler handler) {
    std::lock_guard<std::mutex> lock(_handlerMutex);
    _handler = handler;
  }

  Future<TileLoadResultAndRenderResources> prepareInLoadThread(
      const AsyncSystem& asyncSystem,
      TileLoadResult&& tileLoadResult,
      const glm::dmat4& transform,
      const std::any&) override {
    CNTileMesh* mesh = nil;
    if (const CesiumGltf::Model* pModel =
            std::get_if<CesiumGltf::Model>(&tileLoadResult.contentKind)) {
      os_log_t log = CNSignpostLog("Tiles");
      const os_signpost_id_t signpostID = os_signpost_id_generate(log);
      os_signpost_interval_begin(log, signpostID, "Flatten");
      mesh = buildTileMesh(*pModel, transform, _nextID++);
      os_signpost_interval_end(log, signpostID, "Flatten");
    }
    CNTileLoadHandler handler = tileLoadHandler();
    if (!mesh || !handler) {
      void* pResources = mesh ? (__bridge_retained void*)mesh : nullptr;
      return asyncSystem.createResolvedFuture(TileLoadResultAndRenderResources{
          std::move(tileLoadResult),
          pResources});
    }

    // Hand the tile to the app and finish loading only once its renderer
    // resources exist, so "loaded" means "drawable". The result moves into
    // shared state the completion block can reach; `once` guards against a
    // second call.
    auto promise =
        asyncSystem.createPromise<TileLoadResultAndRenderResources>();
    auto pResult = std::make_shared<TileLoadResult>(std::move(tileLoadResult));
    auto once = std::make_shared<std::atomic<bool>>(false);
    void* pResources = (__bridge_retained void*)mesh;
    handler(mesh, ^{
      if (once->exchange(true)) {
        return;
      }
      promise.resolve(TileLoadResultAndRenderResources{
          std::move(*pResult),
          pResources});
    });
    return promise.getFuture();
  }

  void* prepareInMainThread(Tile&, void* pLoadThreadResult) override {
    // Ownership of the retained CNTileMesh moves from the load-thread slot to
    // the main-thread slot unchanged.
    return pLoadThreadResult;
  }

  void free(Tile&, void* pLoadThreadResult, void* pMainThreadResult) noexcept
      override {
    void* p = pMainThreadResult ? pMainThreadResult : pLoadThreadResult;
    if (!p) {
      return;
    }
    CNTileMesh* mesh = (__bridge_transfer CNTileMesh*)p;
    std::lock_guard<std::mutex> lock(_freedMutex);
    _freed.push_back(mesh.identifier);
  }

  void* prepareRasterInLoadThread(
      CesiumImage::ImageAsset&,
      const std::any&) override {
    return nullptr;
  }
  void* prepareRasterInMainThread(
      CesiumRasterOverlays::RasterOverlayTile&,
      void*) override {
    return nullptr;
  }
  void freeRaster(
      const CesiumRasterOverlays::RasterOverlayTile&,
      void*,
      void*) noexcept override {}
  void attachRasterInMainThread(
      const Tile&,
      int32_t,
      const CesiumRasterOverlays::RasterOverlayTile&,
      void*,
      const glm::dvec2&,
      const glm::dvec2&) override {}
  void detachRasterInMainThread(
      const Tile&,
      int32_t,
      const CesiumRasterOverlays::RasterOverlayTile&,
      void*) noexcept override {}

  CNTileLoadHandler tileLoadHandler() {
    std::lock_guard<std::mutex> lock(_handlerMutex);
    return _handler;
  }

  std::vector<uint64_t> takeFreed() {
    std::lock_guard<std::mutex> lock(_freedMutex);
    return std::exchange(_freed, {});
  }

private:
  std::atomic<uint64_t> _nextID{1};
  std::mutex _handlerMutex;
  CNTileLoadHandler _handler;
  std::mutex _freedMutex;
  std::vector<uint64_t> _freed;
};

/// Skips tiles whose bounding sphere lies entirely outside the area of
/// interest, a square around the anchor, so only what can be shown streams.
/// The square is measured in the anchor's own east-north-up frame, so it
/// stays true however far the anchor is from where the tileset was opened.
class AreaOfInterestExcluder final : public ITileExcluder {
public:
  /// ECEF → anchor east-north-up; updated every frame.
  glm::dmat4 ecefToAnchorEnu{1.0};
  double radius = 500.0;
  /// Unit up at the anchor (ECEF). At hemisphere-scale zoom the tangent-plane
  /// square also covers the far side of the Earth; anything entirely on the
  /// hemisphere opposite the anchor is skipped.
  glm::dvec3 anchorUp{0.0, 0.0, 1.0};

  bool shouldExclude(const Tile& tile) const noexcept override {
    const CesiumGeometry::BoundingSphere sphere =
        getOrientedBoundingBoxFromBoundingVolume(tile.getBoundingVolume())
            .toSphere();
    if (glm::dot(sphere.getCenter(), anchorUp) + sphere.getRadius() < 0.0) {
      return true;
    }
    const glm::dvec3 center =
        glm::dvec3(ecefToAnchorEnu * glm::dvec4(sphere.getCenter(), 1.0));
    const double r = sphere.getRadius();
    return std::abs(center.x) - r > radius || std::abs(center.y) - r > radius;
  }
};

/// The src of the first <img> in a credit's HTML, if any (e.g. the
/// Cesium ion logo).
NSString* _Nullable firstImageSource(const std::string& html) {
  const size_t img = html.find("<img");
  if (img == std::string::npos) {
    return nil;
  }
  const size_t src = html.find("src=", img);
  if (src == std::string::npos || src + 5 >= html.size()) {
    return nil;
  }
  const char quote = html[src + 4];
  if (quote != '"' && quote != '\'') {
    return nil;
  }
  const size_t end = html.find(quote, src + 5);
  if (end == std::string::npos) {
    return nil;
  }
  return @(html.substr(src + 5, end - src - 5).c_str());
}

NSString* stripHTML(const std::string& html) {
  std::string text;
  text.reserve(html.size());
  bool inTag = false;
  for (char c : html) {
    if (c == '<') {
      inTag = true;
    } else if (c == '>') {
      inTag = false;
    } else if (!inTag) {
      text.push_back(c);
    }
  }
  NSString* result = @(text.c_str());
  return [result
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
}

} // namespace

// ── CNTileStreamer ───────────────────────────────────────────────────────────

@interface CNTileStreamer ()
- (instancetype)initWithTilesetMaker:
    (std::function<std::unique_ptr<Tileset>(
         const TilesetExternals&,
         const TilesetOptions&)>)makeTileset NS_DESIGNATED_INITIALIZER;
@end

// Runs an abandoned streamer's main-thread tasks until `finished`, then lets
// go of its AsyncSystem. The last task runs after the flag is seen, so nothing
// is left queued.
static void drainMainThreadTasks(AsyncSystem asyncSystem,
                                 std::shared_ptr<std::atomic<bool>> finished) {
  const bool done = finished->load();
  asyncSystem.dispatchMainThreadTasks();
  if (done) {
    return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
                   drainMainThreadTasks(asyncSystem, finished);
                 });
}

@implementation CNTileStreamer {
  // AsyncSystem has no default constructor; constructed in init.
  std::optional<AsyncSystem> _asyncSystem;
  std::shared_ptr<CesiumUtility::CreditSystem> _creditSystem;
  std::shared_ptr<RealityKitPrepareRendererResources> _resources;
  std::shared_ptr<AreaOfInterestExcluder> _excluder;
  std::unique_ptr<Tileset> _tileset;
  std::shared_ptr<FetchCounters> _fetchCounters;
  CNFrame* _lastFrame;
}

- (void)dealloc {
  // ~Tileset fails pending height samples and leaves in-flight loads to finish,
  // both through the main-thread queue, which frames no longer service.
  // Destroying AsyncSystem with tasks queued cancels them into the dying
  // scheduler, which crashes, so keep servicing it until the tileset is done.
  if (!_tileset) {
    return;
  }
  auto finished = std::make_shared<std::atomic<bool>>(false);
  _tileset->getAsyncDestructionCompleteEvent().thenImmediately(
      [finished]() { finished->store(true); });
  _tileset.reset();
  AsyncSystem asyncSystem = *_asyncSystem;
  dispatch_async(dispatch_get_main_queue(), ^{
    drainMainThreadTasks(asyncSystem, finished);
  });
}

- (instancetype)initWithTilesetURL:(NSString*)url {
  std::string tilesetURL = url.UTF8String;
  return [self initWithTilesetMaker:[tilesetURL](
                                        const TilesetExternals& externals,
                                        const TilesetOptions& options) {
    return std::make_unique<Tileset>(externals, tilesetURL, options);
  }];
}

- (instancetype)initWithIonAssetID:(int64_t)assetID
                       accessToken:(NSString*)accessToken
                     smoothNormals:(BOOL)smoothNormals {
  std::string token = accessToken.UTF8String;
  return [self initWithTilesetMaker:[assetID, token, smoothNormals](
                                        const TilesetExternals& externals,
                                        const TilesetOptions& options) {
    TilesetOptions ionOptions = options;
    ionOptions.contentOptions.generateMissingNormalsSmooth = smoothNormals;
    return std::make_unique<Tileset>(externals, assetID, token, ionOptions);
  }];
}

- (instancetype)initWithTilesetMaker:
    (std::function<std::unique_ptr<Tileset>(
         const TilesetExternals&,
         const TilesetOptions&)>)makeTileset {
  if ((self = [super init])) {
    // Without this, b3dm/glb/i3dm/pnts content is not recognised and the
    // loader falls back to parsing it as an external tileset.json.
    static dispatch_once_t registerOnce;
    dispatch_once(&registerOnce, ^{
      Cesium3DTilesContent::registerAllTileContentTypes();
    });

    _asyncSystem.emplace(std::make_shared<GCDTaskProcessor>());
    _fetchCounters = std::make_shared<FetchCounters>();

    _creditSystem = std::make_shared<CesiumUtility::CreditSystem>();
    _resources = std::make_shared<RealityKitPrepareRendererResources>();
    _excluder = std::make_shared<AreaOfInterestExcluder>();

    TilesetExternals externals{
        .pAssetAccessor =
            std::make_shared<URLSessionAssetAccessor>(_fetchCounters),
        .pPrepareRendererResources = _resources,
        .asyncSystem = *_asyncSystem,
        .pCreditSystem = _creditSystem,
    };

    TilesetOptions options;
    options.maximumScreenSpaceError = 16.0;
    options.maximumCachedBytes = 512ull * 1024 * 1024;
    options.enableFogCulling = false;
    // Draw the whole area of interest: tiles outside the LOD camera's view
    // refine to culledScreenSpaceError (outer detail) instead of vanishing.
    // In VR the viewer can look anywhere.
    options.enableFrustumCulling = false;
    options.forbidHoles = false;
    options.showCreditsOnScreen = true;
    options.excluders = {_excluder};
    options.loadErrorCallback = [](const TilesetLoadFailureDetails& details) {
      NSLog(@"[cesium] tileset load failed (HTTP %d): %s",
            int(details.statusCode),
            details.message.c_str());
    };

    _tileset = makeTileset(externals, options);

    _streamingRadius = 500.0;
    // Looking at the anchor from 1.2 km away, 45° up, facing north.
    _viewPosition = simd_make_double3(0, 848.5, 848.5);
    _viewDirection = simd_make_double3(0, -M_SQRT1_2, -M_SQRT1_2);
    _viewUp = simd_make_double3(0, M_SQRT1_2, -M_SQRT1_2);
    _viewFieldOfView = M_PI / 3;
    _viewAspect = 1;
  }
  return self;
}

- (CNTileLoadHandler)tileLoadHandler {
  return _resources->tileLoadHandler();
}

- (void)setTileLoadHandler:(CNTileLoadHandler)handler {
  _resources->setTileLoadHandler(handler);
}

- (double)maximumScreenSpaceError {
  return _tileset->getOptions().maximumScreenSpaceError;
}

- (void)setMaximumScreenSpaceError:(double)value {
  _tileset->getOptions().maximumScreenSpaceError = value;
}

- (double)culledScreenSpaceError {
  return _tileset->getOptions().culledScreenSpaceError;
}

- (void)setCulledScreenSpaceError:(double)value {
  _tileset->getOptions().culledScreenSpaceError = value;
}

- (NSInteger)maximumSimultaneousTileLoads {
  return NSInteger(_tileset->getOptions().maximumSimultaneousTileLoads);
}

- (void)setMaximumSimultaneousTileLoads:(NSInteger)value {
  _tileset->getOptions().maximumSimultaneousTileLoads =
      uint32_t(std::max<NSInteger>(1, value));
}

- (NSInteger)takeKeyFailureStatus {
  return _fetchCounters->keyFailureStatus.exchange(0);
}

- (CNFetchStats*)fetchStats {
  return [[CNFetchStats alloc] initWithCacheHits:_fetchCounters->cacheHits
                                     revalidated:_fetchCounters->revalidated
                                    networkLoads:_fetchCounters->networkLoads
                                           other:_fetchCounters->other
                                    networkBytes:_fetchCounters->networkBytes];
}

- (int64_t)maximumCachedBytes {
  return _tileset->getOptions().maximumCachedBytes;
}

- (void)setMaximumCachedBytes:(int64_t)value {
  _tileset->getOptions().maximumCachedBytes = value;
}

- (BOOL)forbidHoles {
  return _tileset->getOptions().forbidHoles;
}

- (void)setForbidHoles:(BOOL)value {
  _tileset->getOptions().forbidHoles = value;
}

/// The anchor point: anchorHeight above the ellipsoid at its latitude and
/// longitude.
- (glm::dvec3)anchorECEF {
  return Ellipsoid::WGS84.cartographicToCartesian(Cartographic::fromDegrees(
      _anchorLongitude,
      _anchorLatitude,
      _anchorHeight));
}

/// Local east-north-up at the anchor, as a transform to ECEF.
- (glm::dmat4)anchorEnuToEcef {
  return CesiumGeospatial::GlobeTransforms::eastNorthUpToFixedFrame(
      [self anchorECEF]);
}

/// The anchor frame's RealityKit axes (x east, y up, z south) as
/// east-north-up.
static glm::dvec3 enuFromAnchorAxes(simd_double3 v) {
  return glm::dvec3(v.x, -v.z, v.y);
}

/// The last frame again, with no new selection: for an update that can't
/// run. Loads already in flight keep going.
- (CNFrame*)repeatLastFrame {
  _asyncSystem->dispatchMainThreadTasks();
  CNFrame* frame = [[CNFrame alloc] init];
  frame.tilesToRender = _lastFrame.tilesToRender ?: @[];
  frame.tileTransforms = _lastFrame.tileTransforms ?: [NSData data];
  frame.tileBounds = _lastFrame.tileBounds;
  frame.freedTileIDs = @[];
  frame.credits = _lastFrame.credits ?: @[];
  frame.loadProgress = _lastFrame.loadProgress;
  return frame;
}

- (CNFrame*)updateWithDeltaTime:(float)deltaTime {
  // Ends when the method returns, on any path.
  struct SelectSignpost {
    os_log_t log = CNSignpostLog("Frame");
    os_signpost_id_t id = os_signpost_id_generate(log);
    SelectSignpost() { os_signpost_interval_begin(log, id, "Select"); }
    ~SelectSignpost() { os_signpost_interval_end(log, id, "Select"); }
  } selectSignpost;
  // The excluder's square is axis-aligned in east/north; when the region is
  // turned, grow it to the square that encloses the rotated one.
  const double sinHeading = std::sin(_regionHeading);
  const double cosHeading = std::cos(_regionHeading);
  _excluder->radius =
      _streamingRadius * (std::abs(sinHeading) + std::abs(cosHeading));

  // The LOD camera arrives in the anchor's frame, so it stays level with the
  // ground however far the anchor is from the origin.
  const glm::dmat4 anchorFrame = [self anchorEnuToEcef];
  const glm::dmat3 enuToEcefRotation(anchorFrame);
  _excluder->anchorUp = glm::normalize(glm::dvec3(anchorFrame[2]));
  _excluder->ecefToAnchorEnu = glm::inverse(anchorFrame);
  const glm::dvec3 position = glm::dvec3(
      anchorFrame * glm::dvec4(enuFromAnchorAxes(_viewPosition), 1.0));
  glm::dvec3 direction = enuToEcefRotation * enuFromAnchorAxes(_viewDirection);
  glm::dvec3 up = enuToEcefRotation * enuFromAnchorAxes(_viewUp);
  // cesium-native throws unless direction and up are perpendicular unit
  // vectors ("normal must be normalized"): normalise, and remove any part of
  // up along direction. A degenerate camera skips the view update.
  const double directionLength = glm::length(direction);
  if (!(directionLength > 1e-9) || !std::isfinite(directionLength) ||
      !std::isfinite(position.x + position.y + position.z)) {
    return [self repeatLastFrame];
  }
  direction /= directionLength;
  up -= direction * glm::dot(up, direction);
  const double upLength = glm::length(up);
  if (!(upLength > 1e-9) || !std::isfinite(upLength)) {
    return [self repeatLastFrame];
  }
  up /= upLength;
  const double verticalFieldOfView = std::clamp(_viewFieldOfView, 0.01, M_PI - 0.01);
  const double aspect = std::clamp(_viewAspect, 0.01, 100.0);
  const double horizontalFieldOfView =
      2.0 * std::atan(std::tan(verticalFieldOfView / 2.0) * aspect);

  const ViewUpdateResult* pResult = nullptr;
  std::optional<ViewState> selectedView;
  try {
    ViewState view(
        position,
        direction,
        up,
        glm::dvec2(2048.0 * aspect, 2048.0),
        horizontalFieldOfView,
        verticalFieldOfView);
    pResult = &_tileset->updateViewGroup(
        _tileset->getDefaultViewGroup(),
        {view},
        deltaTime);
    selectedView = view;
    _tileset->loadTiles();
  } catch (const std::exception& error) {
    // Don't take the app down over one bad view: log it, keep loads moving
    // and show the last good frame.
    NSLog(@"[cesium] update failed: %s", error.what());
    return [self repeatLastFrame];
  }
  const ViewUpdateResult& result = *pResult;
  _asyncSystem->dispatchMainThreadTasks();

  // Each drawn tile's placement in the anchor's level frame (RealityKit axes,
  // the anchor at the origin): computed in double from the tile's
  // full-precision centre, so only small, nearby numbers reach Float.
  const glm::dmat4 ecefToAnchorRealityKit =
      kEnuToRealityKit * glm::inverse(anchorFrame);
  NSMutableArray<CNTileMesh*>* tiles =
      [NSMutableArray arrayWithCapacity:result.tilesToRenderThisFrame.size()];
  NSMutableData* transforms = [NSMutableData
      dataWithCapacity:result.tilesToRenderThisFrame.size() *
                       sizeof(simd_float4x4)];
  NSMutableData* bounds = _reportsTileBounds ? [NSMutableData data] : nil;
  auto toFloat = [](const glm::dvec3& v) {
    return simd_make_float3(float(v.x), float(v.y), float(v.z));
  };
  for (const Tile::ConstPointer& pTile : result.tilesToRenderThisFrame) {
    const TileRenderContent* pRender = pTile->getContent().getRenderContent();
    if (!pRender || !pRender->getRenderResources()) {
      continue;
    }
    CNTileMesh* mesh = (__bridge CNTileMesh*)pRender->getRenderResources();
    const glm::dmat4 m =
        glm::translate(ecefToAnchorRealityKit, mesh.center);
    simd_float4x4 placement;
    for (int column = 0; column < 4; ++column) {
      placement.columns[column] = simd_make_float4(
          float(m[column][0]),
          float(m[column][1]),
          float(m[column][2]),
          float(m[column][3]));
    }
    [tiles addObject:mesh];
    [transforms appendBytes:&placement length:sizeof(placement)];
    if (bounds) {
      const BoundingVolume& volume = pTile->getBoundingVolume();
      const CesiumGeometry::OrientedBoundingBox box =
          getOrientedBoundingBoxFromBoundingVolume(volume);
      const glm::dmat3& halfAxes = box.getHalfAxes();
      // In the tile's own frame, like its vertices.
      CNTileBounds entry;
      entry.centre = toFloat(box.getCenter() - mesh.center);
      entry.halfAxisA = toFloat(halfAxes[0]);
      entry.halfAxisB = toFloat(halfAxes[1]);
      entry.halfAxisC = toFloat(halfAxes[2]);
      entry.inView = selectedView && selectedView->isBoundingVolumeVisible(volume);
      [bounds appendBytes:&entry length:sizeof(entry)];
    }
  }

  NSMutableArray<NSNumber*>* freed = [NSMutableArray array];
  for (uint64_t identifier : _resources->takeFreed()) {
    [freed addObject:@(identifier)];
  }

  NSMutableArray<CNCredit*>* credits = [NSMutableArray array];
  const CesiumUtility::CreditsSnapshot& snapshot = _creditSystem->getSnapshot();
  for (const CesiumUtility::Credit& credit : snapshot.currentCredits) {
    const std::string& html = _creditSystem->getHtml(credit);
    NSString* text = stripHTML(html);
    NSString* image = firstImageSource(html);
    if (text.length > 0 || image) {
      [credits addObject:[[CNCredit alloc] initWithText:text imageURL:image]];
    }
  }

  CNFrame* frame = [[CNFrame alloc] init];
  frame.tilesToRender = tiles;
  frame.tileTransforms = transforms;
  frame.tileBounds = bounds;
  frame.freedTileIDs = freed;
  frame.credits = credits;
  frame.loadProgress = _tileset->computeLoadProgress();
  _lastFrame = frame;
  return frame;
}

- (void)sampleGroundHeightAroundLatitude:(double)latitude
                               longitude:(double)longitude
                                  radius:(double)radius
                              completion:(void (^)(double height))completion {
  // A 3×3 grid spanning most of the visible square. A single sample at the
  // centre lands on whatever is there (a hilltop, a roof) and sinks the rest
  // of the region below the base plane; the lowest hit keeps it all above.
  const double reach = 0.8 * radius;
  const glm::dmat4 centreFrame =
      CesiumGeospatial::GlobeTransforms::eastNorthUpToFixedFrame(
          Ellipsoid::WGS84.cartographicToCartesian(
              Cartographic::fromDegrees(longitude, latitude, 0.0)));
  std::vector<Cartographic> positions;
  for (int row = -1; row <= 1; ++row) {
    for (int column = -1; column <= 1; ++column) {
      const glm::dvec3 ecef = glm::dvec3(
          centreFrame * glm::dvec4(column * reach, row * reach, 0.0, 1.0));
      if (std::optional<Cartographic> cartographic =
              Ellipsoid::WGS84.cartesianToCartographic(ecef)) {
        positions.push_back(*cartographic);
      }
    }
  }
  if (positions.empty()) {
    completion(NAN);
    return;
  }

  // sampleHeightMostDetailed ignores the input heights and reports the
  // highest surface hit at each longitude/latitude, as height above the
  // ellipsoid, which is what anchorHeight is measured in.
  _tileset->sampleHeightMostDetailed(positions)
      .thenInMainThread([completion](SampleHeightResult&& result) {
        double lowest = INFINITY;
        for (size_t i = 0; i < result.positions.size(); ++i) {
          if (i >= result.sampleSuccess.size() || !result.sampleSuccess[i]) {
            continue;
          }
          lowest = std::min(lowest, result.positions[i].height);
        }
        completion(std::isfinite(lowest) ? lowest : NAN);
      })
      .catchInMainThread([completion](std::exception&&) { completion(NAN); });
}

@end
