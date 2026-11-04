/*
 * VPXMetalVADriver.h
 * VPXMetalDecoder - VideoToolbox Driver Plugin Interface
 *
 * Target: macOS Tahoe / Intel UHD 630 / UHD 620
 * Copyright (c) 2024-2026 Hackintosh Open Source Community.
 */

#ifndef VPX_METAL_VA_DRIVER_H
#define VPX_METAL_VA_DRIVER_H

#import "VPXMetalCommon.h"

#ifdef __cplusplus
extern "C" {
#endif

// VideoToolbox C-vtable / Driver Export
__attribute__((visibility("default")))
OSStatus VPXMetal_VTDecoder_CreateInstance(
    CFAllocatorRef allocator,
    CFDictionaryRef videoDecoderSpecification,
    CMVideoFormatDescriptionRef formatDescription,
    const VTDecompressionOutputCallbackRecord *outputCallback,
    void *sessionOut);

// Explicit manual registration helper for applications / injected environments
__attribute__((visibility("default")))
OSStatus VPXRegisterDecoder(void);

#ifdef __cplusplus
}
#endif

#endif /* VPX_METAL_VA_DRIVER_H */
