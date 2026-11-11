import Metal

/// Shared glTF sampler mapping for RealityKit, Metal, and offscreen tools.
enum TileSampler {
    static func descriptor(for primitive: CNPrimitive) -> MTLSamplerDescriptor {
        func address(_ wrap: Int) -> MTLSamplerAddressMode {
            switch wrap {
            case 33071: .clampToEdge
            case 33648: .mirrorRepeat
            default: .repeat
            }
        }
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = address(primitive.textureWrapS)
        descriptor.tAddressMode = address(primitive.textureWrapT)
        descriptor.magFilter = primitive.textureMagFilter == 9728 ? .nearest : .linear
        switch primitive.textureMinFilter {
        case 9728: (descriptor.minFilter, descriptor.mipFilter) = (.nearest, .notMipmapped)
        case 9729: (descriptor.minFilter, descriptor.mipFilter) = (.linear, .notMipmapped)
        case 9984: (descriptor.minFilter, descriptor.mipFilter) = (.nearest, .nearest)
        case 9985: (descriptor.minFilter, descriptor.mipFilter) = (.linear, .nearest)
        case 9986: (descriptor.minFilter, descriptor.mipFilter) = (.nearest, .linear)
        default: (descriptor.minFilter, descriptor.mipFilter) = (.linear, .linear)
        }
        return descriptor
    }
}
