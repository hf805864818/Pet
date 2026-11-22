//
//  WNMotion+Input.m — 逆向还原：输入、事件、音效、快照
//
//  还原依据：PetDFY.dylib arm64e，18 个方法共 3131 条指令
//
//  字典键（从 CFString 引用提取）：
//    event:detail:      {kind, time}
//    sound:kind:args:   {name, kind, arguments}
//    snapshot           {_fname, expr, exprUntil, faceVis, facing, fy, gvy,
//                        feet, blinkT, blinkAge, ...}
//    velocity           {t, x, y}
//    emit:...           {type, x, y, vx, vy, life, age}
//

#import "WNMotion.h"
#import <math.h>

@implementation WNMotion (Input)

#pragma mark - 初始化

/// 反汇编 142 条指令，纯计算。字符串常量：idle / jump / neutral / off
- (instancetype)initWithSeed:(uint32_t)seed freeGround:(BOOL)free {
    self = [super init];
    if (!self) return nil;
    randomState = seed ? seed : 1;
    freeGround = free;
    time = 0;
    scale = 1.0;
    _mode = @"idle";
    _faceName = @"neutral";
    _expression = @"";
    _airKind = @"";
    _roamMode = free ? @"free" : @"off";
    _events = [NSMutableArray array];
    _particles = [NSMutableArray array];
    _samples = [NSMutableArray array];
    _soundEvents = [NSMutableArray array];
    _eyeCur = @(1.0);
    _eyePrev = @(1.0);
    p.blinkT = 3.0;
    p.blinkAge = 0;
    return self;
}

#pragma mark - 事件与音效队列

/// 追加一条事件。字典键：kind / time
- (void)event:(NSString *)kind detail:(NSDictionary *)detail {
    if (!kind.length) return;
    NSMutableDictionary *e = [@{@"kind": kind, @"time": @(time)} mutableCopy];
    if ([detail isKindOfClass:[NSDictionary class]]) {
        [e addEntriesFromDictionary:detail];
    }
    if (!_events) _events = [NSMutableArray array];
    [_events addObject:e];
    // 队列上限，防止无限增长
    while (_events.count > 256) [_events removeObjectAtIndex:0];
}

/// 追加一条音效。字典键：name / kind / arguments
- (void)sound:(NSString *)name kind:(NSString *)kind arguments:(id)args {
    if (!name.length) return;
    NSMutableDictionary *s = [@{@"name": name,
                                @"kind": kind ?: @"sfx"} mutableCopy];
    if (args) s[@"arguments"] = args;
    if (!_soundEvents) _soundEvents = [NSMutableArray array];
    [_soundEvents addObject:s];
    while (_soundEvents.count > 64) [_soundEvents removeObjectAtIndex:0];
}

#pragma mark - 粒子

/// 发射一个粒子。字段：type / x / y / vx / vy / life / age
- (void)emit:(NSString *)type point:(CGPoint)pt vx:(double)vx vy:(double)vy life:(double)life {
    if (!_particles) _particles = [NSMutableArray array];
    [_particles addObject:@{@"type": type ?: @"dust",
                            @"x": @(pt.x), @"y": @(pt.y),
                            @"vx": @(vx), @"vy": @(vy),
                            @"life": @(life), @"age": @(0.0)}];
    while (_particles.count > 200) [_particles removeObjectAtIndex:0];
}

/// 扬尘：在角色脚下随机撒 N 个粒子
- (void)dust:(double)amount spread:(double)spread {
    int n = (int)MAX(1, MIN(12, amount * 4));
    for (int i = 0; i < n; i++) {
        double dx = [self rnd:-spread to:spread];
        double dy = [self rnd:-spread * 0.5 to:0];
        [self emit:@"dust"
              point:CGPointMake(p.x, p.fy)
                 vx:dx vy:dy life:[self rnd:0.3 to:0.7]];
    }
}

/// 爱心：向上飘
- (void)emitHeart {
    [self emit:@"heart"
          point:CGPointMake(p.x, p.gy + 40)
             vx:[self rnd:-20 to:20] vy:[self rnd:60 to:100] life:1.2];
}

#pragma mark - 指针采样与速度

/// 记录一次指针采样。字段：t / x / y
- (void)samplePointer:(CGPoint)pt milliseconds:(double)ms {
    if (!_samples) _samples = [NSMutableArray array];
    [_samples addObject:@{@"t": @(ms), @"x": @(pt.x), @"y": @(pt.y)}];
    // 只保留最近 200ms 的样本
    while (_samples.count > 2) {
        NSDictionary *first = _samples.firstObject;
        if (ms - [first[@"t"] doubleValue] <= 200.0) break;
        [_samples removeObjectAtIndex:0];
    }
    _lastPointerTime = ms;
}

/// 当前指针速度（像素/秒），由首尾样本差分得到。
- (CGPoint)velocity {
    if (_samples.count < 2) return CGPointZero;
    NSDictionary *a = _samples.firstObject;
    NSDictionary *b = _samples.lastObject;
    double dt = ([b[@"t"] doubleValue] - [a[@"t"] doubleValue]) / 1000.0;
    if (dt <= 0.0001) return CGPointZero;
    return CGPointMake(([b[@"x"] doubleValue] - [a[@"x"] doubleValue]) / dt,
                       ([b[@"y"] doubleValue] - [a[@"y"] doubleValue]) / dt);
}

#pragma mark - 指针事件

- (void)pointerDown:(CGPoint)pt milliseconds:(double)ms hitConfirmed:(BOOL)confirmed {
    [self samplePointer:pt milliseconds:ms];
    _samples = [@[@{@"t": @(ms), @"x": @(pt.x), @"y": @(pt.y)}] mutableCopy];
    _lastPointerTime = ms;
    pressX = pt.x;
    pressY = pt.y;
    pressT = ms;
    pressing = YES;
    _responsiveInteraction = YES;
    if (confirmed) [self grab];
}

- (void)pointerMove:(CGPoint)pt milliseconds:(double)ms {
    [self samplePointer:pt milliseconds:ms];
    if (!pressing) return;
    CGPoint v = [self velocity];
    pointerVX = v.x;
    pointerX = pt.x;
    pointerY = pt.y;
}

- (void)pointerUp:(CGPoint)pt milliseconds:(double)ms {
    [self samplePointer:pt milliseconds:ms];
    pressing = NO;
    CGPoint v = [self velocity];
    // 快速甩动触发抛掷
    double speed = hypot(v.x, v.y);
    if (speed > 800.0) {
        p.vx = v.x * 0.15;
        p.gvy = MAX(v.y * 0.15, 200.0);
        [self sound:@"throw" kind:@"sfx" arguments:nil];
        [self event:@"throw" detail:@{@"speed": @(speed)}];
    }
    _samples = [NSMutableArray array];
}

/// 取消当前手势（指针离开有效区域）
- (void)cancelAt:(CGPoint)pt {
    pressing = NO;
    _samples = [NSMutableArray array];
    [self event:@"cancel" detail:@{@"x": @(pt.x), @"y": @(pt.y)}];
}

#pragma mark - 动作

/// 戳一下
- (void)poke {
    if (time < petCool) return;         // 冷却
    petCool = time + 0.25;
    [self sound:@"poke" kind:@"sfx" arguments:nil];
    [self event:@"poke" detail:nil];
    [self setExpr:@"surprised" seconds:0.5];
    p.sqv = 6.0;                        // 挤压回弹
}

/// 抓取（开始拖动）
- (void)grab {
    _mode = @"drag";
    p.speed = 0;
    [self event:@"grab" detail:nil];
}

/// 行走。168 条指令
- (void)walkTo:(double)targetX run:(BOOL)run identifier:(NSString *)ident {
    if (ident.length && [_walkIdentifier isEqualToString:ident]) return;
    _walkIdentifier = [ident copy];
    _walkWord = nil;
    p.target = MAX([self minX], MIN([self maxX], targetX));
    p.speed  = run ? 320.0 : 120.0;
    p.stride = run ? 1.6 : 1.0;
    _mode = run ? @"run" : @"walk";
    [self event:@"walk" detail:@{@"target": @(p.target), @"run": @(run)}];
}

/// 说话气泡 / doWord: 见 WNMotion+Word.m（BOOL 返回，与头文件一致）
/// 切换模式。212 条指令
- (void)setModeTo:(NSString *)mode {
    if (!mode.length || [_mode isEqualToString:mode]) return;
    // 离开旧模式时的清理
    if ([_mode isEqualToString:@"walk"] || [_mode isEqualToString:@"run"]) {
        _walkIdentifier = nil;
        _walkWord = nil;
        [self event:@"walkEnd" detail:nil];
    }
    _mode = [mode copy];
    p.modeT = 0;
    [self event:@"mode" detail:@{@"to": mode}];
    if ([mode isEqualToString:@"jump"]) {
        [self sound:@"jump" kind:@"sfx" arguments:nil];
    }
}

#pragma mark - 状态快照

/// 导出当前完整状态（调试/序列化用）。414 条指令
- (NSDictionary *)snapshot {
    return @{
        @"_fname": _faceName ?: @"neutral",
        @"expr": _expression ?: @"",
        @"exprUntil": @(p.exprUntil),
        @"faceVis": @(p.faceVis),
        @"facing": @(p.facing),
        @"fy": @(p.fy),
        @"gvy": @(p.gvy),
        @"feet": @[@(p.feet[0][0]), @(p.feet[0][1]),
                   @(p.feet[1][0]), @(p.feet[1][1])],
        @"blinkT": @(p.blinkT),
        @"blinkAge": @(p.blinkAge),
        @"x": @(p.x),
        @"gy": @(p.gy),
        @"mode": _mode ?: @"idle",
        @"roam": _roamMode ?: @"free",
    };
}

@end
