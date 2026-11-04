/*
 * VPXBitstreamParser.c
 * VPXMetalDecoder - Fast Bitstream Parser Implementation for VP8 & VP9
 *
 * Copyright (c) 2024-2026 Hackintosh Open Source Community.
 */

#include "VPXBitstreamParser.h"
#include <string.h>

void vpx_bit_reader_init(VPXBitReader *reader, const uint8_t *data, size_t size) {
    if (!reader) return;
    reader->data = data;
    reader->size = size;
    reader->bit_offset = 0;
}

uint32_t vpx_read_bit(VPXBitReader *reader) {
    if (!reader || !reader->data) return 0;
    size_t byte_pos = reader->bit_offset >> 3;
    if (byte_pos >= reader->size) return 0;

    int bit_pos = 7 - (int)(reader->bit_offset & 7);
    reader->bit_offset++;
    return (reader->data[byte_pos] >> bit_pos) & 1;
}

uint32_t vpx_read_bits(VPXBitReader *reader, int n) {
    uint32_t value = 0;
    for (int i = 0; i < n; i++) {
        value = (value << 1) | vpx_read_bit(reader);
    }
    return value;
}

uint32_t vpx_read_literal(VPXBitReader *reader, int n) {
    return vpx_read_bits(reader, n);
}

bool vpx_parse_vp9_header(const uint8_t *data, size_t size, VPXFrameHeader *header) {
    if (!data || size < 4 || !header) return false;
    memset(header, 0, sizeof(*header));

    VPXBitReader reader;
    vpx_bit_reader_init(&reader, data, size);

    // 1. Frame Marker: 2 bits, must be 0b10 (2)
    uint32_t frame_marker = vpx_read_bits(&reader, 2);
    if (frame_marker != 2) {
        return false;
    }

    // 2. Profile: 1-3 bits
    uint32_t profile_low = vpx_read_bit(&reader);
    uint32_t profile_high = vpx_read_bit(&reader);
    uint32_t profile = (profile_high << 1) | profile_low;
    if (profile == 3) {
        profile += vpx_read_bit(&reader);
    }
    header->profile = (VP9Profile)profile;

    // 3. Show existing frame
    uint32_t show_existing_frame = vpx_read_bit(&reader);
    if (show_existing_frame) {
        vpx_read_bits(&reader, 3); // frame_to_show_map_idx
        header->show_frame = true;
        return true;
    }

    // 4. Frame Type: 0 = KEY_FRAME, 1 = INTER_FRAME
    header->frame_type = (VP9FrameType)vpx_read_bit(&reader);
    header->show_frame = (bool)vpx_read_bit(&reader);
    header->error_resilient_mode = (bool)vpx_read_bit(&reader);

    if (header->frame_type == VP9_KEY_FRAME) {
        // Sync code: 0x49, 0x83, 0x42
        uint32_t sync_code = vpx_read_bits(&reader, 24);
        if (sync_code != 0x498342) {
            return false;
        }

        // Color config
        if (header->profile >= VP9_PROFILE_2) {
            uint32_t bit_depth_flag = vpx_read_bit(&reader);
            header->bit_depth = bit_depth_flag ? 12 : 10;
        } else {
            header->bit_depth = 8;
        }

        header->color_space = (uint8_t)vpx_read_bits(&reader, 3);
        if (header->color_space != 7) { // 7 is CS_SRGB
            header->color_range = (uint8_t)vpx_read_bit(&reader);
            if (header->profile == VP9_PROFILE_1 || header->profile == VP9_PROFILE_3) {
                header->subsampling_x = (uint8_t)vpx_read_bit(&reader);
                header->subsampling_y = (uint8_t)vpx_read_bit(&reader);
                vpx_read_bit(&reader); // reserved_zero
            } else {
                header->subsampling_x = 1;
                header->subsampling_y = 1;
            }
        } else {
            header->color_range = 1;
            if (header->profile == VP9_PROFILE_1 || header->profile == VP9_PROFILE_3) {
                header->subsampling_x = 0;
                header->subsampling_y = 0;
                vpx_read_bit(&reader); // reserved_zero
            }
        }

        // Frame dimensions (16 bits each, values are width-1 and height-1)
        header->width = vpx_read_bits(&reader, 16) + 1;
        header->height = vpx_read_bits(&reader, 16) + 1;

        // Display dimensions
        uint32_t render_and_frame_size_different = vpx_read_bit(&reader);
        if (render_and_frame_size_different) {
            header->display_width = vpx_read_bits(&reader, 16) + 1;
            header->display_height = vpx_read_bits(&reader, 16) + 1;
        } else {
            header->display_width = header->width;
            header->display_height = header->height;
        }

        header->refresh_frame_flags = 0xFF;
    } else {
        // Inter frame
        header->intra_only = header->show_frame ? false : (bool)vpx_read_bit(&reader);
        header->reset_frame_context = header->error_resilient_mode ? 0 : (uint8_t)vpx_read_bits(&reader, 2);

        if (header->intra_only) {
            uint32_t sync_code = vpx_read_bits(&reader, 24);
            if (sync_code != 0x498342) {
                return false;
            }
            header->refresh_frame_flags = (uint8_t)vpx_read_bits(&reader, 8);
            header->width = vpx_read_bits(&reader, 16) + 1;
            header->height = vpx_read_bits(&reader, 16) + 1;
            header->display_width = header->width;
            header->display_height = header->height;
        } else {
            header->refresh_frame_flags = (uint8_t)vpx_read_bits(&reader, 8);
            // Reference frame indices: last, golden, altref (3 bits each)
            vpx_read_bits(&reader, 3);
            vpx_read_bits(&reader, 3);
            vpx_read_bits(&reader, 3);

            // Frame size with refs or new
            uint32_t is_size_in_refs = vpx_read_bit(&reader);
            if (!is_size_in_refs) {
                header->width = vpx_read_bits(&reader, 16) + 1;
                header->height = vpx_read_bits(&reader, 16) + 1;
            }
        }
    }

    // In-loop filter params
    header->loop_filter_level = (uint8_t)vpx_read_bits(&reader, 6);
    header->loop_filter_sharpness = (uint8_t)vpx_read_bits(&reader, 3);

    return true;
}

bool vpx_parse_vp8_header(const uint8_t *data, size_t size, VPXFrameHeader *header) {
    if (!data || size < 10 || !header) return false;
    memset(header, 0, sizeof(*header));

    // First partition tag (3 bytes)
    uint32_t tag = data[0] | (data[1] << 8) | (data[2] << 16);
    header->frame_type = (tag & 1) ? VP9_INTER_FRAME : VP9_KEY_FRAME;
    uint32_t version = (tag >> 1) & 7;
    (void)version;
    header->show_frame = (tag >> 4) & 1;

    if (header->frame_type == VP9_KEY_FRAME) {
        // Start code: 0x9d, 0x01, 0x2a
        if (data[3] != 0x9d || data[4] != 0x01 || data[5] != 0x2a) {
            return false;
        }

        header->width = ((data[7] << 8) | data[6]) & 0x3fff;
        header->height = ((data[9] << 8) | data[8]) & 0x3fff;
        header->display_width = header->width;
        header->display_height = header->height;
        header->bit_depth = 8;
        header->subsampling_x = 1;
        header->subsampling_y = 1;
    }

    return true;
}

bool vpx_parse_superframe_index(const uint8_t *data, size_t size, VP9SuperframeIndex *index) {
    if (!data || size < 2 || !index) return false;
    memset(index, 0, sizeof(*index));

    // Superframe index is located at the end of the packet
    uint8_t marker = data[size - 1];
    if ((marker & 0xe0) != 0xc0) {
        // No superframe marker, single frame
        index->frame_count = 1;
        index->frame_sizes[0] = size;
        return true;
    }

    size_t count = (marker & 7) + 1;
    size_t mag = ((marker >> 3) & 3) + 1;
    size_t index_size = 2 + mag * count;

    if (size < index_size) return false;
    if (data[size - index_size] != marker) return false;

    const uint8_t *p = data + size - index_size + 1;
    index->frame_count = count;

    for (size_t i = 0; i < count; i++) {
        size_t frame_sz = 0;
        for (size_t j = 0; j < mag; j++) {
            frame_sz |= (size_t)(*p++) << (j * 8);
        }
        index->frame_sizes[i] = frame_sz;
    }

    return true;
}

bool vpx_is_vp9_keyframe(const uint8_t *data, size_t size) {
    VPXFrameHeader h;
    if (vpx_parse_vp9_header(data, size, &h)) {
        return h.frame_type == VP9_KEY_FRAME;
    }
    return false;
}

bool vpx_is_vp8_keyframe(const uint8_t *data, size_t size) {
    VPXFrameHeader h;
    if (vpx_parse_vp8_header(data, size, &h)) {
        return h.frame_type == VP9_KEY_FRAME;
    }
    return false;
}
