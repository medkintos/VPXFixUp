/*
 * VPXMetalCommon.h
 * VPXMetalDecoder - Metal-accelerated VP8/VP9 VideoToolbox Driver
 *
 * Target: macOS Tahoe / Sonoma / Sequoia (x86_64 & Universal)
 * Target GPU: Intel Coffee Lake / Comet Lake (Intel UHD 630 / UHD 620 Gen 9.5)
 *
 * Copyright (c) 2024-2026 Hackintosh Open Source Community.
 */

#ifndef VPX_METAL_COMMON_H
#define VPX_METAL_COMMON_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <CoreMedia/CoreMedia.h>
#include <VideoToolbox/VideoToolbox.h>
#include <os/log.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

// VideoToolbox Codec FourCCs
#ifndef kCMVideoCodecType_VP9
#define kCMVideoCodecType_VP9 'vp09'
#endif

#ifndef kCMVideoCodecType_VP8
#define kCMVideoCodecType_VP8 'vp08'
#endif

#ifndef kCMVideoCodecType_QVP9
#define kCMVideoCodecType_QVP9 'qvp9'
#endif

// Identification
#define VPX_METAL_BUNDLE_ID           "id.medkintos.videodecoder.vpx.metal"
#define VPX_METAL_DECODER_NAME        "VP8/VP9 Metal Hardware-Accelerated Decoder"
#define VPX_METAL_LOG_SUBSYSTEM       "id.medkintos.vpxmetal"

// Logging helper
extern os_log_t g_vpx_log;
#define VPX_LOG(fmt, ...)   os_log(g_vpx_log, "[VPXMetal] " fmt, ##__VA_ARGS__)
#define VPX_LOG_ERR(fmt, ...) os_log_error(g_vpx_log, "[VPXMetal:ERROR] " fmt, ##__VA_ARGS__)
#define VPX_LOG_INFO(fmt, ...) os_log_info(g_vpx_log, "[VPXMetal:INFO] " fmt, ##__VA_ARGS__)

// Pixel Formats supported for output
#define VPX_FORMAT_NV12  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
#define VPX_FORMAT_P010  kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
#define VPX_FORMAT_BGRA  kCVPixelFormatType_32BGRA

// VP9 Frame Types & Profiles
typedef enum {
    VP9_KEY_FRAME   = 0,
    VP9_INTER_FRAME = 1
} VP9FrameType;

typedef enum {
    VP9_PROFILE_0 = 0, // 8-bit 4:2:0
    VP9_PROFILE_1 = 1, // 8-bit 4:2:2 / 4:4:4
    VP9_PROFILE_2 = 2, // 10/12-bit 4:2:0
    VP9_PROFILE_3 = 3  // 10/12-bit 4:2:2 / 4:4:4
} VP9Profile;

// Motion vector representation
typedef struct {
    int16_t row; // 1/8-pel or 1/4-pel resolution
    int16_t col;
} VPXMotionVector;

// Block transform types
typedef enum {
    TRANSFORM_DCT_DCT   = 0,
    TRANSFORM_ADST_DCT  = 1,
    TRANSFORM_DCT_ADST  = 2,
    TRANSFORM_ADST_ADST = 3
} VPXTransformType;

// Block sizes
typedef enum {
    TX_SIZE_4X4   = 0,
    TX_SIZE_8X8   = 1,
    TX_SIZE_16X16 = 2,
    TX_SIZE_32X32 = 3
} VPXTransformSize;

// Frame dimensions and metadata
typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t display_width;
    uint32_t display_height;
    uint8_t  bit_depth;
    uint8_t  subsampling_x;
    uint8_t  subsampling_y;
    uint8_t  color_space;
    uint8_t  color_range;
    VP9FrameType frame_type;
    VP9Profile   profile;
    bool     show_frame;
    bool     error_resilient_mode;
    bool     intra_only;
    uint8_t  reset_frame_context;
    uint8_t  refresh_frame_flags;
    uint8_t  loop_filter_level;
    uint8_t  loop_filter_sharpness;
} VPXFrameHeader;

#ifdef __cplusplus
}
#endif

#endif /* VPX_METAL_COMMON_H */
