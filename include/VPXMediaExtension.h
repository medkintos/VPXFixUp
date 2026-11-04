/*
 * VPXMediaExtension.h
 * VPXMetalDecoder - macOS Tahoe MediaExtension Framework Interface
 *
 * Target: macOS 14.0+ / Tahoe (Darwin 26+)
 * Copyright (c) 2024-2026 Hackintosh Open Source Community.
 */

#ifndef VPX_MEDIA_EXTENSION_H
#define VPX_MEDIA_EXTENSION_H

#import "VPXMetalCommon.h"
#import <MediaExtension/MediaExtension.h>

NS_ASSUME_NONNULL_BEGIN

@interface VPXMediaExtensionFactory : NSObject <MEVideoDecoderExtension>

- (instancetype)init;

- (id<MEVideoDecoder> _Nullable)videoDecoderWithCodecType:(CMVideoCodecType)codecType
                                   videoFormatDescription:(CMVideoFormatDescriptionRef)videoFormatDescription
                               videoDecoderSpecifications:(NSDictionary<NSString *, id> *)videoDecoderSpecifications
                       extensionDecoderPixelBufferManager:(MEVideoDecoderPixelBufferManager *)extensionDecoderPixelBufferManager
                                                    error:(NSError *__autoreleasing _Nullable * _Nullable)error;

@end

@interface VPXMediaExtensionDecoder : NSObject <MEVideoDecoder>

- (instancetype)initWithCodecType:(CMVideoCodecType)codecType
                formatDescription:(CMVideoFormatDescriptionRef)formatDescription
               pixelBufferManager:(MEVideoDecoderPixelBufferManager *)pixelBufferManager;

@end

NS_ASSUME_NONNULL_END

#endif /* VPX_MEDIA_EXTENSION_H */
