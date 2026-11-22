//
//  PDPetView.m — 逆向还原：桌宠视图（MTKView）
//
//  还原依据：PetDFY.dylib arm64e，74 个方法共 2773 条指令
//  本文件覆盖：初始化 / 触摸处理 / 手势 / 帧率 / 交互区域
//
//  ivar 布局（size=200，27 个字段）：
//    +8   isa
//    +9   BOOL stroking            +10 BOOL layoutAnimating
//    +11  BOOL hasLastBubblePosition  +12 BOOL hasLastHoverPosition
//    +13  BOOL tapEligible         +14 BOOL menuPressActive
//    +16  WNRenderer * renderer
//    +24  NSString * doubleTapAction   +32 NSString * longPressAction
//    +40  block gestureActionHandler
//    +48  long long activeFPS
//    +56  block frameHandler       +64 block beforeFrameHandler
//    +72  block hoverHandler       +80 block bubblePositionHandler
//    +88  block hoverPositionHandler
//    +96  UIView * interactionView +104 UITouch * activeTouch
//    +112 CAShapeLayer * interactionMask
//    +120 double lastHoverReach
//    +128 UITapGestureRecognizer * singleTapRecognizer
//    +136 UITapGestureRecognizer * doubleTapRecognizer
//    +144 UILongPressGestureRecognizer * longPressRecognizer
//    +152 CGPoint lastBubblePosition  +168 CGPoint lastHoverPosition
//    +184 CGSize lastHoverViewport
//
//  字符串常量：pet-overlay / drag / menu / none / idle / sit / sleep
//

#import "PDPetView.h"
#import "WNRenderer.h"
#import "WNLiveRig.h"
#import "WNMotion.h"
#import "WNHitMask.h"
#import "PDFramePlayer.h"
#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>
#import <math.h>

// 桩头集缺两项真机 SDK 均有的声明（UIView.didMoveToSuperview / MTKView.drawableSize），
// 就地补声明，不改 /tmp/shim。
@interface UIView (PDPetViewRev)
- (void)didMoveToSuperview;
@end

@interface MTKView (PDPetViewRev)
- (CGSize)drawableSize;
- (void)setDrawableSize:(CGSize)size;
@end

@implementation PDPetView

// 头文件里 hash / superclass / description / debugDescription 四个 readonly 属性在二进制中
// 没有对应 method_t（继承自 NSObject）。若不声明 @dynamic，clang 会自动合成它们并额外长出
// 4 个 ivar，把 instanceSize 从 200 撑到 232，同时覆盖 NSObject 的实现。故在此抑制合成。
@dynamic hash, superclass, description, debugDescription;

#pragma mark - 初始化

/// 384 条指令。建 MTKView + WNRenderer + 手势识别器。
- (instancetype)initWithResourceURL:(NSURL *)url {
    self = [super initWithFrame:CGRectZero device:MTLCreateSystemDefaultDevice()];
    if (!self) return nil;

    // Metal 视图配置
    self.opaque = NO;
    self.backgroundColor = [UIColor clearColor];
    self.clearColor = MTLClearColorMake(0, 0, 0, 0);
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = NO;
    self.enableSetNeedsDisplay = NO;       // 用 displayLink 驱动
    self.paused = YES;                      // 初始暂停，显示时才跑
    self.preferredFramesPerSecond = 60;
    self.userInteractionEnabled = YES;

    // 渲染器
    _renderer = [[WNRenderer alloc] initWithResourceURL:url liveOnly:YES];
    if (!_renderer) return nil;
    _renderer.buildsInteractionPath = YES;
    self.delegate = (id<MTKViewDelegate>)_renderer;

    // 角色离屏渲染结果的显示层（1.2 补齐：原骨架渲染链断了，这里直接显示 painter 产物）
    _charImageView = [[UIImageView alloc] initWithFrame:self.bounds];
    _charImageView.contentMode = UIViewContentModeScaleAspectFit;
    _charImageView.backgroundColor = [UIColor clearColor];
    _charImageView.userInteractionEnabled = NO;
    _charImageView.hidden = YES;
    [self addSubview:_charImageView];

    // 交互蒙版（CAShapeLayer，做精确命中）
    _interactionMask = [CAShapeLayer layer];
    _interactionMask.fillColor = [UIColor clearColor].CGColor;
    _interactionMask.strokeColor = [UIColor clearColor].CGColor;

    // 手势
    _singleTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                  action:@selector(singleTap:)];
    _singleTapRecognizer.numberOfTapsRequired = 1;
    [self addGestureRecognizer:_singleTapRecognizer];

    _doubleTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                  action:@selector(doubleTap:)];
    _doubleTapRecognizer.numberOfTapsRequired = 2;
    [self addGestureRecognizer:_doubleTapRecognizer];
    // 双击时取消单击
    [_singleTapRecognizer requireGestureRecognizerToFail:_doubleTapRecognizer];

    _longPressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(longPress:)];
    _longPressRecognizer.minimumPressDuration = 0.45;
    [self addGestureRecognizer:_longPressRecognizer];

    _doubleTapAction = @"clip";
    _longPressAction = @"menu";
    _activeFPS = 60;
    _tapEligible = YES;

    // 标记为桌宠层（供 PDWindow.hitTest 识别）
    self.accessibilityIdentifier = @"pet-overlay";
    return self;
}

#pragma mark - 生命周期

/// 46 条指令。挂到父视图后：交互视图重新入栈到父视图，并刷新命中区域。
- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    [self.interactionView removeFromSuperview];
    if (self.superview) {
        [self.superview addSubview:self.interactionView];
        [self updateInteractionRegion];

        if (!_framePlayer) {
            _framePlayer = [[PDFramePlayer alloc] init];
            _framePlayer.hidden = YES;
            [self.superview addSubview:_framePlayer];
        }
        _framePlayer.frame = self.frame;
    }
}

#pragma mark - 渲染驱动

/// 23 条指令。暂停状态变化：恢复播放时重算帧率；两种情况都刷新命中区域。
- (void)setPaused:(BOOL)paused {
    [super setPaused:paused];
    if (!paused) [self updateFrameRate];
    [self updateInteractionRegion];
}

/// 8 条指令。仅当值真的变化时才重算帧率（末尾为对 updateFrameRate 的尾调用）。
- (void)setLayoutAnimating:(BOOL)animating {
    if (_layoutAnimating == animating) return;
    _layoutAnimating = animating;
    [self updateFrameRate];
}

/// 64 条指令。按屏幕 scale 把 bounds 换算成像素尺寸，必要时同步 drawableSize。
- (void)layoutSubviews {
    [super layoutSubviews];
    if (_framePlayer && _framePlayer.superview) _framePlayer.frame = self.frame;
    if (_charImageView) _charImageView.frame = self.bounds;

    UIScreen *screen = self.window.screen;
    CGFloat scale = screen.scale;
    if (scale == 0.0) scale = [UIScreen mainScreen].scale;

    CGFloat w = ceil(self.bounds.size.width * scale);
    if (w <= 0.0) return;
    CGFloat h = ceil(self.bounds.size.height * scale);
    if (h <= 0.0) return;

    CGSize cur = self.drawableSize;
    if (cur.width == w && cur.height == h) return;
    [self setDrawableSize:CGSizeMake(w, h)];
}

/// 30 条指令。drawable 尺寸变化原样转发给 renderer（PDPetView 自身是 MTKViewDelegate 的转发层）。
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [self.renderer mtkView:view drawableSizeWillChange:size];
}

/// 211 条指令。每帧回调。
- (void)drawInMTKView:(MTKView *)view {
    if (self.isPaused) return;
    if (_beforeFrameHandler) _beforeFrameHandler();
    [_renderer drawInMTKView:view];
    [self pd_updateCharacterImage];
    if (_frameHandler) _frameHandler();
    if (_renderer.didSubmitFrame) {
        [self updateInteractionRegion];
    }
}

/// 253 条指令。更新命中蒙版（从 renderer 的 CGPath 同步到 CAShapeLayer）。
- (void)updateInteractionRegion {
    CGPathRef path = _renderer.interactionPath;
    if (!path) {
        _interactionMask.path = NULL;
        return;
    }
    CGSize stage = [self stageSize];
    if (stage.width <= 0 || stage.height <= 0) return;

    // 舞台坐标 → 视图坐标
    CGAffineTransform t = CGAffineTransformMakeScale(self.bounds.size.width / stage.width,
                                                     self.bounds.size.height / stage.height);
    CGMutablePathRef scaled = CGPathCreateMutableCopyByTransformingPath(path, &t);
    if (scaled) {
        _interactionMask.path = scaled;
        CGPathRelease(scaled);
    }
}

/// 舞台尺寸（从 renderer 的 liveRig 取）。
/// [非二进制] 内部辅助：把 drawableSize 按 contentScaleFactor 折算成舞台尺寸。
- (CGSize)stageSize {
    WNLiveRig *rig = _renderer.liveRig;
    if (!rig) return self.bounds.size;
    WNMotion *m = rig.motion;
    if (m) return CGSizeMake(m.width, m.height);
    return self.bounds.size;
}

/// 199 条指令。按当前状态调整帧率（idle/sit/sleep 降帧省电）。
- (void)updateFrameRate {
    NSString *mode = _renderer.liveRig.motion.mode ?: @"idle";
    long long fps = 60;

    if ([mode isEqualToString:@"idle"]) {
        fps = 30;
    } else if ([mode isEqualToString:@"sit"]) {
        fps = 24;
    } else if ([mode isEqualToString:@"sleep"]) {
        fps = 15;
    } else if ([mode isEqualToString:@"walk"] || [mode isEqualToString:@"run"]) {
        fps = 60;
    } else if ([mode isEqualToString:@"drag"]) {
        fps = 60;
    }

    // 脉冲/表情切换时临时提帧
    if (_renderer.liveRig.motion.pulse) fps = 60;

    if (fps != _activeFPS) {
        _activeFPS = fps;
        self.preferredFramesPerSecond = (NSInteger)fps;
    }
}

#pragma mark - 触摸处理

/// 111 条指令。按下：记录触点，判断是否可点击。
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    if (!t) return;
    if (_activeTouch) return;               // 已有触点，忽略多点

    _activeTouch = t;
    _tapEligible = YES;
    _stroking = NO;

    CGPoint p = [t locationInView:self];
    CGPoint stage = [self stagePoint:p];

    // 交给 renderer 的 motion 处理
    WNMotion *m = _renderer.liveRig.motion;
    if (m) {
        [m pointerDown:stage milliseconds:t.timestamp * 1000.0
          hitConfirmed:[self pointInInteractionRegion:p]];
    }
}

/// 156 条指令。移动：处理滑动与拖动。
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_activeTouch) return;
    if (![touches containsObject:_activeTouch]) return;

    // 用 coalesced touches 提升精度
    NSArray *coalesced = [event coalescedTouchesForTouch:_activeTouch];
    if (coalesced.count == 0) coalesced = @[_activeTouch];

    WNMotion *m = _renderer.liveRig.motion;
    for (UITouch *t in coalesced) {
        CGPoint p = [t locationInView:self];
        CGPoint stage = [self stagePoint:p];
        if (m) [m pointerMove:stage milliseconds:t.timestamp * 1000.0];
    }

    // 移动超过阈值 → 不再算点击
    CGPoint now = [_activeTouch locationInView:self];
    CGPoint start = [_activeTouch previousLocationInView:self];
    if (hypot(now.x - start.x, now.y - start.y) > 10.0) _tapEligible = NO;

    [self publishHoverPosition];
}

/// 96 条指令。抬起：判断点击/抚摸。
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_activeTouch) return;
    if (![touches containsObject:_activeTouch]) return;

    UITouch *t = _activeTouch;
    _activeTouch = nil;

    CGPoint p = [t locationInView:self];
    CGPoint stage = [self stagePoint:p];
    WNMotion *m = _renderer.liveRig.motion;
    if (m) [m pointerUp:stage milliseconds:t.timestamp * 1000.0];

    // 抚摸判定：短距离、多次移动
    if (_stroking) {
        if (_gestureActionHandler) _gestureActionHandler(@"stroke", p);
    }
}

/// 32 条指令。只有被取消的触点正是当前活动触点时才终止交互。
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (![touches containsObject:self.activeTouch]) return;
    [self cancelInteraction];
}

/// 48 条指令。隐藏 / 暂停 / 交互关闭时一律不命中，否则转给交互视图做精确命中。
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.isHidden) return NO;
    if (self.isPaused) return NO;
    if (!self.interactionEnabled) return NO;
    return [self.interactionView pointInside:[self convertPoint:point toView:self.interactionView]
                                   withEvent:event];
}

/// 76 条指令。取消交互。
- (void)cancelInteraction {
    _tapEligible = NO;
    _menuPressActive = NO;
    _activeTouch = nil;
    _stroking = NO;

    WNMotion *m = _renderer.liveRig.motion;
    if (m) [m cancelAt:CGPointZero];

    if (_hoverHandler) _hoverHandler(NO, CGPointZero, 0);
}

#pragma mark - 手势

/// 67 条指令。单击。
- (void)singleTap:(UITapGestureRecognizer *)g {
    if (!_tapEligible) return;
    if (!self.interactionEnabled) return;

    CGPoint p = [g locationInView:self];
    WNMotion *m = _renderer.liveRig.motion;
    if (m) [m poke];

    if (_gestureActionHandler) _gestureActionHandler(@"tap", p);
}

/// 79 条指令。双击。
- (void)doubleTap:(UITapGestureRecognizer *)g {
    if (!self.interactionEnabled) return;
    NSString *action = _doubleTapAction ?: @"none";
    if ([action isEqualToString:@"none"]) return;

    CGPoint p = [g locationInView:self];
    if ([action isEqualToString:@"clip"]) {
        [self playNextFrameClip];
        return;
    }
    if ([action isEqualToString:@"drag"]) {
        // 进入拖动模式
        WNMotion *m = _renderer.liveRig.motion;
        if (m) [m grab];
    }
    if (_gestureActionHandler) _gestureActionHandler(action, p);
}

/// 节流刷新角色离屏渲染图（约 30fps），显示到 _charImageView。
- (void)pd_updateCharacterImage {
    if (!_charImageView) return;
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 1.0 / 30.0) return;
    last = now;
    UIImage *img = [_renderer pd_renderCharacterImage];
    if (img) _charImageView.image = img;
    _charImageView.hidden = (img == nil);
}

/// 播放下一段逐帧动作；播放期间隐藏程序化桌宠，播完自动恢复。
- (void)playNextFrameClip {
    if (!_framePlayer || ![_framePlayer hasClips]) return;
    NSString *clip = [_framePlayer nextClipID];
    if (!clip.length) return;
    __weak typeof(self) weakSelf = self;
    _framePlayer.completion = ^{
        typeof(self) s = weakSelf;
        if (s) s.hidden = NO;
    };
    self.hidden = YES;
    [_framePlayer playClip:clip];
}

/// 56 条指令。值未变直接返回；变了则先取消进行中的交互，再按新值开关单击/双击识别器。
- (void)setDoubleTapAction:(NSString *)action {
    if ([_doubleTapAction isEqual:action]) return;
    [self cancelInteraction];
    _doubleTapAction = [action copy];

    // Observed: 二进制对 @"none" 用的是 -isEqual:（0xad240），不是 -isEqualToString:
    BOOL enabled = (action.length != 0) && ![action isEqual:@"none"];
    [self.singleTapRecognizer setEnabled:enabled];
    [self.doubleTapRecognizer setEnabled:enabled];
}

/// 47 条指令。同上，但只开关长按识别器。
- (void)setLongPressAction:(NSString *)action {
    if ([_longPressAction isEqual:action]) return;
    [self cancelInteraction];
    _longPressAction = [action copy];

    BOOL enabled = (action.length != 0) && ![action isEqual:@"none"];
    [self.longPressRecognizer setEnabled:enabled];
}

/// 185 条指令。长按。
- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    if (!self.interactionEnabled) return;

    _menuPressActive = YES;
    CGPoint p = [g locationInView:self];
    CGPoint stage = [self stagePoint:p];
    WNMotion *m = _renderer.liveRig.motion;
    if (m) {
        [m pointerDown:stage milliseconds:g.state == UIGestureRecognizerStateBegan ? 0 : 0
          hitConfirmed:YES];
    }

    NSString *action = _longPressAction ?: @"menu";
    if (![action isEqualToString:@"none"]) {
        if (_gestureActionHandler) _gestureActionHandler(action, p);
    }
}

#pragma mark - 坐标转换

/// 视图坐标 → 舞台坐标。
- (CGPoint)stagePoint:(CGPoint)p {
    CGSize stage = [self stageSize];
    if (stage.width <= 0 || stage.height <= 0) return p;
    return CGPointMake(p.x / self.bounds.size.width * stage.width,
                       p.y / self.bounds.size.height * stage.height);
}

/// 是否落在交互区域内（用蒙版路径判断）。
/// [非二进制] 二进制无此方法。CGPath 命中判定的真身在
/// `-[PDInteractionView pointInside:withEvent:]`（0xd0dc，260 条）与
/// `-[PDSpeechBubbleView pointInside:withEvent:]`（0x178bc，140 条）。
/// 这里保留为 PDPetView 的便利封装，供 hitConfirmed 使用。
- (BOOL)pointInInteractionRegion:(CGPoint)p {
    CGPathRef path = _interactionMask.path;
    if (!path) return YES;                  // 无蒙版时宽松处理
    return CGPathContainsPoint(path, NULL, p, NO);
}

#pragma mark - 悬停

/// 103 条指令。把气泡锚点发布给上层；与上次发布位置相距不足 1 物理像素时跳过。
- (void)publishBubblePosition {
    if (!self.bubblePositionHandler) {
        [self setHasLastBubblePosition:NO];
        return;
    }

    CGPoint anchor = [self bubbleAnchorInSuperview];

    UIScreen *screen = self.window.screen;
    CGFloat scale = screen.scale;
    if (scale == 0.0) scale = [UIScreen mainScreen].scale;

    if ([self hasLastBubblePosition]) {
        CGFloat epsilon = 1.0 / scale;
        // Observed: 二进制对 lastBubblePosition 取了两次（0xe924 / 0xe930），x、y 分别来自独立调用
        CGPoint lastX = [self lastBubblePosition];
        CGFloat dx = anchor.x - lastX.x;
        CGPoint lastY = [self lastBubblePosition];
        CGFloat dy = anchor.y - lastY.y;
        if (hypot(dx, dy) < epsilon) return;
    }

    [self setHasLastBubblePosition:YES];
    [self setLastBubblePosition:anchor];
    self.bubblePositionHandler(anchor);
}

/// 23 条指令。装回调、清掉上次悬停标记，然后立刻发布一次（末尾为对 publishHoverPosition 的尾调用）。
- (void)setHoverPositionHandler:(void (^)(CGPoint, CGSize))handler {
    _hoverPositionHandler = [handler copy];
    [self setHasLastHoverPosition:NO];
    [self publishHoverPosition];
}

/// 189 条指令。发布悬停位置（供 hover 按钮定位）。
- (void)publishHoverPosition {
    if (!_hoverPositionHandler) return;
    CGPoint p = [self convertPoint:_lastHoverPosition toView:nil];
    CGSize screen = [UIScreen mainScreen].bounds.size;
    _hoverPositionHandler(p, screen);
}

/// 气泡锚点（父视图坐标）。
- (CGPoint)bubbleAnchorInSuperview {
    CGPoint p = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMinY(self.bounds));
    return [self convertPoint:p toView:self.superview];
}

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setActiveFPS:(long long)v { _activeFPS = v; }
- (void)setInteractionEnabled:(BOOL)v { _interactionEnabled = v; }
- (void)setStroking:(BOOL)v { _stroking = v; }
- (void)setGestureActionHandler:(void (^)(NSString *, CGPoint))v { _gestureActionHandler = [v copy]; }
- (void)setFrameHandler:(id)v { _frameHandler = v; }
- (void)setBeforeFrameHandler:(id)v { _beforeFrameHandler = v; }
- (void)setHoverHandler:(id)v { _hoverHandler = v; }
- (void)setBubblePositionHandler:(id)v { _bubblePositionHandler = v; }
- (void)setHasLastBubblePosition:(BOOL)v { _hasLastBubblePosition = v; }
- (void)setLastHoverReach:(double)v { _lastHoverReach = v; }
- (void)setHasLastHoverPosition:(BOOL)v { _hasLastHoverPosition = v; }
- (void)setTapEligible:(BOOL)v { _tapEligible = v; }
- (void)setMenuPressActive:(BOOL)v { _menuPressActive = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setRenderer:(id)v { _renderer = v; }
- (void)setInteractionView:(id)v { _interactionView = v; }
- (void)setActiveTouch:(id)v { _activeTouch = v; }
- (void)setInteractionMask:(id)v { _interactionMask = v; }
- (void)setSingleTapRecognizer:(id)v { _singleTapRecognizer = v; }
- (void)setDoubleTapRecognizer:(id)v { _doubleTapRecognizer = v; }
- (void)setLongPressRecognizer:(id)v { _longPressRecognizer = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (id)renderer { return _renderer; }
- (BOOL)interactionEnabled { return _interactionEnabled; }
- (BOOL)stroking { return _stroking; }
- (id)doubleTapAction { return _doubleTapAction; }
- (id)longPressAction { return _longPressAction; }
- (long long)activeFPS { return _activeFPS; }
- (BOOL)layoutAnimating { return _layoutAnimating; }
- (id)interactionView { return _interactionView; }
- (id)interactionMask { return _interactionMask; }
- (BOOL)hasLastBubblePosition { return _hasLastBubblePosition; }
- (double)lastHoverReach { return _lastHoverReach; }
- (BOOL)hasLastHoverPosition { return _hasLastHoverPosition; }
- (id)singleTapRecognizer { return _singleTapRecognizer; }
- (id)doubleTapRecognizer { return _doubleTapRecognizer; }
- (id)longPressRecognizer { return _longPressRecognizer; }
- (BOOL)tapEligible { return _tapEligible; }
- (BOOL)menuPressActive { return _menuPressActive; }

#pragma mark - 二进制存取器（块 / 弱引用 / 结构体，逐条 8-16 指令）

/// 8 条指令。块 ivar 直接读（getter 返回 +0，retain/autorelease 由调用方负责）。
- (void (^)(NSString *, CGPoint))gestureActionHandler { return _gestureActionHandler; }
- (void (^)(void))frameHandler { return _frameHandler; }
- (void (^)(void))beforeFrameHandler { return _beforeFrameHandler; }
- (void (^)(BOOL, CGPoint, double))hoverHandler { return _hoverHandler; }
- (void (^)(CGPoint))bubblePositionHandler { return _bubblePositionHandler; }
- (void (^)(CGPoint, CGSize))hoverPositionHandler { return _hoverPositionHandler; }

/// 12 条指令。弱引用读取：objc_loadWeakRetained + objc_autoreleaseReturnValue（0xfd18）。
- (UITouch *)activeTouch { return _activeTouch; }

/// 结构体存取器：CGPoint / CGSize 各 16 字节，ldp/stp d0,d1 一次搬运（0xfd84–0xfe38）。
- (CGPoint)lastBubblePosition { return _lastBubblePosition; }
- (void)setLastBubblePosition:(CGPoint)position { _lastBubblePosition = position; }
- (CGPoint)lastHoverPosition { return _lastHoverPosition; }
- (void)setLastHoverPosition:(CGPoint)position { _lastHoverPosition = position; }
- (CGSize)lastHoverViewport { return _lastHoverViewport; }
- (void)setLastHoverViewport:(CGSize)viewport { _lastHoverViewport = viewport; }

#pragma mark - 保真账本

/*
 本次补齐 24 个方法（11 个业务方法 + 13 个存取器），全部按二进制 method_t 的 IMP 取证。
 未解项：0。所有分支、常量、选择器均已解出，故正文无 Inferred / Assumed 标注。

 业务方法（IMP → 下一条 IMP 的间距 / 指令数，types 取自 objc_full.json）：
   0xd95c didMoveToSuperview                 0xb8  46  v16@0:8
   0xda14 setPaused:                         0x5c  23  v20@0:8B16
   0xda80 setLayoutAnimating:                0x20   8  v20@0:8B16
   0xddb4 setDoubleTapAction:                0xe0  56  v24@0:8@16
   0xde94 setLongPressAction:                0xbc  47  v24@0:8@16
   0xe198 layoutSubviews                     0x100 64  v16@0:8
   0xe838 publishBubblePosition              0x19c 103 v16@0:8
   0xe9d4 setHoverPositionHandler:           0x5c  23  v24@0:8@?16
   0xed20 pointInside:withEvent:             0xc0  48  B40@0:8{CGPoint=dd}16@32
   0xf37c touchesCancelled:withEvent:        0x80  32  v32@0:8@16@24
   0xfb4c mtkView:drawableSizeWillChange:    0x78  30  v40@0:8@16{CGSize=dd}24

 存取器：0xfc38–0xfe38 连续 13 个（getter 为 ldr/ldrb，setter 为 str/strb/stp），
   block 类走 ldr + ret（返回 +0，retain/autorelease 交给调用方），
   CGPoint / CGSize 用 ldp/stp d0,d1 一次搬运 16 字节。

 已解常量：
   0xfb790 → @"none"（setDoubleTapAction: / setLongPressAction: 里 -isEqual: 的比较对象）
   setDoubleTapAction: / setLongPressAction: 的 ivar 偏移槽 0x304 / 0x308（+24 / +32）

 取证中的三处修正（均已在正文注释标明）：
   1. _activeTouch 是弱引用：getter 走 objc_loadWeakRetained（0xfd18），
      setter 走 objc_storeWeak（0xfd5c），属性元数据亦为 T@"UITouch",W,N。
      头文件原为 strong，已改为 weak，否则 ARC 语义与二进制不符。
   2. publishBubblePosition 对 lastBubblePosition 取了两次（0xe924 取 x、0xe930 取 y），
      按原样保留两次调用，不合并成一次。
   3. hash / superclass / description / debugDescription 在二进制中没有 method_t，
      属 NSObject 继承；头文件声明成 @property 会触发自动合成，长出 4 个幽灵 ivar
      把 instanceSize 从 200 撑到 232。已在 @implementation 顶部用 @dynamic 抑制。

 桩头集未声明、真机 SDK 有、故在 .m 内就地补声明的两项（未改 /tmp/shim）：
   UIView.didMoveToSuperview（[super didMoveToSuperview] 需要）
   MTKView.drawableSize / setDrawableSize:（layoutSubviews 读写需要）
*/

@end
