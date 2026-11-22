//
//  WNRenderer+Draw.m — 逆向还原：Metal 绘制主循环
//
//  还原依据：PetDFY.dylib arm64e
//    drawInMTKView:                                  510 insns
//    encodeClip:frame:descriptor:command:offset:     591 insns
//    preparedLiveClipForCommand:slot:                658 insns
//    paintSurface:slot:rect:blit:                    520 insns
//    updateInteractionPath                           444 insns
//    meshesForParts:                                 361 insns
//    captureClip:frame:URL:                          328 insns
//    liveFigureLook                                  228 insns
//    liveFigureBounds                                 74 insns
//    drawMesh:positions:textureObject:look:encoder:   97 insns
//
//  绘制流程：
//    1. drawInMTKView   → 计算帧间隔，推进 rig，取 drawable
//    2. preparedLiveClip → 准备 live 网格（阴影 + 前景）
//    3. encodeClip      → 编码顶点缓冲 + 提交命令
//    4. drawMesh        → 逐网格设置管线与缓冲
//    5. 剪影 + 高斯模糊 → 辉光
//

#import "WNRenderer.h"
#import "WNLiveRig.h"
#import "WNPainter.h"
#import "WNClip.h"
#import "WNMesh.h"
#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>
#import <math.h>

@implementation WNRenderer (Draw)

#pragma mark - MTKView 回调

/// 510 条指令。每帧入口。
- (void)drawInMTKView:(MTKView *)view {
    if (!view || !_device) return;

    double now = CACurrentMediaTime();
    double dt = (_lastFrameAt > 0) ? (now - _lastFrameAt) : (1.0 / 60.0);
    if (dt > 0.25) dt = 1.0 / 60.0;         // 首帧或后台恢复
    _lastFrameAt = now;
    _elapsed += dt;

    // 帧率统计（滑动窗口）
    [_performanceSamples addObject:@(dt)];
    while (_performanceSamples.count > 120) [_performanceSamples removeObjectAtIndex:0];

    // 推进 rig（网格装配）
    // 修正：原写 [_liveRig renderBuildingMesh:dt]（把 double dt 传进来），
    //       实测签名是 v20@0:8B16 —— 参数是 BOOL，不是 double（method_t / 0xb0140）。
    //       二进制唯一的两处调用点都取常量：render @0x4dc2c `mov w2,#1`；
    //       step:buildMesh: 尾调 @0x4dc30 直传入参 w2。本处对应 render 语义，传 YES。
    if (_liveRig) {
        [_liveRig renderBuildingMesh:YES];
    }

    // 取 drawable
    id drawable = [view currentDrawable];
    if (!drawable) return;

    NSInteger slot = (NSInteger)(_frameIndex % 3);   // 三缓冲
    _frameIndex++;

    // 建命令缓冲
    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    if (!cmd) return;

    // 准备 live 网格
    WNClip *live = [self preparedLiveClipForCommand:cmd slot:slot];

    // 编码绘制
    if (live) {
        [self encodeClip:live frame:0 descriptor:view.currentRenderPassDescriptor
                 command:cmd offset:CGPointZero];
    }

    [cmd presentDrawable:drawable];
    [cmd commit];

    _didSubmitFrame = YES;
}

#pragma mark - live 网格准备

/// 658 条指令。准备当前帧的 live 网格（阴影 + 前景两部分）。
- (WNClip *)preparedLiveClipForCommand:(id<MTLCommandBuffer>)cmd slot:(NSInteger)slot {
    if (!cmd || !_liveRig) return nil;

    WNClip *clip = _liveClip;
    if (!clip) {
        clip = [WNClip new];
        _liveClip = clip;
    }

    // 1) 取画布尺寸
    CGRect fgBounds = [_painter foregroundBoundsForRig:_liveRig];
    CGRect shBounds = [_painter shadowBoundsForRig:_liveRig];
    if (CGRectIsEmpty(fgBounds)) return nil;

    // 2) 建表面（阴影 + 前景各一层）
    CGSize sz = CGSizeMake(fgBounds.size.width, fgBounds.size.height);
    id fgSurf  = [self surfaceForKey:@"fg"  slot:slot size:sz];
    id shSurf  = [self surfaceForKey:@"sh"  slot:slot size:shBounds.size];

    // 3) 绘制阴影层
    if (shSurf) {
        [self paintSurface:shSurf slot:slot rect:shBounds blit:NO];
    }
    // 4) 绘制前景层
    if (fgSurf) {
        [self paintSurface:fgSurf slot:slot rect:fgBounds blit:NO];
    }

    // 5) 更新顶点位置
    NSDictionary *pos = [_liveRig positions];
    if ([pos isKindOfClass:[NSDictionary class]]) {
        clip.positions = [NSKeyedArchiver archivedDataWithRootObject:pos
                                                requiringSecureCoding:NO
                                                                error:NULL];
        clip.backgroundPositions = nil;
    }
    return clip;
}

/// 520 条指令。把 rig 画到指定表面。
- (void)paintSurface:(id)surface slot:(NSInteger)slot rect:(CGRect)rect blit:(BOOL)blit {
    if (!surface || !_painter || !_liveRig) return;

    // 1) 阴影指令
    NSArray *shadowOps = [_painter shadowOperationsForRig:_liveRig];

    // 2) 绘制（用 UIGraphics 离屏渲染，再上传到 Metal 纹理）
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (ctx) {
        CGContextTranslateCTM(ctx, -rect.origin.x, -rect.origin.y);
        // 阴影
        if (shadowOps.count) [_painter paintShadowOperations:shadowOps context:ctx];
        // 前景
        [_painter paintOverlayForRig:_liveRig background:NO context:ctx];
    }
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    // 3) 上传（blit 模式下走 blitCommandEncoder，否则直接写 pixels）
    if (img && [surface isKindOfClass:[NSDictionary class]]) {
        NSMutableData *pixels = ((NSDictionary *)surface)[@"pixels"];
        if ([pixels isKindOfClass:[NSMutableData class]]) {
            CGImageRef cg = img.CGImage;
            if (cg) {
                size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
                size_t bytes = w * h * 4;
                if (pixels.length >= bytes) {
                    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
                    CGContextRef bctx = CGBitmapContextCreate(pixels.mutableBytes, w, h, 8,
                                                              w * 4, cs,
                                                              kCGImageAlphaPremultipliedLast);
                    if (bctx) {
                        CGContextDrawImage(bctx, CGRectMake(0, 0, w, h), cg);
                        CGContextRelease(bctx);
                    }
                    CGColorSpaceRelease(cs);
                }
            }
        }
    }
}

#pragma mark - 编码

/// 591 条指令。编码一个 clip 的绘制命令。
- (void)encodeClip:(WNClip *)clip frame:(NSInteger)frame
        descriptor:(MTLRenderPassDescriptor *)rp
           command:(id<MTLCommandBuffer>)cmd offset:(CGPoint)offset {
    if (!clip || !rp || !cmd) return;

    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
    if (!enc) return;

    // 顶点数据
    NSData *positions = clip.positions;
    if ([positions isKindOfClass:[NSData class]] && positions.length) {
        NSUInteger len = positions.length;
        id<MTLBuffer> buf = [_device newBufferWithBytes:positions.bytes
                                                length:len
                                               options:MTLResourceStorageModeShared];
        if (buf) {
            [enc setVertexBuffer:buf offset:0 atIndex:0];
            [enc setVertexBytes:&(float[4]){1, 1, 0, 0}
                         length:sizeof(float) * 4
                        atIndex:2];
        }
    }
    if (_sampler) [enc setFragmentSamplerState:_sampler atIndex:0];

    // 逐网格绘制
    NSArray *meshes = clip.meshes;
    if ([meshes isKindOfClass:[NSArray class]]) {
        for (WNMesh *m in meshes) {
            if (![m isKindOfClass:[WNMesh class]]) continue;
            [self drawMesh:m positions:positions textureObject:nil look:_glowTint encoder:enc];
        }
    }

    [enc endEncoding];
}

/// 97 条指令。绘制单个网格。
- (void)drawMesh:(WNMesh *)mesh positions:(id)pos textureObject:(id)tex
            look:(NSDictionary *)look encoder:(id<MTLRenderCommandEncoder>)enc {
    if (!mesh || !enc) return;

    // 1) 选管线：multiply 标志决定乘算还是普通
    id<MTLRenderPipelineState> pipe = mesh.multiply ? _multiplyPipeline : _normalPipeline;
    if (!pipe) pipe = _normalPipeline;
    if (!pipe) return;
    [enc setRenderPipelineState:pipe];

    // 2) 顶点缓冲：positionOffset 是该网格在共享 buffer 中的偏移
    if (mesh.uv) [enc setVertexBuffer:mesh.uv offset:0 atIndex:1];
    if (mesh.indices) [enc setVertexBuffer:mesh.indices offset:0 atIndex:3];

    // 3) 纹理
    id<MTLTexture> t = [self texture:mesh.texture];
    if (t) [enc setFragmentTexture:t atIndex:0];

    // 4) 提交绘制
    if (mesh.indexCount > 0) {
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:mesh.indexCount
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:mesh.indices
                 indexBufferOffset:mesh.positionOffset];
    }
}

#pragma mark - 交互路径

/// 444 条指令。构建点击命中路径（CGPath）。
- (void)updateInteractionPath {
    if (!_buildsInteractionPath || !_liveRig) return;

    NSDictionary *pos = [_liveRig positions];
    if (![pos isKindOfClass:[NSDictionary class]]) return;

    CGMutablePathRef path = CGPathCreateMutable();
    if (!path) return;

    // 遍历所有部件的顶点，连成多边形
    for (NSString *key in [_liveRig order]) {
        NSDictionary *part = pos[key];
        if (![part isKindOfClass:[NSDictionary class]]) continue;
        NSData *bytes = part[@"bytes"];
        if (![bytes isKindOfClass:[NSData class]]) continue;

        const float *f = bytes.bytes;
        NSUInteger n = bytes.length / 8;      // float2
        if (n < 3) continue;
        CGPathMoveToPoint(path, NULL, f[0], f[1]);
        for (NSUInteger i = 1; i < n; i++) {
            CGPathAddLineToPoint(path, NULL, f[i * 2], f[i * 2 + 1]);
        }
        CGPathCloseSubpath(path);
    }

    if (_interactionPath) CGPathRelease(_interactionPath);
    _interactionPath = path;
}

/// 74 条指令。当前角色的舞台包围盒。
- (CGRect)liveFigureBounds {
    if (!_liveRig) return CGRectZero;
    return [_painter foregroundBoundsForRig:_liveRig];
}

/// 228 条指令，纯计算。当前渲染视角参数。
- (NSDictionary *)liveFigureLook {
    CGRect b = [self liveFigureBounds];
    if (CGRectIsEmpty(b)) return @{};

    double cx = CGRectGetMidX(b), cy = CGRectGetMidY(b);
    double w = b.size.width, h = b.size.height;

    return @{
        @"ax": @(cx), @"ay": @(cy),
        @"kx": @(w / 2), @"ky": @(h / 2),
        @"AX": @(cx + w * 0.5), @"AY": @(cy + h * 0.5),
        @"rot": @(0.0),
        @"view": [NSValue valueWithCGRect:b],
    };
}

#pragma mark - 网格构建

/// 361 条指令。把部件名数组转成 WNMesh 数组。
- (NSArray *)meshesForParts:(NSArray *)parts {
    if (![parts isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *p in parts) {
        if (![p isKindOfClass:[NSDictionary class]]) continue;
        WNMesh *m = [WNMesh new];
        m.positionOffset = [p[@"offset"] unsignedLongLongValue];
        m.indexCount     = [p[@"count"] unsignedLongLongValue];
        m.texture        = p[@"texture"];
        m.multiply       = [p[@"multiply"] boolValue];
        [out addObject:m];
    }
    return out;
}

#pragma mark - 截图

/// 328 条指令。把当前帧渲染到纹理并导出 PNG。
- (BOOL)captureClip:(WNClip *)clip frame:(NSInteger)frame URL:(NSURL *)url {
    if (!clip || !url || !_device) return NO;

    CGRect b = [self liveFigureBounds];
    if (CGRectIsEmpty(b)) return NO;
    NSUInteger w = (NSUInteger)b.size.width, h = (NSUInteger)b.size.height;
    if (w == 0 || h == 0) return NO;

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                            width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex = [_device newTextureWithDescriptor:td];
    if (!tex) return NO;

    // 渲染
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = tex;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);

    id<MTLCommandBuffer> cmd = [_queue commandBuffer];
    [self encodeClip:clip frame:frame descriptor:rp command:cmd offset:CGPointZero];
    [cmd commit];
    [cmd waitUntilCompleted];

    // 读回并写 PNG
    NSUInteger bytes = w * h * 4;
    NSMutableData *pixels = [NSMutableData dataWithLength:bytes];
    [tex getBytes:pixels.mutableBytes bytesPerRow:w * 4
       fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(pixels.mutableBytes, w, h, 8, w * 4, cs,
                                             kCGImageAlphaPremultipliedFirst);
    if (!ctx) { CGColorSpaceRelease(cs); return NO; }
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    if (!img) return NO;

    UIImage *ui = [UIImage imageWithCGImage:img];
    CGImageRelease(img);
    NSData *png = UIImagePNGRepresentation(ui);
    return png ? [png writeToURL:url atomically:YES] : NO;
}


#pragma mark - 角色离屏渲染（1.2 补齐）

/// 把当前 rig 的角色（身体 + 情绪叠加层）渲染成一张 UIImage。
///
/// 原 1.2 骨架的绘制链断在两处：rig.frame 从未赋值（离屏画布尺寸为 0），
/// WNPainter 不画身体。这里按 rig.frame 建画布，缩放 3 倍保证贴图分辨率，
/// 再交给 painter 绘制。绘制结果由 PDPetView 显示。
- (UIImage *)pd_renderCharacterImage {
    WNLiveRig *rig = _liveRig;
    if (!rig || !_painter) return nil;

    CGRect stage = rig.frame;
    if (CGRectIsEmpty(stage)) return nil;

    double scale = 3.0;
    CGSize size = CGSizeMake((CGFloat)ceil(stage.size.width * scale),
                             (CGFloat)ceil(stage.size.height * scale));
    if (size.width <= 0.0 || size.height <= 0.0) return nil;

    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) { UIGraphicsEndImageContext(); return nil; }

    CGContextTranslateCTM(ctx, -stage.origin.x * scale, -stage.origin.y * scale);
    CGContextScaleCTM(ctx, scale, scale);

    // 地面阴影：原阴影贴图（shadow.png）素材包里没有，这里用椭圆等价实现。
    {
        CGFloat cx = CGRectGetMidX(stage);
        CGFloat cy = CGRectGetMaxY(stage) + 4.0;
        CGFloat rx = stage.size.width * 0.42;
        CGFloat ry = rx * 0.22;
        CGContextSetRGBAFillColor(ctx, 0.0, 0.0, 0.0, 0.18);
        CGContextFillEllipseInRect(ctx, CGRectMake(cx - rx, cy - ry, rx * 2.0, ry * 2.0));
    }

    [_painter paintOverlayForRig:rig background:NO context:ctx];

    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

@end
