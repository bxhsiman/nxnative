// Render the actual output-type generator's synthetic entries (test_dmsh_output_types.py), including integer bit patterns that cannot survive a numeric float conversion.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <string.h>

static int checks, failures;
static void check(const char *name, int ok) { checks++; if (!ok) { failures++; fprintf(stderr, "FAIL: %s\n", name); } }

static NSData *render(id<MTLDevice> dev, id<MTLLibrary> lib, NSString *entry, MTLPixelFormat format, const uint32_t *words, NSUInteger n, BOOL mixed) {
    NSError *error = nil;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vs"]; d.fragmentFunction = [lib newFunctionWithName:entry];
    d.colorAttachments[0].pixelFormat = format;
    if (mixed) d.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA32Float;
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:d error:&error];
    if (!ps) @throw [NSException exceptionWithName:@"Pipeline" reason:error.localizedDescription userInfo:nil];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:n height:1 mipmapped:NO];
    td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [dev newTextureWithDescriptor:td], second = nil;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (mixed) { td.pixelFormat = MTLPixelFormatRGBA32Float; second = [dev newTextureWithDescriptor:td];
        rp.colorAttachments[1].texture = second; rp.colorAttachments[1].loadAction = MTLLoadActionClear; rp.colorAttachments[1].storeAction = MTLStoreActionStore; }
    id<MTLBuffer> buf = [dev newBufferWithBytes:words length:n * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:ps]; [enc setFragmentBuffer:buf offset:0 atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status == MTLCommandBufferStatusError) @throw [NSException exceptionWithName:@"GPU" reason:cb.error.localizedDescription userInfo:nil];
    if (mixed) {
        float values[4 * n]; [second getBytes:values bytesPerRow:n * 16 fromRegion:MTLRegionMake2D(0, 0, n, 1) mipmapLevel:0];
        int ok = 1; for (NSUInteger i = 0; i < n; i++) ok &= values[4*i] == 0.25f && values[4*i+1] == 0.5f && values[4*i+2] == 0.75f && values[4*i+3] == 1.0f;
        check("mixed target keeps computed float values", ok);
    }
    NSUInteger bytes = n * (format == MTLPixelFormatR8Uint ? 1 : 4);
    NSMutableData *data = [NSMutableData dataWithLength:bytes];
    [target getBytes:data.mutableBytes bytesPerRow:bytes fromRegion:MTLRegionMake2D(0, 0, n, 1) mipmapLevel:0];
    return data;
}

int main(int argc, const char **argv) { @autoreleasepool { @try {
    if (argc != 2) return 64;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) { fprintf(stderr, "No Metal device\n"); return 2; }
    NSData *data = [NSData dataWithContentsOfFile:@(argv[1])]; if (!data) return 2;
    dispatch_data_t bytes = dispatch_data_create(data.bytes, data.length, nil, ^{ (void)data; });
    NSError *error = nil; id<MTLLibrary> lib = [dev newLibraryWithData:bytes error:&error];
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
    const uint32_t words[] = {0, 1, 127, 255, 256, 65535, 0x3f800000, 0x80000000, 0x7fc00001, 0xffffffff};
    NSUInteger n = sizeof words / sizeof words[0]; NSData *raw = [NSData dataWithBytes:words length:sizeof words];
    check("unsigned reference R32 bits", [render(dev, lib, @"originalOut", MTLPixelFormatR32Uint, words, n, NO) isEqual:raw]);
    check("generated unsigned R32 bits", [render(dev, lib, @"main0_u", MTLPixelFormatR32Uint, words, n, NO) isEqual:raw]);
    check("generated mixed R32 bits", [render(dev, lib, @"main0_m", MTLPixelFormatR32Uint, words, n, YES) isEqual:raw]);
    NSData *reference = render(dev, lib, @"originalOut", MTLPixelFormatR8Uint, words, n, NO);
    check("generated R8 matches unsigned reference", [render(dev, lib, @"main0_u", MTLPixelFormatR8Uint, words, n, NO) isEqual:reference]);
    const uint8_t small[] = {0, 1, 127, 255};
    check("generated R8 literal values", [render(dev, lib, @"main0_u", MTLPixelFormatR8Uint, words, 4, NO) isEqual:[NSData dataWithBytes:small length:sizeof small]]);
    const uint32_t floats[] = {0, 0x3e800000, 0x3f000000, 0x3f800000}, exponents[] = {0, 13, 14, 15}; uint32_t packed[4];
    for (int i = 0; i < 4; i++) packed[i] = (exponents[i] << 6) | (exponents[i] << 17) | (exponents[i] << 27);
    check("default float entry RG11B10 values", [render(dev, lib, @"main0", MTLPixelFormatRG11B10Float, floats, 4, NO) isEqual:[NSData dataWithBytes:packed length:sizeof packed]]);
    printf("output types: %d checks, %d failures (%s)\n", checks, failures, dev.name.UTF8String);
    return failures != 0;
} @catch (NSException *e) { fprintf(stderr, "%s: %s\n", e.name.UTF8String, e.reason.UTF8String); return 2; } } }
