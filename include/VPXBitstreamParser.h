/*
 * VPXBitstreamParser.h
 * VPXMetalDecoder - Fast Bitstream Parser for VP8 & VP9
 *
 * Copyright (c) 2024-2026 Hackintosh Open Source Community.
 */

#ifndef VPX_BITSTREAM_PARSER_H
#define VPX_BITSTREAM_PARSER_H

#include "VPXMetalCommon.h"
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Superframe index table
#define VPX_MAX_SUPERFRAME_FRAMES 8

typedef struct {
    size_t frame_sizes[VPX_MAX_SUPERFRAME_FRAMES];
    size_t frame_count;
} VP9SuperframeIndex;

// Fast bit reader helper
typedef struct {
    const uint8_t *data;
    size_t size;
    size_t bit_offset;
} VPXBitReader;

void vpx_bit_reader_init(VPXBitReader *reader, const uint8_t *data, size_t size);
uint32_t vpx_read_bit(VPXBitReader *reader);
uint32_t vpx_read_bits(VPXBitReader *reader, int n);
uint32_t vpx_read_literal(VPXBitReader *reader, int n);

// Bitstream parser functions
bool vpx_parse_vp9_header(const uint8_t *data, size_t size, VPXFrameHeader *header);
bool vpx_parse_vp8_header(const uint8_t *data, size_t size, VPXFrameHeader *header);
bool vpx_parse_superframe_index(const uint8_t *data, size_t size, VP9SuperframeIndex *index);

// Codec detector
bool vpx_is_vp9_keyframe(const uint8_t *data, size_t size);
bool vpx_is_vp8_keyframe(const uint8_t *data, size_t size);

#ifdef __cplusplus
}
#endif

#endif /* VPX_BITSTREAM_PARSER_H */
