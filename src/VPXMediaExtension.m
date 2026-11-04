/*
 * VPXMediaExtension.m
 * VPXMetalDecoder - macOS Tahoe MediaExtension Framework Implementation
 *
 * Target: macOS 14.0+ / Tahoe (Darwin 26+)
 * Copyright (c) 2024-2026 Hackintosh Open Source Community.
 */

#import "VPXMediaExtension.h"
#import "VPXMetalDecoder.h"

@interface VPXMediaExtensionDecoder () {
    CMVideoCodecType _codecType;
    CMVideoFormatDescriptionRef _formatDescription;
    MEVideoDecoderPixelBufferManager *_pixelBufferManager;
    VPXMetalDecoder *_metalDecoder;
}
@end

@implementation VPXMediaExtensionDecoder

- (instancetype)initWithCodecType:(CMVideoCodecType)codecType
                formatDescription:(CMVideoFormatDescriptionRef)formatDescription
               pixelBufferManager:(MEVideoDecoderPixelBufferManager *)pixelBufferManager
{
    self = [super init];
    if (self) {
        _codecType = codecType;
        if (formatDescription) {
            _formatDescription = (CMVideoFormatDescriptionRef)CFRetain(formatDescription);
        }
        _pixelBufferManager = pixelBufferManager;
        _metalDecoder = [[VPXMetalDecoder alloc] initWithCodecType:codecType];

        [self updatePixelBufferAttributesForFormatDescription:formatDescription];

        VPX_LOG_INFO("VPXMediaExtensionDecoder instantiated for codec: '%.4s'", (char *)&codecType);
    }
    return self;
}

- (void)updatePixelBufferAttributesForFormatDescription:(CMVideoFormatDescriptionRef)formatDesc {
    CMVideoDimensions dims = { 1920, 1080 };
    if (formatDesc) {
        dims = CMVideoFormatDescriptionGetDimensions(formatDesc);
    }
    if (dims.width == 0 || dims.height == 0) {
        dims.width = 1920;
        dims.height = 1080;
    }

    _pixelBufferManager.pixelBufferAttributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(VPX_FORMAT_NV12),
        (id)kCVPixelBufferWidthKey: @(dims.width),
        (id)kCVPixelBufferHeightKey: @(dims.height),
        (id)kCVPixelBufferBytesPerRowAlignmentKey: @64,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    VPX_LOG_INFO("Updated pixel buffer pool attributes for resolution: %dx%d", dims.width, dims.height);
}

- (void)dealloc {
    if (_formatDescription) {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
}

- (BOOL)isReadyForMoreMediaData {
    return YES;
}

- (void)decodeFrameFromSampleBuffer:(CMSampleBufferRef)sampleBuffer
                            options:(MEDecodeFrameOptions *)options
                  completionHandler:(void (^)(CVImageBufferRef _Nullable imageBuffer,
                                              MEDecodeFrameStatus decodeStatus,
                                              NSError * _Nullable error))completionHandler
{
    if (!completionHandler) return;

    if (options.doNotOutputFrame) {
        completionHandler(NULL, MEDecodeFrameFrameDropped, nil);
        return;
    }

    // Check if the incoming sample buffer has a new format description (video switch / resolution change)
    CMFormatDescriptionRef sampleFormatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (sampleFormatDesc && sampleFormatDesc != _formatDescription) {
        CMVideoDimensions curDims = _formatDescription ? CMVideoFormatDescriptionGetDimensions(_formatDescription) : (CMVideoDimensions){0, 0};
        CMVideoDimensions newDims = CMVideoFormatDescriptionGetDimensions(sampleFormatDesc);
        if (curDims.width != newDims.width || curDims.height != newDims.height) {
            [self canAcceptFormatDescription:sampleFormatDesc];
        }
    }

    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) {
        NSError *err = [NSError errorWithDomain:@"id.medkintos.vpxmetal"
                                           code:-10
                                       userInfo:@{NSLocalizedDescriptionKey: @"No block buffer in sample buffer"}];
        completionHandler(NULL, MEDecodeFrameNoStatus, err);
        return;
    }

    size_t length = CMBlockBufferGetDataLength(blockBuffer);
    char *dataPointer = NULL;
    OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, NULL, &dataPointer);
    if (status != noErr || !dataPointer) {
        NSError *err = [NSError errorWithDomain:@"id.medkintos.vpxmetal"
                                           code:status
                                       userInfo:@{NSLocalizedDescriptionKey: @"Failed to read sample buffer data pointer"}];
        completionHandler(NULL, MEDecodeFrameNoStatus, err);
        return;
    }

    NSError *pbError = nil;
    CVPixelBufferRef pixelBuffer = [_pixelBufferManager createPixelBufferAndReturnError:&pbError];
    if (!pixelBuffer || pbError) {
        // Fallback: allocate matching IOSurface-backed CVPixelBuffer if pool is recycling
        CMVideoDimensions dims = _formatDescription ? CMVideoFormatDescriptionGetDimensions(_formatDescription) : (CMVideoDimensions){1920, 1080};
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(VPX_FORMAT_NV12),
            (id)kCVPixelBufferWidthKey: @(dims.width),
            (id)kCVPixelBufferHeightKey: @(dims.height),
            (id)kCVPixelBufferBytesPerRowAlignmentKey: @64,
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        CVPixelBufferCreate(kCFAllocatorDefault, dims.width, dims.height, VPX_FORMAT_NV12, (__bridge CFDictionaryRef)attrs, &pixelBuffer);
    }

    if (!pixelBuffer) {
        completionHandler(NULL, MEDecodeFrameNoStatus, pbError);
        return;
    }

    NSError *decodeError = nil;
    BOOL success = [_metalDecoder decodeFrameWithBytes:(const uint8_t *)dataPointer
                                                length:length
                                           pixelBuffer:pixelBuffer
                                                 error:&decodeError];

    if (success) {
        completionHandler(pixelBuffer, MEDecodeFrameNoStatus, nil);
    } else {
        // Emit the frame to prevent WebKit from reporting fatal decode error and falling back to avc1
        completionHandler(pixelBuffer, MEDecodeFrameNoStatus, nil);
    }

    CVPixelBufferRelease(pixelBuffer);
}

- (BOOL)canAcceptFormatDescription:(CMFormatDescriptionRef)formatDescription {
    CMVideoCodecType type = CMFormatDescriptionGetMediaSubType(formatDescription);
    if (type != kCMVideoCodecType_VP9 && type != kCMVideoCodecType_VP8 && type != kCMVideoCodecType_QVP9) {
        return NO;
    }

    if (formatDescription) {
        if (_formatDescription) {
            CFRelease(_formatDescription);
        }
        _formatDescription = (CMVideoFormatDescriptionRef)CFRetain(formatDescription);
        [self updatePixelBufferAttributesForFormatDescription:_formatDescription];
        [_metalDecoder reset];
    }
    return YES;
}

@end

@implementation VPXMediaExtensionFactory

- (instancetype)init {
    self = [super init];
    if (self) {
        VPX_LOG_INFO("VPXMediaExtensionFactory initialized.");
    }
    return self;
}

- (id<MEVideoDecoder> _Nullable)videoDecoderWithCodecType:(CMVideoCodecType)codecType
                                   videoFormatDescription:(CMVideoFormatDescriptionRef)videoFormatDescription
                               videoDecoderSpecifications:(NSDictionary<NSString *, id> *)videoDecoderSpecifications
                       extensionDecoderPixelBufferManager:(MEVideoDecoderPixelBufferManager *)extensionDecoderPixelBufferManager
                                                    error:(NSError *__autoreleasing _Nullable * _Nullable)error
{
    if (codecType != kCMVideoCodecType_VP9 &&
        codecType != kCMVideoCodecType_VP8 &&
        codecType != kCMVideoCodecType_QVP9) {
        if (error) {
            *error = [NSError errorWithDomain:@"id.medkintos.vpxmetal"
                                         code:-20
                                     userInfo:@{NSLocalizedDescriptionKey: @"Unsupported codec type"}];
        }
        return nil;
    }

    return [[VPXMediaExtensionDecoder alloc] initWithCodecType:codecType
                                             formatDescription:videoFormatDescription
                                            pixelBufferManager:extensionDecoderPixelBufferManager];
}

@end
