#import "CNTileStreamer.h"

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

#include <algorithm>
#include <atomic>
#include <cmath>
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
                          indices:(NSData *)indices
                             rgba:(nullable NSData *)rgba
                            width:(NSInteger)width
                           height:(NSInteger)height;
@end

@implementation CNPrimitive
- (instancetype)initWithPositions:(NSData *)positions
                        texcoords:(NSData *)texcoords
                          indices:(NSData *)indices
                             rgba:(NSData *)rgba
                            width:(NSInteger)width
                           height:(NSInteger)height {
  if ((self = [super init])) {
    _positions = positions;
    _texcoords = texcoords;
    _indices = indices;
    _rgba = rgba;
    _textureWidth = width;
    _textureHeight = height;
  }
  return self;
}
@end

@interface CNTileMesh ()
- (instancetype)initWithIdentifier:(uint64_t)identifier
                        primitives:(NSArray<CNPrimitive *> *)primitives;
@end

@implementation CNTileMesh
- (instancetype)initWithIdentifier:(uint64_t)identifier
                        primitives:(NSArray<CNPrimitive *> *)primitives {
  if ((self = [super init])) {
    _identifier = identifier;
    _primitives = primitives;
  }
  return self;
}
- (void)discardCPUData {
  _primitives = nil;
}
@end

@interface CNFrame ()
@property (nonatomic, readwrite) NSArray<CNTileMesh *> *tilesToRender;
@property (nonatomic, readwrite) NSArray<NSNumber *> *freedTileIDs;
@property (nonatomic, readwrite) NSArray<NSString *> *credits;
@property (nonatomic, readwrite) float loadProgress;
@end

@implementation CNFrame
@end

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

/// IAssetAccessor over NSURLSession. cesium-native is built with curl
/// disabled, so this is its only network path. NSURLCache gives us a basic
/// HTTP cache for free (within Google's caching terms).
class URLSessionAssetAccessor final : public IAssetAccessor {
public:
  URLSessionAssetAccessor() {
    NSURLSessionConfiguration* config =
        [NSURLSessionConfiguration defaultSessionConfiguration];
    config.HTTPMaximumConnectionsPerHost = 12;
    _session = [NSURLSession sessionWithConfiguration:config];
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

    NSURLSessionDataTask* task = [_session
        dataTaskWithRequest:req
          completionHandler:^(
              NSData* data, NSURLResponse* response, NSError* error) {
            if (error) {
              promise.reject(
                  std::runtime_error(error.localizedDescription.UTF8String));
              return;
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
CNTileMesh* _Nullable buildTileMesh(
    const CesiumGltf::Model& model,
    const glm::dmat4& tileTransform,
    const glm::dmat4& ecefToLocal,
    uint64_t identifier) {
  using namespace CesiumGltf;
  using CesiumGltfContent::GltfUtilities;

  glm::dmat4 rootTransform = GltfUtilities::applyRtcCenter(model, tileTransform);
  rootTransform = GltfUtilities::applyGltfUpAxisTransform(model, rootTransform);
  const glm::dmat4 toLocal = kEnuToRealityKit * ecefToLocal * rootTransform;

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

        const glm::dmat4 transform = toLocal * nodeTransform;
        const size_t vertexCount = size_t(positions.size());
        NSMutableData* positionData =
            [NSMutableData dataWithLength:vertexCount * 4 * sizeof(float)];
        float* p = static_cast<float*>(positionData.mutableBytes);
        for (size_t i = 0; i < vertexCount; ++i) {
          const glm::dvec4 v =
              transform * glm::dvec4(glm::dvec3(positions[int64_t(i)]), 1.0);
          p[i * 4 + 0] = float(v.x);
          p[i * 4 + 1] = float(v.y);
          p[i * 4 + 2] = float(v.z);
          p[i * 4 + 3] = 0.0f;
        }

        // Base colour texture (photogrammetry is unlit; that's all there is).
        int64_t texCoordSet = 0;
        const CesiumImage::ImageAsset* pImage = nullptr;
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

        NSData* indexData =
            [NSData dataWithBytes:indices.data()
                           length:indices.size() * sizeof(uint32_t)];
        NSInteger width = rgba && pImage ? pImage->width : 0;
        NSInteger height = rgba && pImage ? pImage->height : 0;
        [primitives addObject:[[CNPrimitive alloc] initWithPositions:positionData
                                                           texcoords:texcoordData
                                                             indices:indexData
                                                                rgba:rgba
                                                               width:width
                                                              height:height]];
      });

  if (primitives.count == 0) {
    return nil;
  }
  return [[CNTileMesh alloc] initWithIdentifier:identifier
                                     primitives:primitives];
}

/// Holds each tile's CNTileMesh as a retained void* inside cesium-native and
/// reports frees back to Swift so it can drop the matching entity.
class RealityKitPrepareRendererResources final
    : public IPrepareRendererResources {
public:
  explicit RealityKitPrepareRendererResources(const glm::dmat4& ecefToLocal)
      : _ecefToLocal(ecefToLocal) {}

  Future<TileLoadResultAndRenderResources> prepareInLoadThread(
      const AsyncSystem& asyncSystem,
      TileLoadResult&& tileLoadResult,
      const glm::dmat4& transform,
      const std::any&) override {
    void* pResources = nullptr;
    if (const CesiumGltf::Model* pModel =
            std::get_if<CesiumGltf::Model>(&tileLoadResult.contentKind)) {
      CNTileMesh* mesh =
          buildTileMesh(*pModel, transform, _ecefToLocal, _nextID++);
      if (mesh) {
        pResources = (__bridge_retained void*)mesh;
      }
    }
    return asyncSystem.createResolvedFuture(TileLoadResultAndRenderResources{
        std::move(tileLoadResult),
        pResources});
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

  std::vector<uint64_t> takeFreed() {
    std::lock_guard<std::mutex> lock(_freedMutex);
    return std::exchange(_freed, {});
  }

private:
  glm::dmat4 _ecefToLocal;
  std::atomic<uint64_t> _nextID{1};
  std::mutex _freedMutex;
  std::vector<uint64_t> _freed;
};

/// Skips tiles whose bounding sphere lies entirely outside the square focus
/// region, so the volume only streams what it can show. The square is
/// measured in the focus's own east-north-up frame, so it stays true however
/// far the focus is from where the tileset was opened.
class FocusRegionExcluder final : public ITileExcluder {
public:
  /// ECEF → focus east-north-up; updated every frame.
  glm::dmat4 ecefToFocusEnu{1.0};
  double radius = 500.0;
  /// Unit up at the focus (ECEF). At hemisphere-scale zoom the tangent-plane
  /// square also covers the far side of the Earth; anything entirely on the
  /// hemisphere opposite the focus is skipped.
  glm::dvec3 focusUp{0.0, 0.0, 1.0};

  bool shouldExclude(const Tile& tile) const noexcept override {
    const CesiumGeometry::BoundingSphere sphere =
        getOrientedBoundingBoxFromBoundingVolume(tile.getBoundingVolume())
            .toSphere();
    if (glm::dot(sphere.getCenter(), focusUp) + sphere.getRadius() < 0.0) {
      return true;
    }
    const glm::dvec3 center =
        glm::dvec3(ecefToFocusEnu * glm::dvec4(sphere.getCenter(), 1.0));
    const double r = sphere.getRadius();
    return std::abs(center.x) - r > radius || std::abs(center.y) - r > radius;
  }
};

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

@implementation CNTileStreamer {
  // AsyncSystem has no default constructor; constructed in init.
  std::optional<AsyncSystem> _asyncSystem;
  std::shared_ptr<CesiumUtility::CreditSystem> _creditSystem;
  std::shared_ptr<RealityKitPrepareRendererResources> _resources;
  std::shared_ptr<FocusRegionExcluder> _excluder;
  std::unique_ptr<Tileset> _tileset;
  glm::dmat4 _enuToEcef;
  glm::dmat4 _ecefToEnu;
}

- (instancetype)initWithTilesetURL:(NSString*)url
                    originLatitude:(double)latitude
                         longitude:(double)longitude
                            height:(double)height {
  if ((self = [super init])) {
    // Without this, b3dm/glb/i3dm/pnts content is not recognised and the
    // loader falls back to parsing it as an external tileset.json.
    static dispatch_once_t registerOnce;
    dispatch_once(&registerOnce, ^{
      Cesium3DTilesContent::registerAllTileContentTypes();
    });

    _asyncSystem.emplace(std::make_shared<GCDTaskProcessor>());

    const glm::dvec3 origin = Ellipsoid::WGS84.cartographicToCartesian(
        Cartographic::fromDegrees(longitude, latitude, height));
    _enuToEcef =
        CesiumGeospatial::GlobeTransforms::eastNorthUpToFixedFrame(origin);
    _ecefToEnu = glm::inverse(_enuToEcef);

    _creditSystem = std::make_shared<CesiumUtility::CreditSystem>();
    _resources =
        std::make_shared<RealityKitPrepareRendererResources>(_ecefToEnu);
    _excluder = std::make_shared<FocusRegionExcluder>();

    TilesetExternals externals{
        .pAssetAccessor = std::make_shared<URLSessionAssetAccessor>(),
        .pPrepareRendererResources = _resources,
        .asyncSystem = *_asyncSystem,
        .pCreditSystem = _creditSystem,
    };

    TilesetOptions options;
    options.maximumScreenSpaceError = 16.0;
    options.maximumCachedBytes = 512ull * 1024 * 1024;
    options.enableFogCulling = false;
    options.forbidHoles = false;
    options.showCreditsOnScreen = true;
    options.excluders = {_excluder};
    options.loadErrorCallback = [](const TilesetLoadFailureDetails& details) {
      NSLog(@"[cesium] tileset load failed (HTTP %d): %s",
            int(details.statusCode),
            details.message.c_str());
    };

    _tileset = std::make_unique<Tileset>(externals, url.UTF8String, options);

    _focusRadius = 500.0;
    _viewerDistance = 1200.0;
  }
  return self;
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

/// The focus's ground point: focusHeight above the ellipsoid at the focus's
/// latitude/longitude.
- (glm::dvec3)focusECEF {
  return Ellipsoid::WGS84.cartographicToCartesian(Cartographic::fromDegrees(
      _focusLongitude,
      _focusLatitude,
      _focusHeight));
}

/// Local east-north-up at the focus, as a transform to ECEF.
- (glm::dmat4)focusEnuToEcef {
  return CesiumGeospatial::GlobeTransforms::eastNorthUpToFixedFrame(
      [self focusECEF]);
}

- (simd_float4x4)displayTransform {
  // Baked tile coordinates (RealityKit axes, origin frame) → ECEF → focus ENU
  // → RealityKit axes. Rotation and translation only; computed in double and
  // narrowed at the end.
  const glm::dmat4 m = kEnuToRealityKit * glm::inverse([self focusEnuToEcef]) *
                       _enuToEcef * glm::transpose(kEnuToRealityKit);
  simd_float4x4 result;
  for (int column = 0; column < 4; ++column) {
    result.columns[column] = simd_make_float4(
        float(m[column][0]),
        float(m[column][1]),
        float(m[column][2]),
        float(m[column][3]));
  }
  return result;
}

- (CNFrame*)updateWithDeltaTime:(float)deltaTime {
  // The excluder's square is axis-aligned in east/north; when the view is
  // turned, grow it to the square that encloses the rotated visible one.
  const double sinHeading = std::sin(_viewHeading);
  const double cosHeading = std::cos(_viewHeading);
  const double streamingRadius =
      _streamingRadius > 0.0 ? _streamingRadius : _focusRadius;
  _excluder->radius =
      streamingRadius * (std::abs(sinHeading) + std::abs(cosHeading));

  // No head pose in the Shared Space, so LOD comes from a synthetic camera
  // looking at the focus from the front of the volume, 45° up, facing the
  // view heading.
  const double elevation = M_PI / 4.0;
  const double horizontal = std::cos(elevation) * _viewerDistance;
  const glm::dvec3 offsetEnu(
      -sinHeading * horizontal,
      -cosHeading * horizontal,
      std::sin(elevation) * _viewerDistance);
  // Built in the focus's own east-north-up frame, so the camera stays level
  // with the ground however far the focus is from the origin.
  const glm::dmat4 focusFrame = [self focusEnuToEcef];
  _excluder->focusUp = glm::normalize(glm::dvec3(focusFrame[2]));
  _excluder->ecefToFocusEnu = glm::inverse(focusFrame);
  const glm::dvec3 target = glm::dvec3(focusFrame[3]);
  const glm::dvec3 position =
      glm::dvec3(focusFrame * glm::dvec4(offsetEnu, 1.0));
  const glm::dvec3 direction = glm::normalize(target - position);
  const glm::dvec3 upEcef = glm::normalize(glm::dvec3(focusFrame[2]));
  const glm::dvec3 up =
      glm::normalize(upEcef - glm::dot(upEcef, direction) * direction);
  const double fov = glm::radians(60.0);
  ViewState view(
      position,
      direction,
      up,
      glm::dvec2(2048.0, 2048.0),
      fov,
      fov);

  const ViewUpdateResult& result = _tileset->updateViewGroup(
      _tileset->getDefaultViewGroup(),
      {view},
      deltaTime);
  _tileset->loadTiles();
  _asyncSystem->dispatchMainThreadTasks();

  NSMutableArray<CNTileMesh*>* tiles =
      [NSMutableArray arrayWithCapacity:result.tilesToRenderThisFrame.size()];
  for (const Tile::ConstPointer& pTile : result.tilesToRenderThisFrame) {
    const TileRenderContent* pRender = pTile->getContent().getRenderContent();
    if (pRender && pRender->getRenderResources()) {
      [tiles addObject:(__bridge CNTileMesh*)pRender->getRenderResources()];
    }
  }

  NSMutableArray<NSNumber*>* freed = [NSMutableArray array];
  for (uint64_t identifier : _resources->takeFreed()) {
    [freed addObject:@(identifier)];
  }

  NSMutableArray<NSString*>* credits = [NSMutableArray array];
  const CesiumUtility::CreditsSnapshot& snapshot = _creditSystem->getSnapshot();
  for (const CesiumUtility::Credit& credit : snapshot.currentCredits) {
    NSString* text = stripHTML(_creditSystem->getHtml(credit));
    if (text.length > 0) {
      [credits addObject:text];
    }
  }

  CNFrame* frame = [[CNFrame alloc] init];
  frame.tilesToRender = tiles;
  frame.freedTileIDs = freed;
  frame.credits = credits;
  frame.loadProgress = _tileset->computeLoadProgress();
  return frame;
}

- (void)sampleGroundHeightInFocusRegion:(void (^)(double height))completion {
  // A 3×3 grid spanning most of the visible square. A single sample at the
  // focus lands on whatever is there (a hilltop, a roof) and sinks the rest of
  // the region below the volume floor; the lowest hit keeps it all above.
  const double reach = 0.8 * _focusRadius;
  const glm::dmat4 focusFrame = [self focusEnuToEcef];
  std::vector<Cartographic> positions;
  for (int row = -1; row <= 1; ++row) {
    for (int column = -1; column <= 1; ++column) {
      const glm::dvec3 ecef = glm::dvec3(
          focusFrame * glm::dvec4(column * reach, row * reach, 0.0, 1.0));
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
  // ellipsoid, which is what focusHeight is measured in.
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
