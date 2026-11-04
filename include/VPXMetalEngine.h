/*
 * VPXMetalEngine.h
 * VPXMetalDecoder - Metal Compute Engine for VP8/VP9
 *
 * Target: Metal 2/3 on Intel UHD 630 / UHD 620 (Coffee Lake / Comet Lake)
 * Copyright (c) 2024-2026 Hackintosh Open Source Community.
 */

#ifndef VPX_METAL_ENGINE_H
#define VPX_METAL_ENGINE_H

#import "VPXMetalCommon.h"

@interface VPXMetalEngine : NSObject

@property (nonatomic, strong, readonly) id<MTLDevice> device;
@property (nonatomic, strong, readonly) id<MTLCommandQueue> commandQueue;
@property (nonatomic, assign, readonly) CVMetalTextureCacheRef textureCache;
@property (nonatomic, assign, readonly) BOOL isIntelGPU;
@property (nonatomic, copy, readonly) NSString *gpuName;

+ (instancetype)sharedEngine;
- (BOOL)initializePipelinesWithError:(NSError **)error;

// Compute dispatch methods
- (BOOL)dispatchInverseTransform4x4WithCoeffs:(id<MTLBuffer>)coeffs
                                    residuals:(id<MTLBuffer>)residuals
                                   prediction:(id<MTLBuffer>)prediction
                                  destination:(id<MTLBuffer>)destination
                                       stride:(uint32_t)stride
                                   blockCount:(uint32_t)blockCount;

- (BOOL)dispatchMotionCompensationWithRef:(id<MTLBuffer>)refSurface
                              predSurface:(id<MTLBuffer>)predSurface
                                    width:(uint32_t)width
                                   height:(uint32_t)height
                                   stride:(uint32_t)stride
                                    mvRow:(int32_t)mvRow
                                    mvCol:(int32_t)mvCol;

- (BOOL)dispatchLoopFilterOnSurface:(id<MTLBuffer>)surface
                             stride:(uint32_t)stride
                              limit:(uint32_t)limit
                             blimit:(uint32_t)blimit
                             thresh:(uint32_t)thresh
                         isVertical:(BOOL)isVertical
                              width:(uint32_t)width
                             height:(uint32_t)height;

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
                   dstUVStride:(uint32_t)dstUVStride;

- (BOOL)renderToPixelBuffer:(CVPixelBufferRef)pixelBuffer
                     fromY:(id<MTLBuffer>)yPlane
                         U:(id<MTLBuffer>)uPlane
                         V:(id<MTLBuffer>)vPlane
                     width:(uint32_t)width
                    height:(uint32_t)height
                   yStride:(uint32_t)yStride
                  uvStride:(uint32_t)uvStride;

- (id<MTLBuffer>)allocateBufferWithLength:(NSUInteger)length;

@end

#endif /* VPX_METAL_ENGINE_H */
