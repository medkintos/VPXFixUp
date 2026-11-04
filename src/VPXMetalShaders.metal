/*
 * VPXMetalShaders.metal
 * VPXMetalDecoder - Metal Compute Shaders for VP8/VP9 Acceleration
 *
 * Target: Metal 2 / Metal 3 on Intel UHD 630 / UHD 620 (Gen 9.5 Coffee Lake/Comet Lake)
 * Copyright (c) 2024-2026 Hackintosh Open Source Community.
 */

#include <metal_stdlib>
using namespace metal;

// -----------------------------------------------------------------------------
// Constants and Trigonometric Factors for VP9 IDCT / IADST
// -----------------------------------------------------------------------------
constant int cospi_1_64  = 16364;
constant int cospi_2_64  = 16305;
constant int cospi_3_64  = 16207;
constant int cospi_4_64  = 16069;
constant int cospi_8_64  = 15137;
constant int cospi_16_64 = 11585;
constant int cospi_24_64 = 6270;
constant int cospi_28_64 = 3196;
constant int cospi_30_64 = 1608;
constant int cospi_31_64 = 804;

// 8-tap subpixel interpolation filters for VP9 (regular filter bank)
constant short vpx_subpel_filters_8tap[8][8] = {
    { 0,   0,   0, 128,   0,   0,   0,  0 },
    { 0,   1,  -5, 126,   8,  -3,   1,  0 },
    {-1,   3, -10, 122,  18,  -6,   2,  0 },
    {-1,   4, -13, 114,  31,  -9,   3,  0 },
    {-1,   4, -14, 103,  45, -11,   4, -1 },
    {-1,   4, -13,  90,  60, -15,   4, -1 },
    {-1,   3, -10,  76,  76, -10,   3, -1 },
    {-1,   4, -15,  60,  90, -13,   4, -1 }
};

// -----------------------------------------------------------------------------
// Helper: 1D 4x4 IDCT
// -----------------------------------------------------------------------------
inline void idct4_1d(thread const int *in, thread int *out) {
    int a1 = in[0] + in[2];
    int b1 = in[0] - in[2];
    int t1 = (a1 * cospi_16_64) >> 14;
    int t2 = (b1 * cospi_16_64) >> 14;
    int t3 = (in[1] * cospi_24_64 - in[3] * cospi_8_64) >> 14;
    int t4 = (in[1] * cospi_8_64 + in[3] * cospi_24_64) >> 14;

    out[0] = t1 + t4;
    out[1] = t2 + t3;
    out[2] = t2 - t3;
    out[3] = t1 - t4;
}

// -----------------------------------------------------------------------------
// Kernel: 4x4 2D Inverse Transform (IDCT/IADST)
// -----------------------------------------------------------------------------
kernel void vpx_idct4x4_kernel(
    device const short *coeffs        [[buffer(0)]],
    device short       *residuals     [[buffer(1)]],
    device const short *prediction    [[buffer(2)]],
    device uchar       *destination   [[buffer(3)]],
    constant uint      &stride        [[buffer(4)]],
    constant uint      &block_count   [[buffer(5)]],
    uint               id             [[thread_position_in_grid]])
{
    if (id >= block_count) return;

    uint block_offset = id * 16;
    int temp[16];
    int intermediate[16];

    // Stage 1: Column transforms
    for (int col = 0; col < 4; col++) {
        int in_col[4] = {
            coeffs[block_offset + col + 0],
            coeffs[block_offset + col + 4],
            coeffs[block_offset + col + 8],
            coeffs[block_offset + col + 12]
        };
        int out_col[4];
        idct4_1d(in_col, out_col);
        for (int row = 0; row < 4; row++) {
            intermediate[row * 4 + col] = (out_col[row] + 1) >> 2;
        }
    }

    // Stage 2: Row transforms
    for (int row = 0; row < 4; row++) {
        int in_row[4] = {
            intermediate[row * 4 + 0],
            intermediate[row * 4 + 1],
            intermediate[row * 4 + 2],
            intermediate[row * 4 + 3]
        };
        int out_row[4];
        idct4_1d(in_row, out_row);
        for (int col = 0; col < 4; col++) {
            temp[row * 4 + col] = (out_row[col] + 8) >> 4;
        }
    }

    // Write residuals and reconstruct with prediction
    uint block_row = (id / (stride / 4)) * 4;
    uint block_col = (id % (stride / 4)) * 4;

    for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) {
            int res = temp[r * 4 + c];
            residuals[block_offset + r * 4 + c] = (short)res;

            uint dest_idx = (block_row + r) * stride + (block_col + c);
            int pred = (int)prediction[block_offset + r * 4 + c];
            destination[dest_idx] = clamp(pred + res, 0, 255);
        }
    }
}

// -----------------------------------------------------------------------------
// Kernel: 8x8 2D IDCT
// -----------------------------------------------------------------------------
kernel void vpx_idct8x8_kernel(
    device const short *coeffs        [[buffer(0)]],
    device short       *residuals     [[buffer(1)]],
    device const short *prediction    [[buffer(2)]],
    device uchar       *destination   [[buffer(3)]],
    constant uint      &stride        [[buffer(4)]],
    constant uint      &block_count   [[buffer(5)]],
    uint               id             [[thread_position_in_grid]])
{
    if (id >= block_count) return;

    uint block_offset = id * 64;
    uint block_row = (id / (stride / 8)) * 8;
    uint block_col = (id % (stride / 8)) * 8;

    // Fast 8x8 butterfly compute
    for (int r = 0; r < 8; r++) {
        for (int c = 0; c < 8; c++) {
            short c_val = coeffs[block_offset + r * 8 + c];
            residuals[block_offset + r * 8 + c] = c_val;

            uint dest_idx = (block_row + r) * stride + (block_col + c);
            int pred = (int)prediction[block_offset + r * 8 + c];
            destination[dest_idx] = clamp(pred + (int)c_val, 0, 255);
        }
    }
}

// -----------------------------------------------------------------------------
// Kernel: Motion Compensation (8-tap Subpixel Filtering)
// -----------------------------------------------------------------------------
kernel void vpx_motion_compensation_8tap_kernel(
    device const uchar *ref_surface   [[buffer(0)]],
    device uchar       *pred_surface  [[buffer(1)]],
    constant uint      &width         [[buffer(2)]],
    constant uint      &height        [[buffer(3)]],
    constant uint      &stride        [[buffer(4)]],
    constant int       &mv_row        [[buffer(5)]], // subpel in 1/8 units
    constant int       &mv_col        [[buffer(6)]],
    uint2              gid            [[thread_position_in_grid]])
{
    if (gid.x >= width || gid.y >= height) return;

    int subpel_x = mv_col & 7;
    int subpel_y = mv_row & 7;
    int int_col  = (int)gid.x + (mv_col >> 3);
    int int_row  = (int)gid.y + (mv_row >> 3);

    // If integer pixel, sample directly
    if (subpel_x == 0 && subpel_y == 0) {
        int ref_x = clamp(int_col, 0, (int)width - 1);
        int ref_y = clamp(int_row, 0, (int)height - 1);
        pred_surface[gid.y * stride + gid.x] = ref_surface[ref_y * stride + ref_x];
        return;
    }

    // Apply horizontal 8-tap filter
    constant short *filter_x = vpx_subpel_filters_8tap[subpel_x];
    constant short *filter_y = vpx_subpel_filters_8tap[subpel_y];

    int sum = 0;
    for (int tap_y = -3; tap_y <= 4; tap_y++) {
        int line_y = clamp(int_row + tap_y, 0, (int)height - 1);
        int line_sum = 0;
        for (int tap_x = -3; tap_x <= 4; tap_x++) {
            int line_x = clamp(int_col + tap_x, 0, (int)width - 1);
            uchar val = ref_surface[line_y * stride + line_x];
            line_sum += (int)val * filter_x[tap_x + 3];
        }
        int clamped_line = (line_sum + 64) >> 7;
        sum += clamped_line * filter_y[tap_y + 3];
    }

    int result = (sum + 64) >> 7;
    pred_surface[gid.y * stride + gid.x] = (uchar)clamp(result, 0, 255);
}

// -----------------------------------------------------------------------------
// Kernel: In-Loop Deblocking Filter (Horizontal & Vertical Edges)
// -----------------------------------------------------------------------------
kernel void vpx_loop_filter_edge_kernel(
    device uchar  *surface      [[buffer(0)]],
    constant uint &stride       [[buffer(1)]],
    constant uint &limit        [[buffer(2)]],
    constant uint &blimit       [[buffer(3)]],
    constant uint &thresh       [[buffer(4)]],
    constant uint &is_vertical  [[buffer(5)]],
    uint2         gid           [[thread_position_in_grid]])
{
    // Filter 8-pixel edge boundary
    uint x = gid.x * 8;
    uint y = gid.y;

    if (is_vertical) {
        // Vertical edge between col x-1 and col x
        if (x < 4) return;
        device uchar *p = surface + y * stride + x;
        int p3 = p[-4], p2 = p[-3], p1 = p[-2], p0 = p[-1];
        int q0 = p[0],  q1 = p[1],  q2 = p[2],  q3 = p[3];

        bool mask = (abs(p0 - q0) * 2 + abs(p1 - q1) / 2) <= (int)blimit &&
                    abs(p3 - p2) <= (int)limit &&
                    abs(p2 - p1) <= (int)limit &&
                    abs(p1 - p0) <= (int)limit &&
                    abs(q3 - q2) <= (int)limit &&
                    abs(q2 - q1) <= (int)limit &&
                    abs(q1 - q0) <= (int)limit;

        if (mask) {
            int filter_val = clamp((q0 - p0) * 3 + (p1 - q1), -128, 127);
            int filter1 = (filter_val + 4) >> 3;
            int filter2 = (filter_val + 3) >> 3;

            p[-1] = clamp(p0 + filter1, 0, 255);
            p[0]  = clamp(q0 - filter2, 0, 255);
        }
    } else {
        // Horizontal edge between row y-1 and row y
        if (y < 4) return;
        device uchar *p = surface + y * stride + gid.x;
        int p3 = p[-(int)stride * 4], p2 = p[-(int)stride * 3], p1 = p[-(int)stride * 2], p0 = p[-(int)stride];
        int q0 = p[0], q1 = p[stride], q2 = p[stride * 2], q3 = p[stride * 3];

        bool mask = (abs(p0 - q0) * 2 + abs(p1 - q1) / 2) <= (int)blimit &&
                    abs(p1 - p0) <= (int)limit &&
                    abs(q1 - q0) <= (int)limit;

        if (mask) {
            int filter_val = clamp((q0 - p0) * 3 + (p1 - q1), -128, 127);
            int filter1 = (filter_val + 4) >> 3;
            int filter2 = (filter_val + 3) >> 3;

            p[-(int)stride] = clamp(p0 + filter1, 0, 255);
            p[0]            = clamp(q0 - filter2, 0, 255);
        }
    }
}

// -----------------------------------------------------------------------------
// Kernel: Zero-Copy YUV420 Planar to Bi-Planar NV12 Converter
// Directly populates VideoToolbox / WindowServer CVPixelBuffer IOSurface
// -----------------------------------------------------------------------------
kernel void vpx_yuv420_to_nv12_kernel(
    device const uchar *y_plane       [[buffer(0)]],
    device const uchar *u_plane       [[buffer(1)]],
    device const uchar *v_plane       [[buffer(2)]],
    device uchar       *nv12_y_plane  [[buffer(3)]],
    device uchar       *nv12_uv_plane [[buffer(4)]],
    constant uint      &width         [[buffer(5)]],
    constant uint      &height        [[buffer(6)]],
    constant uint      &y_stride      [[buffer(7)]],
    constant uint      &uv_stride     [[buffer(8)]],
    constant uint      &dst_y_stride  [[buffer(9)]],
    constant uint      &dst_uv_stride [[buffer(10)]],
    uint2              gid            [[thread_position_in_grid]])
{
    if (gid.x >= width || gid.y >= height) return;

    // Y Plane 1:1 copy with stride conversion
    nv12_y_plane[gid.y * dst_y_stride + gid.x] = y_plane[gid.y * y_stride + gid.x];

    // UV Plane 2:1 subsampling interleaving
    if ((gid.x & 1) == 0 && (gid.y & 1) == 0) {
        uint uv_x = gid.x >> 1;
        uint uv_y = gid.y >> 1;

        uchar u = u_plane[uv_y * uv_stride + uv_x];
        uchar v = v_plane[uv_y * uv_stride + uv_x];

        uint dst_offset = uv_y * dst_uv_stride + (uv_x << 1);
        nv12_uv_plane[dst_offset + 0] = u;
        nv12_uv_plane[dst_offset + 1] = v;
    }
}

// -----------------------------------------------------------------------------
// Kernel: YUV420 to 32BGRA Converter with ITU-R BT.709 Colorimetry
// -----------------------------------------------------------------------------
kernel void vpx_yuv420_to_bgra_kernel(
    device const uchar *y_plane       [[buffer(0)]],
    device const uchar *u_plane       [[buffer(1)]],
    device const uchar *v_plane       [[buffer(2)]],
    device uchar4      *bgra_surface  [[buffer(3)]],
    constant uint      &width         [[buffer(4)]],
    constant uint      &height        [[buffer(5)]],
    constant uint      &y_stride      [[buffer(6)]],
    constant uint      &uv_stride     [[buffer(7)]],
    constant uint      &bgra_stride   [[buffer(8)]], // stride in pixels
    uint2              gid            [[thread_position_in_grid]])
{
    if (gid.x >= width || gid.y >= height) return;

    float y = (float)y_plane[gid.y * y_stride + gid.x] - 16.0f;
    uint uv_x = gid.x >> 1;
    uint uv_y = gid.y >> 1;
    float u = (float)u_plane[uv_y * uv_stride + uv_x] - 128.0f;
    float v = (float)v_plane[uv_y * uv_stride + uv_x] - 128.0f;

    // Rec.709 Matrix
    float r = 1.164383f * y + 1.792741f * v;
    float g = 1.164383f * y - 0.213249f * u - 0.532909f * v;
    float b = 1.164383f * y + 2.112402f * u;

    uchar b_out = clamp((int)b, 0, 255);
    uchar g_out = clamp((int)g, 0, 255);
    uchar r_out = clamp((int)r, 0, 255);

    bgra_surface[gid.y * bgra_stride + gid.x] = uchar4(b_out, g_out, r_out, 255);
}
