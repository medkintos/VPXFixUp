/*
 * VPXMetalDecoder.h
 * VPXMetalDecoder - Core Decoder Orchestrator
 *
 * Target: macOS Tahoe / Intel UHD 630 / UHD 620
 * Copyright (c) 2024-2026 Hackintosh Open Source Community.
 */

#ifndef VPX_METAL_DECODER_H
#define VPX_METAL_DECODER_H

#import "VPXMetalCommon.h"
#import "VPXMetalEngine.h"
#import "VPXBitstreamParser.h"

@interface VPXMetalDecoder : NSObject

@property (nonatomic, assign, readonly) CMVideoCodecType codecType;
@property (nonatomic, assign, readonly) uint32_t width;
@property (nonatomic, assign, readonly) uint32_t height;
@property (nonatomic, assign, readonly) BOOL isConfigured;
@property (nonatomic, strong, readonly) VPXMetalEngine *metalEngine;

- (instancetype)initWithCodecType:(CMVideoCodecType)codecType;

- (BOOL)decodeFrameWithBytes:(const uint8_t *)data
                      length:(size_t)length
                 pixelBuffer:(CVPixelBufferRef)destinationPixelBuffer
                       error:(NSError **)error;

- (void)flush;
- (void)reset;

@end

#endif /* VPX_METAL_DECODER_H */
