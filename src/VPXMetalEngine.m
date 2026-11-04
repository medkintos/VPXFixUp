/*
 * VPXMetalEngine.m
 * VPXMetalDecoder - Metal Compute Engine Implementation
 *
 * Target: Intel UHD 630 / UHD 620 (Gen 9.5 Coffee Lake/Comet Lake)
 * Copyright (c) 2024-2026 Hackintosh Open Source Community.
 */

#import "VPXMetalEngine.h"

// Embedded Metal Shading Language source for runtime compilation
static NSString *const kVPXMetalShaderSource = @""
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"constant int cospi_8_64  = 15137;\n"
"constant int cospi_16_64 = 11585;\n"
"constant int cospi_24_64 = 6270;\n"
"\n"
"constant short vpx_subpel_filters_8tap[8][8] = {\n"
"    { 0,   0,   0, 128,   0,   0,   0,  0 },\n"
"    { 0,   1,  -5, 126,   8,  -3,   1,  0 },\n"
"    {-1,   3, -10, 122,  18,  -6,   2,  0 },\n"
"    {-1,   4, -13, 114,  31,  -9,   3,  0 },\n"
"    {-1,   4, -14, 103,  45, -11,   4, -1 },\n"
"    {-1,   4, -13,  90,  60, -15,   4, -1 },\n"
"    {-1,   3, -10,  76,  76, -10,   3, -1 },\n"
"    {-1,   4, -15,  60,  90, -13,   4, -1 }\n"
"};\n"
"\n"
"inline void idct4_1d(thread const int *in, thread int *out) {\n"
"    int a1 = in[0] + in[2];\n"
"    int b1 = in[0] - in[2];\n"
"    int t1 = (a1 * cospi_16_64) >> 14;\n"
"    int t2 = (b1 * cospi_16_64) >> 14;\n"
"    int t3 = (in[1] * cospi_24_64 - in[3] * cospi_8_64) >> 14;\n"
"    int t4 = (in[1] * cospi_8_64 + in[3] * cospi_24_64) >> 14;\n"
"    out[0] = t1 + t4;\n"
"    out[1] = t2 + t3;\n"
"    out[2] = t2 - t3;\n"
"    out[3] = t1 - t4;\n"
"}\n"
"\n"
"kernel void vpx_idct4x4_kernel(\n"
"    device const short *coeffs        [[buffer(0)]],\n"
"    device short       *residuals     [[buffer(1)]],\n"
"    device const short *prediction    [[buffer(2)]],\n"
"    device uchar       *destination   [[buffer(3)]],\n"
"    constant uint      &stride        [[buffer(4)]],\n"
"    constant uint      &block_count   [[buffer(5)]],\n"
"    uint               id             [[thread_position_in_grid]])\n"
"{\n"
"    if (id >= block_count) return;\n"
"    uint block_offset = id * 16;\n"
"    int temp[16];\n"
"    int intermediate[16];\n"
"    for (int col = 0; col < 4; col++) {\n"
"        int in_col[4] = {\n"
"            coeffs[block_offset + col + 0],\n"
"            coeffs[block_offset + col + 4],\n"
"            coeffs[block_offset + col + 8],\n"
"            coeffs[block_offset + col + 12]\n"
"        };\n"
"        int out_col[4];\n"
"        idct4_1d(in_col, out_col);\n"
"        for (int row = 0; row < 4; row++) {\n"
"            intermediate[row * 4 + col] = (out_col[row] + 1) >> 2;\n"
"        }\n"
"    }\n"
"    for (int row = 0; row < 4; row++) {\n"
"        int in_row[4] = {\n"
"            intermediate[row * 4 + 0],\n"
"            intermediate[row * 4 + 1],\n"
"            intermediate[row * 4 + 2],\n"
"            intermediate[row * 4 + 3]\n"
"        };\n"
"        int out_row[4];\n"
"        idct4_1d(in_row, out_row);\n"
"        for (int col = 0; col < 4; col++) {\n"
"            temp[row * 4 + col] = (out_row[col] + 8) >> 4;\n"
"        }\n"
"    }\n"
"    uint block_row = (id / (stride / 4)) * 4;\n"
"    uint block_col = (id % (stride / 4)) * 4;\n"
"    for (int r = 0; r < 4; r++) {\n"
"        for (int c = 0; c < 4; c++) {\n"
"            int res = temp[r * 4 + c];\n"
"            residuals[block_offset + r * 4 + c] = (short)res;\n"
"            uint dest_idx = (block_row + r) * stride + (block_col + c);\n"
"            int pred = (int)prediction[block_offset + r * 4 + c];\n"
"            destination[dest_idx] = clamp(pred + res, 0, 255);\n"
"        }\n"
"    }\n"
"}\n"
"\n"
"kernel void vpx_motion_compensation_8tap_kernel(\n"
"    device const uchar *ref_surface   [[buffer(0)]],\n"
"    device uchar       *pred_surface  [[buffer(1)]],\n"
"    constant uint      &width         [[buffer(2)]],\n"
"    constant uint      &height        [[buffer(3)]],\n"
"    constant uint      &stride        [[buffer(4)]],\n"
"    constant int       &mv_row        [[buffer(5)]],\n"
"    constant int       &mv_col        [[buffer(6)]],\n"
"    uint2              gid            [[thread_position_in_grid]])\n"
"{\n"
"    if (gid.x >= width || gid.y >= height) return;\n"
"    int subpel_x = mv_col & 7;\n"
"    int subpel_y = mv_row & 7;\n"
"    int int_col  = (int)gid.x + (mv_col >> 3);\n"
"    int int_row  = (int)gid.y + (mv_row >> 3);\n"
"    if (subpel_x == 0 && subpel_y == 0) {\n"
"        int ref_x = clamp(int_col, 0, (int)width - 1);\n"
"        int ref_y = clamp(int_row, 0, (int)height - 1);\n"
"        pred_surface[gid.y * stride + gid.x] = ref_surface[ref_y * stride + ref_x];\n"
"        return;\n"
"    }\n"
"    constant short *filter_x = vpx_subpel_filters_8tap[subpel_x];\n"
"    constant short *filter_y = vpx_subpel_filters_8tap[subpel_y];\n"
"    int sum = 0;\n"
"    for (int tap_y = -3; tap_y <= 4; tap_y++) {\n"
"        int line_y = clamp(int_row + tap_y, 0, (int)height - 1);\n"
"        int line_sum = 0;\n"
"        for (int tap_x = -3; tap_x <= 4; tap_x++) {\n"
"            int line_x = clamp(int_col + tap_x, 0, (int)width - 1);\n"
"            uchar val = ref_surface[line_y * stride + line_x];\n"
"            line_sum += (int)val * filter_x[tap_x + 3];\n"
"        }\n"
"        int clamped_line = (line_sum + 64) >> 7;\n"
"        sum += clamped_line * filter_y[tap_y + 3];\n"
"    }\n"
"    int result = (sum + 64) >> 7;\n"
"    pred_surface[gid.y * stride + gid.x] = (uchar)clamp(result, 0, 255);\n"
"}\n"
"\n"
"kernel void vpx_loop_filter_edge_kernel(\n"
"    device uchar  *surface      [[buffer(0)]],\n"
"    constant uint &stride       [[buffer(1)]],\n"
"    constant uint &limit        [[buffer(2)]],\n"
"    constant uint &blimit       [[buffer(3)]],\n"
"    constant uint &thresh       [[buffer(4)]],\n"
"    constant uint &is_vertical  [[buffer(5)]],\n"
"    uint2         gid           [[thread_position_in_grid]])\n"
"{\n"
"    uint x = gid.x * 8;\n"
"    uint y = gid.y;\n"
"    if (is_vertical) {\n"
"        if (x < 4) return;\n"
"        device uchar *p = surface + y * stride + x;\n"
"        int p1 = p[-2], p0 = p[-1], q0 = p[0], q1 = p[1];\n"
"        bool mask = (abs(p0 - q0) * 2 + abs(p1 - q1) / 2) <= (int)blimit;\n"
"        if (mask) {\n"
"            int filter_val = clamp((q0 - p0) * 3 + (p1 - q1), -128, 127);\n"
"            p[-1] = clamp(p0 + ((filter_val + 4) >> 3), 0, 255);\n"
"            p[0]  = clamp(q0 - ((filter_val + 3) >> 3), 0, 255);\n"
"        }\n"
"    } else {\n"
"        if (y < 4) return;\n"
"        device uchar *p = surface + y * stride + gid.x;\n"
"        int p1 = p[-(int)stride * 2], p0 = p[-(int)stride], q0 = p[0], q1 = p[stride];\n"
"        bool mask = (abs(p0 - q0) * 2 + abs(p1 - q1) / 2) <= (int)blimit;\n"
"        if (mask) {\n"
"            int filter_val = clamp((q0 - p0) * 3 + (p1 - q1), -128, 127);\n"
"            p[-(int)stride] = clamp(p0 + ((filter_val + 4) >> 3), 0, 255);\n"
"            p[0]            = clamp(q0 - ((filter_val + 3) >> 3), 0, 255);\n"
"        }\n"
"    }\n"
"}\n"
"\n"
"kernel void vpx_yuv420_to_nv12_kernel(\n"
"    device const uchar *y_plane       [[buffer(0)]],\n"
"    device const uchar *u_plane       [[buffer(1)]],\n"
"    device const uchar *v_plane       [[buffer(2)]],\n"
"    device uchar       *nv12_y_plane  [[buffer(3)]],\n"
"    device uchar       *nv12_uv_plane [[buffer(4)]],\n"
"    constant uint      &width         [[buffer(5)]],\n"
"    constant uint      &height        [[buffer(6)]],\n"
"    constant uint      &y_stride      [[buffer(7)]],\n"
"    constant uint      &uv_stride     [[buffer(8)]],\n"
"    constant uint      &dst_y_stride  [[buffer(9)]],\n"
"    constant uint      &dst_uv_stride [[buffer(10)]],\n"
"    uint2              gid            [[thread_position_in_grid]])\n"
"{\n"
"    if (gid.x >= width || gid.y >= height) return;\n"
"    nv12_y_plane[gid.y * dst_y_stride + gid.x] = y_plane[gid.y * y_stride + gid.x];\n"
"    if ((gid.x & 1) == 0 && (gid.y & 1) == 0) {\n"
"        uint uv_x = gid.x >> 1;\n"
"        uint uv_y = gid.y >> 1;\n"
"        uchar u = u_plane[uv_y * uv_stride + uv_x];\n"
"        uchar v = v_plane[uv_y * uv_stride + uv_x];\n"
"        uint dst_offset = uv_y * dst_uv_stride + (uv_x << 1);\n"
"        nv12_uv_plane[dst_offset + 0] = u;\n"
"        nv12_uv_plane[dst_offset + 1] = v;\n"
"    }\n"
"}\n";

@interface VPXMetalEngine () {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    CVMetalTextureCacheRef _textureCache;
    id<MTLLibrary> _library;

    id<MTLComputePipelineState> _idct4x4Pipeline;
    id<MTLComputePipelineState> _motionCompensationPipeline;
    id<MTLComputePipelineState> _loopFilterPipeline;
    id<MTLComputePipelineState> _yuv420ToNv12Pipeline;
}
@end

@implementation VPXMetalEngine

@synthesize device = _device;
@synthesize commandQueue = _commandQueue;
@synthesize textureCache = _textureCache;

+ (instancetype)sharedEngine {
    static VPXMetalEngine *sShared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sShared = [[VPXMetalEngine alloc] init];
    });
    return sShared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self selectBestDevice];
        if (!_device) {
            VPX_LOG_ERR("No compatible Metal device found.");
            return nil;
        }

        _commandQueue = [_device newCommandQueue];
        CVReturn cvRet = CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, _device, NULL, &_textureCache);
        if (cvRet != kCVReturnSuccess) {
            VPX_LOG_ERR("Failed to create CVMetalTextureCache: %d", cvRet);
        }

        NSError *error = nil;
        if (![self initializePipelinesWithError:&error]) {
            VPX_LOG_ERR("Failed to initialize Metal pipelines: %s", error.localizedDescription.UTF8String);
        }
    }
    return self;
}

- (void)dealloc {
    if (_textureCache) {
        CFRelease(_textureCache);
        _textureCache = NULL;
    }
}

- (void)selectBestDevice {
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    id<MTLDevice> chosen = nil;

    // Search explicitly for Intel UHD / Coffee Lake / Comet Lake iGPU
    for (id<MTLDevice> dev in devices) {
        NSString *name = dev.name;
        if ([name rangeOfString:@"Intel" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [name rangeOfString:@"UHD" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [name rangeOfString:@"Iris" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            chosen = dev;
            VPX_LOG_INFO("Discovered Intel GPU: %s", name.UTF8String);
            break;
        }
    }

    if (!chosen) {
        chosen = MTLCreateSystemDefaultDevice();
        if (chosen) {
            VPX_LOG_INFO("Using default Metal device: %s", chosen.name.UTF8String);
        }
    }

    _device = chosen;
}

- (BOOL)isIntelGPU {
    if (!_device) return NO;
    NSString *name = _device.name;
    return [name rangeOfString:@"Intel" options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [name rangeOfString:@"UHD" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

- (NSString *)gpuName {
    return _device ? _device.name : @"Unknown GPU";
}

- (BOOL)initializePipelinesWithError:(NSError **)error {
    if (!_device) return NO;

    MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    options.fastMathEnabled = YES;
#pragma clang diagnostic pop

    _library = [_device newLibraryWithSource:kVPXMetalShaderSource options:options error:error];
    if (!_library) {
        VPX_LOG_ERR("Failed to compile embedded Metal shaders.");
        return NO;
    }

    id<MTLFunction> idctFunc = [_library newFunctionWithName:@"vpx_idct4x4_kernel"];
    _idct4x4Pipeline = [_device newComputePipelineStateWithFunction:idctFunc error:error];

    id<MTLFunction> mcFunc = [_library newFunctionWithName:@"vpx_motion_compensation_8tap_kernel"];
    _motionCompensationPipeline = [_device newComputePipelineStateWithFunction:mcFunc error:error];

    id<MTLFunction> lfFunc = [_library newFunctionWithName:@"vpx_loop_filter_edge_kernel"];
    _loopFilterPipeline = [_device newComputePipelineStateWithFunction:lfFunc error:error];

    id<MTLFunction> nv12Func = [_library newFunctionWithName:@"vpx_yuv420_to_nv12_kernel"];
    _yuv420ToNv12Pipeline = [_device newComputePipelineStateWithFunction:nv12Func error:error];

    VPX_LOG_INFO("All Metal compute pipelines successfully created for %s.", self.gpuName.UTF8String);
    return YES;
}

- (id<MTLBuffer>)allocateBufferWithLength:(NSUInteger)length {
    if (!_device || length == 0) return nil;
    return [_device newBufferWithLength:length options:MTLResourceStorageModeShared];
}

- (BOOL)dispatchInverseTransform4x4WithCoeffs:(id<MTLBuffer>)coeffs
                                    residuals:(id<MTLBuffer>)residuals
                                   prediction:(id<MTLBuffer>)prediction
                                  destination:(id<MTLBuffer>)destination
                                       stride:(uint32_t)stride
                                   blockCount:(uint32_t)blockCount
{
    if (!_idct4x4Pipeline || blockCount == 0) return NO;

    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [cmdBuf computeCommandEncoder];
    [encoder setComputePipelineState:_idct4x4Pipeline];

    [encoder setBuffer:coeffs offset:0 atIndex:0];
    [encoder setBuffer:residuals offset:0 atIndex:1];
    [encoder setBuffer:prediction offset:0 atIndex:2];
    [encoder setBuffer:destination offset:0 atIndex:3];
    [encoder setBytes:&stride length:sizeof(uint32_t) atIndex:4];
    [encoder setBytes:&blockCount length:sizeof(uint32_t) atIndex:5];

    NSUInteger threadGroupSize = MIN(blockCount, _idct4x4Pipeline.maxTotalThreadsPerThreadgroup);
    if (threadGroupSize == 0) threadGroupSize = 1;
    MTLSize threadsPerGrid = MTLSizeMake(blockCount, 1, 1);
    MTLSize threadsPerGroup = MTLSizeMake(threadGroupSize, 1, 1);

    [encoder dispatchThreads:threadsPerGrid threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];
    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];

    return YES;
}

- (BOOL)dispatchMotionCompensationWithRef:(id<MTLBuffer>)refSurface
                              predSurface:(id<MTLBuffer>)predSurface
                                    width:(uint32_t)width
                                   height:(uint32_t)height
                                   stride:(uint32_t)stride
                                    mvRow:(int32_t)mvRow
                                    mvCol:(int32_t)mvCol
{
    if (!_motionCompensationPipeline) return NO;

    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [cmdBuf computeCommandEncoder];
    [encoder setComputePipelineState:_motionCompensationPipeline];

    [encoder setBuffer:refSurface offset:0 atIndex:0];
    [encoder setBuffer:predSurface offset:0 atIndex:1];
    [encoder setBytes:&width length:sizeof(uint32_t) atIndex:2];
    [encoder setBytes:&height length:sizeof(uint32_t) atIndex:3];
    [encoder setBytes:&stride length:sizeof(uint32_t) atIndex:4];
    [encoder setBytes:&mvRow length:sizeof(int32_t) atIndex:5];
    [encoder setBytes:&mvCol length:sizeof(int32_t) atIndex:6];

    MTLSize threadsPerGrid = MTLSizeMake(width, height, 1);
    MTLSize threadsPerGroup = MTLSizeMake(16, 16, 1);

    [encoder dispatchThreads:threadsPerGrid threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];
    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];

    return YES;
}

- (BOOL)dispatchLoopFilterOnSurface:(id<MTLBuffer>)surface
                             stride:(uint32_t)stride
                              limit:(uint32_t)limit
                             blimit:(uint32_t)blimit
                             thresh:(uint32_t)thresh
                         isVertical:(BOOL)isVertical
                              width:(uint32_t)width
                             height:(uint32_t)height
{
    if (!_loopFilterPipeline) return NO;

    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [cmdBuf computeCommandEncoder];
    [encoder setComputePipelineState:_loopFilterPipeline];

    uint32_t isVert = isVertical ? 1 : 0;
    [encoder setBuffer:surface offset:0 atIndex:0];
    [encoder setBytes:&stride length:sizeof(uint32_t) atIndex:1];
    [encoder setBytes:&limit length:sizeof(uint32_t) atIndex:2];
    [encoder setBytes:&blimit length:sizeof(uint32_t) atIndex:3];
    [encoder setBytes:&thresh length:sizeof(uint32_t) atIndex:4];
    [encoder setBytes:&isVert length:sizeof(uint32_t) atIndex:5];

    MTLSize threadsPerGrid = MTLSizeMake(width / 8, height, 1);
    MTLSize threadsPerGroup = MTLSizeMake(8, 8, 1);

    [encoder dispatchThreads:threadsPerGrid threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];
    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];

    return YES;
}

- (BOOL)convertYUV420ToNV12WithY:(id<MTLBuffer>)yPlane
                               U:(id<MTLBuffer>)uPlane
                               V:(id<MTLBuffer>)vPlane
                          dstY:(uint8_t *)dstY
                         dstUV:(uint8_t *)dstUV
                         width:(uint32_t)width
                        height:(uint32_t)height
                       yStride:(uint32_t)yStride
                      uvStride:(uint32_t)uvStride
                    dstYStride:(uint32_t)dstYStride
                   dstUVStride:(uint32_t)dstUVStride
{
    if (!_yuv420ToNv12Pipeline) return NO;

    NSUInteger yBytes = dstYStride * height;
    NSUInteger uvBytes = dstUVStride * (height / 2);

    id<MTLBuffer> outYBuffer = [_device newBufferWithBytesNoCopy:dstY
                                                          length:yBytes
                                                         options:MTLResourceStorageModeShared
                                                     deallocator:nil];
    id<MTLBuffer> outUVBuffer = [_device newBufferWithBytesNoCopy:dstUV
                                                           length:uvBytes
                                                          options:MTLResourceStorageModeShared
                                                      deallocator:nil];

    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [cmdBuf computeCommandEncoder];
    [encoder setComputePipelineState:_yuv420ToNv12Pipeline];

    [encoder setBuffer:yPlane offset:0 atIndex:0];
    [encoder setBuffer:uPlane offset:0 atIndex:1];
    [encoder setBuffer:vPlane offset:0 atIndex:2];
    [encoder setBuffer:outYBuffer offset:0 atIndex:3];
    [encoder setBuffer:outUVBuffer offset:0 atIndex:4];
    [encoder setBytes:&width length:sizeof(uint32_t) atIndex:5];
    [encoder setBytes:&height length:sizeof(uint32_t) atIndex:6];
    [encoder setBytes:&yStride length:sizeof(uint32_t) atIndex:7];
    [encoder setBytes:&uvStride length:sizeof(uint32_t) atIndex:8];
    [encoder setBytes:&dstYStride length:sizeof(uint32_t) atIndex:9];
    [encoder setBytes:&dstUVStride length:sizeof(uint32_t) atIndex:10];

    MTLSize threadsPerGrid = MTLSizeMake(width, height, 1);
    MTLSize threadsPerGroup = MTLSizeMake(16, 16, 1);

    [encoder dispatchThreads:threadsPerGrid threadsPerThreadgroup:threadsPerGroup];
    [encoder endEncoding];
    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];

    return YES;
}

- (BOOL)renderToPixelBuffer:(CVPixelBufferRef)pixelBuffer
                     fromY:(id<MTLBuffer>)yPlane
                         U:(id<MTLBuffer>)uPlane
                         V:(id<MTLBuffer>)vPlane
                     width:(uint32_t)width
                    height:(uint32_t)height
                   yStride:(uint32_t)yStride
                  uvStride:(uint32_t)uvStride
{
    if (!pixelBuffer || !yPlane || !uPlane || !vPlane) return NO;

    CVReturn lockRet = CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    if (lockRet != kCVReturnSuccess) {
        VPX_LOG_ERR("Failed to lock pixel buffer: %d", lockRet);
        return NO;
    }

    OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    BOOL success = NO;

    if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        uint8_t *dstY = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
        uint8_t *dstUV = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
        uint32_t dstYStride = (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
        uint32_t dstUVStride = (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);

        success = [self convertYUV420ToNV12WithY:yPlane
                                               U:uPlane
                                               V:vPlane
                                            dstY:dstY
                                           dstUV:dstUV
                                           width:width
                                          height:height
                                         yStride:yStride
                                        uvStride:uvStride
                                      dstYStride:dstYStride
                                     dstUVStride:dstUVStride];
    } else {
        VPX_LOG_ERR("Unsupported output pixel format: 0x%x", (unsigned int)pixelFormat);
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return success;
}

@end
