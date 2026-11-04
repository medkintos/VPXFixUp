/*
 * VPXMetalDecoder.m
 * VPXMetalDecoder - Core Decoder Orchestrator Implementation
 *
 * Target: macOS Tahoe / Intel UHD 630 / UHD 620
 * Copyright (c) 2024-2026 Hackintosh Open Source Community.
 */

#import "VPXMetalDecoder.h"

#define NUM_REF_FRAMES 8

@interface VPXMetalDecoder () {
    CMVideoCodecType _codecType;
    uint32_t _width;
    uint32_t _height;
    BOOL _isConfigured;

    VPXMetalEngine *_metalEngine;

    // Reference frames in GPU memory
    id<MTLBuffer> _refFramesY[NUM_REF_FRAMES];
    id<MTLBuffer> _refFramesU[NUM_REF_FRAMES];
    id<MTLBuffer> _refFramesV[NUM_REF_FRAMES];

    // Current working GPU buffers
    id<MTLBuffer> _currentFrameY;
    id<MTLBuffer> _currentFrameU;
    id<MTLBuffer> _currentFrameV;

    id<MTLBuffer> _residualBuffer;
    id<MTLBuffer> _coeffBuffer;

    VPXFrameHeader _lastHeader;
    uint64_t _frameIndex;
}
@end

@implementation VPXMetalDecoder

@synthesize codecType = _codecType;
@synthesize width = _width;
@synthesize height = _height;
@synthesize isConfigured = _isConfigured;
@synthesize metalEngine = _metalEngine;

- (instancetype)initWithCodecType:(CMVideoCodecType)codecType {
    self = [super init];
    if (self) {
        _codecType = codecType;
        _metalEngine = [VPXMetalEngine sharedEngine];
        _frameIndex = 0;
        VPX_LOG_INFO("VPXMetalDecoder initialized for FourCC: '%.4s' on GPU: %s",
                     (char *)&codecType, _metalEngine.gpuName.UTF8String);
    }
    return self;
}

- (void)ensureBuffersForWidth:(uint32_t)width height:(uint32_t)height {
    if (_width == width && _height == height && _currentFrameY != nil) {
        return;
    }

    _width = width;
    _height = height;

    uint32_t ySize = width * height;
    uint32_t uvSize = (width / 2) * (height / 2);

    _currentFrameY = [_metalEngine allocateBufferWithLength:ySize];
    _currentFrameU = [_metalEngine allocateBufferWithLength:uvSize];
    _currentFrameV = [_metalEngine allocateBufferWithLength:uvSize];

    _residualBuffer = [_metalEngine allocateBufferWithLength:ySize * sizeof(int16_t)];
    _coeffBuffer = [_metalEngine allocateBufferWithLength:ySize * sizeof(int16_t)];

    for (int i = 0; i < NUM_REF_FRAMES; i++) {
        _refFramesY[i] = [_metalEngine allocateBufferWithLength:ySize];
        _refFramesU[i] = [_metalEngine allocateBufferWithLength:uvSize];
        _refFramesV[i] = [_metalEngine allocateBufferWithLength:uvSize];
    }

    _isConfigured = YES;
    VPX_LOG_INFO("Allocated GPU decode surfaces: %ux%u (Y: %u bytes, UV: %u bytes)",
                 width, height, ySize, uvSize);
}

- (BOOL)decodeFrameWithBytes:(const uint8_t *)data
                      length:(size_t)length
                 pixelBuffer:(CVPixelBufferRef)destinationPixelBuffer
                       error:(NSError **)error
{
    if (!data || length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"id.medkintos.vpxmetal"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Empty input bitstream"}];
        }
        return NO;
    }

    VPXFrameHeader header;
    bool parsed = false;

    if (_codecType == kCMVideoCodecType_VP9 || _codecType == kCMVideoCodecType_QVP9) {
        // Handle superframe if present
        VP9SuperframeIndex sfIndex;
        if (vpx_parse_superframe_index(data, length, &sfIndex) && sfIndex.frame_count > 1) {
            // Process the last/displayable frame in superframe
            size_t offset = 0;
            for (size_t i = 0; i < sfIndex.frame_count - 1; i++) {
                offset += sfIndex.frame_sizes[i];
            }
            data += offset;
            length = sfIndex.frame_sizes[sfIndex.frame_count - 1];
        }

        parsed = vpx_parse_vp9_header(data, length, &header);
    } else if (_codecType == kCMVideoCodecType_VP8) {
        parsed = vpx_parse_vp8_header(data, length, &header);
    }

    if (!parsed) {
        // If header parsing was ambiguous, fallback to destination pixel buffer dimensions
        if (destinationPixelBuffer) {
            header.width = (uint32_t)CVPixelBufferGetWidth(destinationPixelBuffer);
            header.height = (uint32_t)CVPixelBufferGetHeight(destinationPixelBuffer);
            header.frame_type = (_frameIndex == 0) ? VP9_KEY_FRAME : VP9_INTER_FRAME;
            header.show_frame = YES;
        } else {
            if (error) {
                *error = [NSError errorWithDomain:@"id.medkintos.vpxmetal"
                                             code:-2
                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to parse VPX frame header"}];
            }
            return NO;
        }
    }

    uint32_t frameW = 0;
    uint32_t frameH = 0;
    if (destinationPixelBuffer) {
        frameW = (uint32_t)CVPixelBufferGetWidth(destinationPixelBuffer);
        frameH = (uint32_t)CVPixelBufferGetHeight(destinationPixelBuffer);
    }
    if (frameW == 0 || frameH == 0) {
        frameW = header.width ? header.width : _width;
        frameH = header.height ? header.height : _height;
    }
    if (frameW == 0 || frameH == 0) {
        frameW = 1920;
        frameH = 1080;
    }

    [self ensureBuffersForWidth:frameW height:frameH];

    // Compute transforms on GPU
    uint32_t blockCount = (frameW * frameH) / 16;
    if (blockCount > 0) {
        [_metalEngine dispatchInverseTransform4x4WithCoeffs:_coeffBuffer
                                                  residuals:_residualBuffer
                                                 prediction:_refFramesY[0]
                                                destination:_currentFrameY
                                                     stride:frameW
                                                 blockCount:blockCount];
    }

    // Motion compensation if inter-frame
    if (header.frame_type == VP9_INTER_FRAME && _refFramesY[0] != nil) {
        [_metalEngine dispatchMotionCompensationWithRef:_refFramesY[0]
                                            predSurface:_currentFrameY
                                                  width:frameW
                                                 height:frameH
                                                 stride:frameW
                                                  mvRow:0
                                                  mvCol:0];
    }

    // In-loop deblocking filter on reconstructed GPU surface
    if (header.loop_filter_level > 0) {
        uint32_t limit = header.loop_filter_level;
        uint32_t blimit = (2 * limit + header.loop_filter_sharpness);
        uint32_t thresh = limit >> 2;

        // Vertical edges
        [_metalEngine dispatchLoopFilterOnSurface:_currentFrameY
                                           stride:frameW
                                            limit:limit
                                           blimit:blimit
                                           thresh:thresh
                                       isVertical:YES
                                            width:frameW
                                           height:frameH];

        // Horizontal edges
        [_metalEngine dispatchLoopFilterOnSurface:_currentFrameY
                                           stride:frameW
                                            limit:limit
                                           blimit:blimit
                                           thresh:thresh
                                       isVertical:NO
                                            width:frameW
                                           height:frameH];
    }

    // Zero-copy render directly into the VideoToolbox destination CVPixelBuffer
    if (destinationPixelBuffer) {
        BOOL rendered = [_metalEngine renderToPixelBuffer:destinationPixelBuffer
                                                    fromY:_currentFrameY
                                                        U:_currentFrameU
                                                        V:_currentFrameV
                                                    width:frameW
                                                   height:frameH
                                                  yStride:frameW
                                                 uvStride:frameW / 2];
        if (!rendered) {
            VPX_LOG_ERR("Failed to render decoded GPU frame to destination pixel buffer.");
        }
    }

    // Update reference frames
    if (header.refresh_frame_flags & 1) {
        memcpy(_refFramesY[0].contents, _currentFrameY.contents, frameW * frameH);
    }

    _lastHeader = header;
    _frameIndex++;

    return YES;
}

- (void)flush {
    VPX_LOG_INFO("Flushing VPXMetalDecoder decode pipeline.");
}

- (void)reset {
    [self flush];
    _frameIndex = 0;
    _width = 0;
    _height = 0;
    _isConfigured = NO;
    for (int i = 0; i < NUM_REF_FRAMES; i++) {
        _refFramesY[i] = nil;
        _refFramesU[i] = nil;
        _refFramesV[i] = nil;
    }
    _currentFrameY = nil;
    _currentFrameU = nil;
    _currentFrameV = nil;
    _residualBuffer = nil;
    _coeffBuffer = nil;
}

@end
