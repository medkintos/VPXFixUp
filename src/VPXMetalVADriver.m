/*
 * VPXMetalVADriver.m
 * VPXMetalDecoder - VideoToolbox Driver Plugin Implementation
 *
 * Target: macOS Tahoe / Intel UHD 630 / UHD 620
 * Copyright (c) 2024-2026 Hackintosh Open Source Community.
 */

#import "VPXMetalVADriver.h"
#import "VPXMetalDecoder.h"
#import <dlfcn.h>

// Undocumented / Internal VideoToolbox registration entry point
typedef OSStatus (*VTRegisterVideoDecoderWithInfoFunc)(
    CMVideoCodecType codecType,
    CFDictionaryRef decoderInfo,
    void *factoryFunction
);

// Internal session storage wrapper
typedef struct {
    void *isa; // Object header
    VPXMetalDecoder *decoder;
    VTDecompressionOutputCallbackRecord outputCallback;
    CMVideoFormatDescriptionRef formatDescription;
    CVPixelBufferPoolRef pixelBufferPool;
} VPXDecoderSession;

// Internal VideoToolbox session operations
__attribute__((unused))
static OSStatus vpx_session_decode_frame(
    VPXDecoderSession *session,
    CMSampleBufferRef sampleBuffer,
    VTDecodeFrameFlags decodeFlags,
    void *sourceFrameRefCon)
{
    if (!session || !session->decoder || !sampleBuffer) {
        return kVTParameterErr;
    }

    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!blockBuffer) {
        return kVTParameterErr;
    }

    size_t length = CMBlockBufferGetDataLength(blockBuffer);
    char *dataPointer = NULL;
    OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, NULL, &dataPointer);
    if (status != noErr || !dataPointer) {
        return status;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    if (session->pixelBufferPool) {
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, session->pixelBufferPool, &pixelBuffer);
    }

    if (!pixelBuffer) {
        // Create matching pixel buffer if pool is unavailable
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(session->formatDescription);
        NSDictionary *pixelBufferAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(VPX_FORMAT_NV12),
            (id)kCVPixelBufferWidthKey: @(dims.width),
            (id)kCVPixelBufferHeightKey: @(dims.height),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };

        CVPixelBufferCreate(kCFAllocatorDefault,
                            dims.width,
                            dims.height,
                            VPX_FORMAT_NV12,
                            (__bridge CFDictionaryRef)pixelBufferAttributes,
                            &pixelBuffer);
    }

    NSError *decodeError = nil;
    BOOL ok = [session->decoder decodeFrameWithBytes:(const uint8_t *)dataPointer
                                              length:length
                                         pixelBuffer:pixelBuffer
                                               error:&decodeError];

    VTDecodeInfoFlags infoFlags = 0;
    if (ok) {
        infoFlags |= kVTDecodeInfo_Asynchronous;
    }

    if (session->outputCallback.decompressionOutputCallback && pixelBuffer) {
        CMSampleTimingInfo timingInfo;
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timingInfo);

        session->outputCallback.decompressionOutputCallback(
            session->outputCallback.decompressionOutputRefCon,
            sourceFrameRefCon,
            ok ? noErr : kVTVideoDecoderBadDataErr,
            infoFlags,
            pixelBuffer,
            timingInfo.presentationTimeStamp,
            timingInfo.duration
        );
    }

    if (pixelBuffer) {
        CVPixelBufferRelease(pixelBuffer);
    }

    return ok ? noErr : kVTVideoDecoderBadDataErr;
}

OSStatus VPXMetal_VTDecoder_CreateInstance(
    CFAllocatorRef allocator,
    CFDictionaryRef videoDecoderSpecification,
    CMVideoFormatDescriptionRef formatDescription,
    const VTDecompressionOutputCallbackRecord *outputCallback,
    void *sessionOut)
{
    VPX_LOG_INFO("Creating VPXMetal VideoToolbox decoder instance.");

    CMVideoCodecType codecType = CMFormatDescriptionGetMediaSubType(formatDescription);
    if (codecType != kCMVideoCodecType_VP9 &&
        codecType != kCMVideoCodecType_VP8 &&
        codecType != kCMVideoCodecType_QVP9) {
        VPX_LOG_ERR("Unsupported codec type: 0x%x", (unsigned int)codecType);
        return kVTVideoDecoderUnsupportedDataFormatErr;
    }

    VPXDecoderSession *session = (VPXDecoderSession *)calloc(1, sizeof(VPXDecoderSession));
    if (!session) return kVTAllocationFailedErr;

    session->decoder = [[VPXMetalDecoder alloc] initWithCodecType:codecType];
    if (outputCallback) {
        session->outputCallback = *outputCallback;
    }
    if (formatDescription) {
        session->formatDescription = (CMVideoFormatDescriptionRef)CFRetain(formatDescription);
    }

    *(void **)sessionOut = (void *)session;
    VPX_LOG_INFO("VPXMetal VideoToolbox decoder instance created successfully.");
    return noErr;
}

OSStatus VPXRegisterDecoder(void) {
    static dispatch_once_t onceToken;
    static OSStatus result = noErr;

    dispatch_once(&onceToken, ^{
        void *vtHandle = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_NOW | RTLD_GLOBAL);
        if (!vtHandle) {
            VPX_LOG_ERR("Failed to dlopen VideoToolbox: %s", dlerror());
            result = -1;
            return;
        }

        VTRegisterVideoDecoderWithInfoFunc regFunc = (VTRegisterVideoDecoderWithInfoFunc)dlsym(vtHandle, "VTRegisterVideoDecoderWithInfo");
        if (!regFunc) {
            VPX_LOG_ERR("VTRegisterVideoDecoderWithInfo symbol not found.");
            result = -2;
            return;
        }

        // Capabilities dictionary advertising hardware acceleration
        NSDictionary *decoderInfoVP9 = @{
            @"IsHardwareAccelerated": @YES,
            @"VTIsHardwareAccelerated": @YES,
            @"CMClassImplementationID": @"id.medkintos.videodecoder.vpx.metal",
            @"CMClassImplementationName": @"VP9 Metal Hardware Accelerated Decoder",
            @"VTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder": @YES,
            @"VTCodecType": @"vp09"
        };

        NSDictionary *decoderInfoVP8 = @{
            @"IsHardwareAccelerated": @YES,
            @"VTIsHardwareAccelerated": @YES,
            @"CMClassImplementationID": @"id.medkintos.videodecoder.vp8.metal",
            @"CMClassImplementationName": @"VP8 Metal Hardware Accelerated Decoder",
            @"VTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder": @YES,
            @"VTCodecType": @"vp08"
        };

        OSStatus st9 = regFunc(kCMVideoCodecType_VP9, (__bridge CFDictionaryRef)decoderInfoVP9, (void *)VPXMetal_VTDecoder_CreateInstance);
        OSStatus st8 = regFunc(kCMVideoCodecType_VP8, (__bridge CFDictionaryRef)decoderInfoVP8, (void *)VPXMetal_VTDecoder_CreateInstance);

        VPX_LOG_INFO("Registered VP9 Metal decoder with VideoToolbox (status: %d)", (int)st9);
        VPX_LOG_INFO("Registered VP8 Metal decoder with VideoToolbox (status: %d)", (int)st8);

        result = (st9 == noErr || st8 == noErr) ? noErr : st9;
    });

    return result;
}

__attribute__((constructor))
static void vpx_driver_init(void) {
    VPX_LOG_INFO("VPXMetalVADriver bundle loaded into process PID %d (%s)",
                 getpid(), getprogname());
    VPXRegisterDecoder();
}
