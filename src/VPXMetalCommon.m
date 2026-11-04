/*
 * VPXMetalCommon.m
 * VPXMetalDecoder - Common logging and shared definitions
 *
 * Copyright (c) 2024-2026 Hackintosh Open Source Community.
 */

#import "VPXMetalCommon.h"

os_log_t g_vpx_log = NULL;

__attribute__((constructor))
static void vpx_common_init(void) {
    g_vpx_log = os_log_create(VPX_METAL_LOG_SUBSYSTEM, "decoder");
    VPX_LOG_INFO("VPXMetalDecoder initialized. Target: Coffee Lake / Comet Lake (Intel Gen 9.5)");
}
