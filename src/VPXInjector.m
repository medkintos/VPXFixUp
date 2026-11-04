/*
 * VPXInjector.m
 * VPXMetalDecoder - System-wide VideoToolbox Hook & Injection Shim
 *
 * Target: macOS Tahoe / Intel UHD 630 / UHD 620
 * Copyright (c) 2024-2026 Hackintosh Open Source Community.
 */

#import "VPXMetalCommon.h"
#import "VPXMetalVADriver.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <IOKit/IOKitLib.h>

// -----------------------------------------------------------------------------
// Dyld Interposing Macro
// -----------------------------------------------------------------------------
#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
            __attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

// -----------------------------------------------------------------------------
// Hook: Block IOGVAXDecode in IOKit Property Queries
// Prevents AppleGVAVPXDecoder from falsely claiming it has T2 hardware acceleration
// -----------------------------------------------------------------------------
typedef CFTypeRef (*IORegistryEntryCreateCFPropertyFunc)(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options);
typedef CFTypeRef (*IORegistryEntrySearchCFPropertyFunc)(io_registry_entry_t entry, const io_name_t plane, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options);

static IORegistryEntryCreateCFPropertyFunc orig_IORegistryEntryCreateCFProperty = NULL;
static IORegistryEntrySearchCFPropertyFunc orig_IORegistryEntrySearchCFProperty = NULL;

static CFTypeRef hooked_IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    if (key && CFStringCompare(key, CFSTR("IOGVAXDecode"), 0) == kCFCompareEqualTo) {
        VPX_LOG_INFO("Hiding IOGVAXDecode from IORegistryEntryCreateCFProperty (bypassing broken AppleGVAVPXDecoder).");
        return NULL;
    }
    if (!orig_IORegistryEntryCreateCFProperty) {
        orig_IORegistryEntryCreateCFProperty = (IORegistryEntryCreateCFPropertyFunc)dlsym(RTLD_NEXT, "IORegistryEntryCreateCFProperty");
    }
    return orig_IORegistryEntryCreateCFProperty ? orig_IORegistryEntryCreateCFProperty(entry, key, allocator, options) : NULL;
}

static CFTypeRef hooked_IORegistryEntrySearchCFProperty(io_registry_entry_t entry, const io_name_t plane, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    if (key && CFStringCompare(key, CFSTR("IOGVAXDecode"), 0) == kCFCompareEqualTo) {
        VPX_LOG_INFO("Hiding IOGVAXDecode from IORegistryEntrySearchCFProperty (bypassing broken AppleGVAVPXDecoder).");
        return NULL;
    }
    if (!orig_IORegistryEntrySearchCFProperty) {
        orig_IORegistryEntrySearchCFProperty = (IORegistryEntrySearchCFPropertyFunc)dlsym(RTLD_NEXT, "IORegistryEntrySearchCFProperty");
    }
    return orig_IORegistryEntrySearchCFProperty ? orig_IORegistryEntrySearchCFProperty(entry, plane, key, allocator, options) : NULL;
}

DYLD_INTERPOSE(hooked_IORegistryEntryCreateCFProperty, IORegistryEntryCreateCFProperty)
DYLD_INTERPOSE(hooked_IORegistryEntrySearchCFProperty, IORegistryEntrySearchCFProperty)

// -----------------------------------------------------------------------------
// Hook: VTRegisterSupplementalVideoDecoderIfAvailable
// -----------------------------------------------------------------------------
typedef void (*VTRegisterSupplementalVideoDecoderIfAvailableFunc)(CMVideoCodecType codecType);
static VTRegisterSupplementalVideoDecoderIfAvailableFunc orig_VTRegisterSupplementalVideoDecoderIfAvailable = NULL;

static void hooked_VTRegisterSupplementalVideoDecoderIfAvailable(CMVideoCodecType codecType) {
    if (codecType == kCMVideoCodecType_VP9 ||
        codecType == kCMVideoCodecType_VP8 ||
        codecType == kCMVideoCodecType_QVP9) {
        VPX_LOG_INFO("Intercepted VTRegisterSupplementalVideoDecoderIfAvailable for '%.4s' -> Registering VPXMetalDecoder", (char *)&codecType);
        VPXRegisterDecoder();
    }

    if (!orig_VTRegisterSupplementalVideoDecoderIfAvailable) {
        orig_VTRegisterSupplementalVideoDecoderIfAvailable = (VTRegisterSupplementalVideoDecoderIfAvailableFunc)dlsym(RTLD_NEXT, "VTRegisterSupplementalVideoDecoderIfAvailable");
    }
    if (orig_VTRegisterSupplementalVideoDecoderIfAvailable) {
        orig_VTRegisterSupplementalVideoDecoderIfAvailable(codecType);
    }
}

DYLD_INTERPOSE(hooked_VTRegisterSupplementalVideoDecoderIfAvailable, VTRegisterSupplementalVideoDecoderIfAvailable)

// -----------------------------------------------------------------------------
// Fallback: Intercept GVACODEC_VTDecoder_CreateInstance if AppleGVAVPXDecoder is loaded
// -----------------------------------------------------------------------------
typedef OSStatus (*GVACODEC_VTDecoder_CreateInstanceFunc)(
    CFAllocatorRef allocator,
    CFDictionaryRef videoDecoderSpecification,
    CMVideoFormatDescriptionRef formatDescription,
    const VTDecompressionOutputCallbackRecord *outputCallback,
    void *sessionOut
);

__attribute__((visibility("default")))
OSStatus GVACODEC_VTDecoder_CreateInstance(
    CFAllocatorRef allocator,
    CFDictionaryRef videoDecoderSpecification,
    CMVideoFormatDescriptionRef formatDescription,
    const VTDecompressionOutputCallbackRecord *outputCallback,
    void *sessionOut)
{
    VPX_LOG_INFO("Intercepted GVACODEC_VTDecoder_CreateInstance call -> Safely delegating to VPXMetalDecoder!");
    return VPXMetal_VTDecoder_CreateInstance(allocator, videoDecoderSpecification, formatDescription, outputCallback, sessionOut);
}

// -----------------------------------------------------------------------------
// Constructor Initialization
// -----------------------------------------------------------------------------
__attribute__((constructor))
static void vpx_injector_init(void) {
    VPX_LOG_INFO("VPXInjector active in process PID %d (%s)", getpid(), getprogname());

    // Register our hardware decoders with VideoToolbox
    VPXRegisterDecoder();
}
