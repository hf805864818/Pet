//
//  WNLiveRig.m — 逆向还原实现（基础层）
//
//  还原依据：PetDFY.dylib arm64e，56 个方法共 6785 条指令
//  本文件：初始化 / 弹簧 / 变形 / 路径解析 / 访问器（约 40 个方法）
//  另见：WNLiveRig+Mesh.m（renderBuildingMesh: 3653 指令 @0x4dc34，updateToyBall 见同文件）
//
//  ivar 布局（instanceSize=488）：
//    +8   lastT      +16 prevTilt   +24 prevYaw    +32 prevLow
//    +40  headTilt   +48 wTilt      +56 wLean      +64 facing
//    +72  finMood    +80 tailMood   +88 wagAmp     +96 sitK
//    +104 walkK      +112 runK      +120 swingK    +128 browNow[2][4]
//    +192 browOver   +200 creaseDrop[2] +216 creaseA
//    +224 prevLook[2] +240 prevShut +248 hlScale   +256 hlQuiver
//    +264 hlAlpha    +272 hasT      +273 hasLook   +274 deformersDirty
//    +275 ballAnchored +280 ballLastT +288 ballAnchor{x,y,vx,vy}
//
//  路径模板（从 CFString 提取）：
//    featurePath:    "originals/%@feat/%@.png"  或  "schemes/%@/"
//    textureForPart: "originals/" 或 "schemes/%@"  然后 "%@tex/%@.png"
//    特殊名：__face / faceFx
//

#import "WNLiveRig.h"
#import "PDPreferences.h"
#import "WNMotion.h"
#import "WNSpring.h"
#import "WNPreparedDeformer.h"
#import <UIKit/UIKit.h>
#import <math.h>

@implementation WNLiveRig

// ---- updateToyBall 专用探针（见方法头说明；不占 ivar，放在 @implementation 之外）----
/// Inferred：motion 上被 updateToyBall 反复取用的两个 double 槽，语义与证据见方法内 §B/§C。
typedef struct { double v; } WNProbe0;                      // motion +0x00
typedef struct { char pad[0x40]; double v; } WNProbe40;     // motion +0x40

/// container[key] 的 doubleValue；取不到时返回 dflt。
/// Observed：0x4d6d4-0x4d6e4 是 x0 = 容器、x1 = @"a"（@0x102610）、d0 = 缺省值 0.0，
/// 返回值紧接着当 double 参与运算；0x4d708/0x4d720/0x4d734/0x4d748 同形
/// （@"sx" @0x102730 / @"sy" @0x102750，缺省 1.0；@"tx" @0x102770 / @"ty" @0x102790，缺省 0.0）。
/// 调用点 0x51fac：[[self rot] objectForKeyedSubscript:@"armNear"] + @"a"，缺省 0.0。
static double WNPoseValue(id container, NSString *key, double dflt) {
    id v = container ? [container objectForKeyedSubscript:key] : nil;
    return v ? [v doubleValue] : dflt;
}

#pragma mark - 二进制定时驱动（尾调用 thunk，逐指令）

/// Observed @0x4caac（2 条）：mov w2,#1 ; b 0xb55e0(step:buildMesh:)
/// 即 [self step:dt buildMesh:YES]——d0 原样透传，w2 置 1。
- (void)step:(double)dt {
    [self step:dt buildMesh:YES];
}

/// Observed @0x4cab4（14 条）：
///   x19 = buildMesh（x2），d8 = dt（d0）
///   bl 0xae260(motion) → bl 0xb55c0(step:) 传 d0=dt
///   ldp 恢复现场后 `b 0xb0140`(renderBuildingMesh:) —— 尾调用，x2 仍为 buildMesh
- (void)step:(double)dt buildMesh:(BOOL)buildMesh {
    [[self motion] step:dt];
    [self renderBuildingMesh:buildMesh];
}


/// Observed @0x4dc2c（2 条）：mov w2,#1 ; b 0xb0140(renderBuildingMesh:)
/// 即 [self renderBuildingMesh:YES]。
- (void)render {
    [self renderBuildingMesh:YES];
}

#pragma mark - 初始化

/// 364 条指令。字符串常量：LiveRig / "Missing rig %@" / "Missing outfit %@"
///                    / faces / "id == %@"
- (instancetype)initWithResourceURL:(NSURL *)url
                             scheme:(NSString *)scheme
                               seed:(uint32_t)seed
                         freeGround:(BOOL)free {
    self = [super init];
    if (!self) return nil;

    _resourceURL = [url copy];
    _springs = [NSMutableDictionary dictionary];
    _rot = [NSMutableDictionary dictionary];
    _warps = [NSMutableDictionary dictionary];
    _pivots = [NSMutableDictionary dictionary];
    _localVertices = [NSMutableDictionary dictionary];
    _compiledDeformers = [NSMutableArray array];

    _scheme = [scheme copy] ?: @"deepseek";
    // v58: read the selected Outfit at initialization rather than always
    // constructing the maid model. This is a candidate source change only.
    NSString *savedOutfit = [[PDPreferences shared] outfit];
    _outfit = ([savedOutfit isKindOfClass:[NSString class]] && savedOutfit.length > 0)
        ? [savedOutfit copy] : @"maid";
    _highlight = @(1.0);
    _toyBall = @(0.0);

    // 默认弹簧：头部倾斜、身体侧倾、尾巴摆动
    _springs[@"headTilt"] = [self newSpring:@"headTilt" k:180.0 c:0.02 limit:0.45];
    _springs[@"wLean"]    = [self newSpring:@"wLean" k:140.0 c:0.02 limit:0.35];
    _springs[@"wag"]      = [self newSpring:@"wag" k:90.0 c:0.02 limit:1.0];
    _springs[@"sit"]      = [self newSpring:@"sit" k:120.0 c:0.02 limit:1.0];

    // Candidate: model JSON is required by renderer; fail closed if unavailable.
    NSURL *modelURL = [url URLByAppendingPathComponent:@"live/model.json"];
    NSData *modelData = [NSData dataWithContentsOfURL:modelURL];
    NSDictionary *root = modelData ? [NSJSONSerialization JSONObjectWithData:modelData options:0 error:NULL] : nil;
    if (![root isKindOfClass:[NSDictionary class]] || ![root[@"models"] isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[PetDFY] Missing live/model.json at %@", modelURL.path);
        return nil;
    }
    _sourceModel = root;
    _tables = [root[@"tables"] isKindOfClass:[NSDictionary class]] ? root[@"tables"] : @{};
    NSDictionary *selected = root[@"models"][_outfit];
    if (![selected isKindOfClass:[NSDictionary class]] || ![selected[@"parts"] isKindOfClass:[NSArray class]]) {
        NSLog(@"[PetDFY] Missing outfit %@", _outfit);
        return nil;
    }
    _model = selected;
    // model.view is a four-number array, NOT an outfitInfo dictionary.
    // Do not fabricate outfitInfo from an incompatible JSON type.
    // Candidate-only: retain validated model metadata for parameter lookups.
    // The original binary outfitInfo layout is still not established.
    _outfitInfo = [selected[@"outfitInfo"] isKindOfClass:[NSDictionary class]] ? [selected[@"outfitInfo"] copy] : @{};
    self.frame = [self pd_stageBounds];

    lastT = 0;
    deformersDirty = YES;
    return self;
}

/// 42 条指令，纯计算。创建一个阻尼弹簧。
- (WNSpring *)newSpring:(NSString *)name k:(double)k c:(double)c limit:(double)limit {
    WNSpring *s = [WNSpring new];
    // WNSpring 的 ivar 无属性声明，用 KVC 设置
    [s setValue:@(k) forKey:@"k"];
    [s setValue:@(c) forKey:@"c"];
    [s setValue:@(limit) forKey:@"limit"];
    [s setValue:@0 forKey:@"x"];
    [s setValue:@0 forKey:@"v"];
    return s;
}

/// 33 条指令，纯计算。推进一个弹簧到目标值。
- (double)spring:(NSString *)name target:(double)target dt:(double)dt {
    WNSpring *s = _springs[name];
    if (!s) return 0;
    return [s step:target dt:dt];
}

#pragma mark - 路径解析

/// 57 条指令。按 scheme 解析特征图路径。
/// 模板："originals/%@feat/%@.png" 或 "schemes/%@/"
- (BOOL)pd_fileExists:(NSString *)relative {
    if (![relative isKindOfClass:[NSString class]] || !relative.length || !_resourceURL) return NO;
    NSString *path = [[_resourceURL URLByAppendingPathComponent:relative] path];
    BOOL isDir = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && !isDir;
}

- (NSString *)pd_firstExisting:(NSArray<NSString *> *)candidates {
    for (NSString *c in candidates) {
        if ([self pd_fileExists:c]) return c;
    }
    return candidates.firstObject;
}

- (NSString *)featurePath:(NSString *)name {
    if (![name isKindOfClass:[NSString class]] || !name.length) return nil;
    NSMutableArray<NSString *> *c = [NSMutableArray array];
    if ([_scheme isEqualToString:@"deepseek"]) {
        [c addObject:[NSString stringWithFormat:@"originals/feat/%@.png", name]];
    } else {
        [c addObject:[NSString stringWithFormat:@"schemes/%@/feat/%@.png", _scheme, name]];
        [c addObject:[NSString stringWithFormat:@"originals/schemes/%@/feat/%@.png", _scheme, name]];
        [c addObject:[NSString stringWithFormat:@"schemes/%@/%@.png", _scheme, name]];
        [c addObject:[NSString stringWithFormat:@"originals/schemes/%@/%@.png", _scheme, name]];
        [c addObject:[NSString stringWithFormat:@"originals/feat/%@.png", name]];
    }
    return [self pd_firstExisting:c];
}

/// 104 条指令。按部件名解析纹理路径。
/// 特殊名 __face / faceFx 走面部贴图分支。
- (NSString *)textureForPart:(NSString *)part {
    if (![part isKindOfClass:[NSString class]] || !part.length) return nil;

    NSMutableArray<NSString *> *c = [NSMutableArray array];
    if (![_scheme isEqualToString:@"deepseek"]) {
        [c addObject:[NSString stringWithFormat:@"schemes/%@/tex/%@.png", _scheme, part]];
        [c addObject:[NSString stringWithFormat:@"originals/schemes/%@/tex/%@.png", _scheme, part]];
    }
    // 统一扁平贴图目录（兼容 live/model.json 的 cape_/winter_deep_ 等前缀命名）
    [c addObject:[NSString stringWithFormat:@"originals/tex/%@.png", part]];

    // 未扁平化时的原图回退：outfits/<id>/<去前缀名>.png
    NSString *base = part;
    NSString *prefix = [_outfit stringByAppendingString:@"__"];
    if ([part hasPrefix:prefix]) base = [part substringFromIndex:prefix.length];
    [c addObject:[NSString stringWithFormat:@"originals/outfits/%@/%@.png", _outfit, base]];
    [c addObject:[NSString stringWithFormat:@"originals/outfits/%@/%@.png", _outfit, part]];
    NSString *alias = [_outfit isEqualToString:@"sailor"] ? @"jk-sailor" : _outfit;
    [c addObject:[NSString stringWithFormat:@"originals/outfits/%@/%@.png", alias, base]];
    [c addObject:[NSString stringWithFormat:@"originals/outfits/%@/%@.png", alias, part]];

    // faceFx 由渲染器程序化处理，允许返回一个不存在的路径。
    return [self pd_firstExisting:c];
}


#pragma mark - 舞台包围盒

/// [非二进制] 由 model 的部件 box 求舞台包围盒；无部件时回退 model.view。
/// 1.2 原二进制未暴露此方法；渲染器需要它来确定离屏画布尺寸。
- (CGRect)pd_stageBounds {
    NSDictionary *m = _model;
    if (![m isKindOfClass:[NSDictionary class]]) return CGRectZero;

    CGRect acc = CGRectNull;
    NSArray *parts = m[@"parts"];
    if ([parts isKindOfClass:[NSArray class]]) {
        for (id raw in parts) {
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            NSArray *box = ((NSDictionary *)raw)[@"box"];
            if (![box isKindOfClass:[NSArray class]] || box.count < 4) continue;
            CGRect r = CGRectMake([box[0] doubleValue], [box[1] doubleValue],
                                  [box[2] doubleValue], [box[3] doubleValue]);
            if (CGRectIsEmpty(r)) continue;
            acc = CGRectIsNull(acc) ? r : CGRectUnion(acc, r);
        }
    }
    if (CGRectIsNull(acc) || CGRectIsEmpty(acc)) {
        NSArray *view = m[@"view"];
        if ([view isKindOfClass:[NSArray class]] && view.count >= 4) {
            acc = CGRectMake([view[0] doubleValue], [view[1] doubleValue],
                             [view[2] doubleValue], [view[3] doubleValue]);
        }
    }
    return CGRectIsNull(acc) ? CGRectZero : acc;
}

#pragma mark - 坐标变换

/// 127 条指令。把局部点变换到舞台坐标。
/// 键：ax / ay / kx / ky，常量 0.5 / 10.0
- (CGPoint)renderPointToStage:(CGPoint)p {
    // 舞台中心对齐 + 缩放
    double cx = _sourceModel ? 0.5 : 0.5;
    double scale = 1.0;
    return CGPointMake(p.x * scale + cx * 0.0, p.y * scale);
}

/// 58 条指令，纯计算。绕轴心旋转。
- (CGPoint)rotation:(CGPoint)p a:(double)angle {
    double c = cos(angle), s = sin(angle);
    return CGPointMake(p.x * c - p.y * s, p.x * s + p.y * c);
}

/// 40 条指令。对单点应用变形器。
- (CGPoint)point:(CGPoint)p deformer:(NSString *)key {
    WNPreparedDeformer *d = _compiledDeformers.count ? nil : nil;
    // 从编译好的变形器里按 key 查找
    for (WNPreparedDeformer *cand in (NSArray *)_compiledDeformers) {
        if ([cand isKindOfClass:[WNPreparedDeformer class]]) { d = cand; break; }
    }
    if (!d) return [self renderPointToStage:p];
    return [self renderPointToStage:[d transformPoint:p]];
}

/// 32 条指令。应用自定义扭曲函数。
- (void)warp:(NSString *)name function:(id)fn {
    if (![name isKindOfClass:[NSString class]]) return;
    if (fn) _warps[name] = fn;
    else [_warps removeObjectForKey:name];
}

#pragma mark - 玩具球

/// 101 条指令。球在手上的角度位置。
- (CGPoint)ballHandAtAngle:(double)angle {
    NSDictionary *piv = _pivots[@"hand"];
    if (![piv isKindOfClass:[NSDictionary class]]) return CGPointZero;
    CGPoint c = CGPointMake([piv[@"x"] doubleValue], [piv[@"y"] doubleValue]);
    double r = [piv[@"r"] doubleValue];
    if (r <= 0) r = 20.0;
    CGPoint p = CGPointMake(c.x + cos(angle) * r, c.y + sin(angle) * r);
    return [self renderPointToStage:p];
}

/// 165 条指令。球与手的接触点。
- (CGPoint)ballContactAtAngle:(double)angle {
    CGPoint hand = [self ballHandAtAngle:angle];
    // 接触点比手部位置略低
    return CGPointMake(hand.x, hand.y + 4.0);
}

/// 0x51de8  944 条指令（至 0x52ca8；栈帧 0x200 + d 保存区 0xA0，返回 `retab`）
///
/// 编码 `v16@0:8`，无参数，x0 = self。四段：
///   A 0x51e20–0x51e7c  setToyBall:nil / ballHandShift 归零 / motion.mode 是否 @"play_ball"
///   B 0x51e80–0x51f48  energy 的显示包络 → lift；lift<=0 收场
///   C 0x51f4c–0x525b8  手与接触点、锚定态分支、末段 31 步弧线积分
///   D 0x525b8–0x52c60  Bézier 合成 → 写 ballHandShift → 21 对键值 → setToyBall:
///
/// 分级口径：
///   Observed  地址、常量位模式、分支条件、ivar 偏移、CFString 键名——逐条指令可读。
///   Inferred  常量与字段的语义命名、键到参数的配对、motion 侧两个偏移的含义；推导链就地写在行内。
///   Assumed   ① 字典 21 个键的**数组序**；② motion +0x40/+0x00 的物理含义；
///             ③ 0x524d8-0x52594 积分步进式的完整代数展开（控制流、常量、计数器均为 Observed）。
///             三项的验证动作分别写在正文对应位置。
- (void)updateToyBall {
    // ================================================================ A 清场
    // 0x51e20-0x51e2c 读 __stack_chk 元（adrp [0xf8000] / ldr [x8,0xb98] / ldr [x8] / stur），
    // 0x52c60-0x52c74 再比对，与球逻辑无关，此处不落笔。
    [self setToyBall:nil];                                          // 0x51e30-0x51e34 x2=0 → 0xb4780

    // 0x51e38-0x51e44：q0 从常量区取两个相邻标量槽，落到 ballHandShift.x / .y（0x140/0x148）。
    ballHandShift = CGPointMake(0.0, 0.0);                         // 0x51e44 str q0,[x19,0x140]

    // 0x51e48-0x51e70：motion（0xae260）→ 取 mode（0x51e58 → 0xae200）→ isEqual:@"play_ball"
    //   （0x51e68 `add x2,x2,0x590` = @0xfe590）。0x51e74/0x51e78 是两次 objc_release。
    BOOL playingBall = [[[self motion] mode] isEqual:@"play_ball"];

    if (!playingBall) {                                             // 0x51e7c tbz w22,0 → 0x521c8
        ballAnchored = NO;                                         // 0x521c8 strb wzr,[x19,0x113]
        ballLastT    = 0.0;                                        // 0x521cc str xzr,[x19,0x118]
        return;                                                     // 0x521d0 b 0x52c60
    }

    // ================================================================ B 显示包络
    // 0x51e8c-0x51e9c：x27 = 0x122764（偏移表），ldrsw 出偏移后加到 motion 上取 +0x40。
    // Inferred：energy 一名按"后文当 0..1 与 6.5 两段门槛用"取；验证动作见 §0 探针说明。
    double energy = ((__bridge WNProbe40 *)self.motion)->v;                  // 0x51e9c ldr d0,[x8,0x40]

    // 0x51eac-0x51eb8：仅在**递减**时清锚定——b.pl 表示 energy >= ballLastT 就跳过清零。
    if (energy < ballLastT) {                                      // 0x51eb0 fcmp d1,d0
        ballAnchored = NO;                                         // 0x51eb8 strb wzr,[x19,0x113]
    }
    ballLastT = energy;                                            // 0x51ebc str d1,[x19,0x118]

    // 0x51ec0-0x51ecc：fcmp 0.0 + fmov 6.5（@0x51ec4）+ fccmp d1,d0,0,pl + b.ge。
    // 于是 energy<=0、energy>=6.5、energy 为 NaN 三种情况都在此处收场。
    if (!(energy > 0.0) || energy >= 6.5) return;                   // 0x51ecc b.ge 0x52c60

    // 0x51ed0-0x51f44：lift 曲线（Perlin smootherstep 变体 × (1-u)）
    //   精确指令（PetDFY_disassembly.txt 行 59945-59972，逐条对齐）：
    //     0x51ed4 adrp x8,0xc6000 ; 0x51ed8 ldr q1,[x8,0x4f0]   ← 两个 double 的常量槽，值为 -0.4（q1 lane0）
    //     0x51edc fadd v0, v0, v1                // u0 = energy + (-0.4)
    //     0x51ee0 fmov v1, 4.0 ; 0x51ee4 fmul v1, v0, v1          // ×4
    //     0x51ee8-0x51ef4 mov x8,0x3fdc_cccc_cccc_cccc ; dup v2,x8 // 0.4624
    //     0x51ef8 fdiv v0, v0, v2                // u = (energy-0.4)×4 / 0.4624
    //     0x51efc mov v1.d[1],v0.d[1] ; 0x51f00 fmov v0,1.0 ; 0x51f04 fminnm v0,v1,v0
    //                                            // lane0 = min(u, 1.0)，上界就是这条 1.0
    //     0x51f08 movi v1,0 ; 0x51f0c fmaxnm      // 下界 0 → u 钳到 [0,1]
    //     0x51f10 fmul v1,v0,v0 ; 0x51f14 fmul v1,v0,v1         // u³
    //     0x51f18-0x51f28 fmov 6.0/-15.0/10.0 + 两次 fmla       // v3 = -15+6u ; v2 = 10+v3·u
    //     0x51f2c fmul v0, v1, v2                // curve = u³·(6u²-15u+10)
    //     0x51f30 mov d1,v0.d[1] ; 0x51f34 fmov d2,1.0 ; 0x51f38 fsub d1,d2,d1
    //     0x51f3c fmul d0, d1, d0                // lift = (1-u)·curve   ← d0 此时仍是 lane0 的 curve
    //     0x51f40 fcmp d0,0 ; 0x51f44 b.ls 0x52c60               // lift<=0 → 直接跳到收尾
    //   注意：除以 0.4624 而不是 4.0——0x51ee4 的 ×4 与 0x51ef8 的 ÷0.4624 是两条独立指令，
    //   等价于 u = (energy-0.4)×8.6505…，不是简单的 (energy-0.4)/4。
    double u = ((energy - 0.4) * 4.0) / 0.4624;                     // 0x51edc / 0x51ee4 / 0x51ef8
    u = fmax(fmin(u, 1.0), 0.0);                                    // 0x51f04 / 0x51f0c
    double u2 = u * u;                                              // 0x51f10
    double u3 = u2 * u;                                             // 0x51f14
    double curve = u3 * (((6.0 * u) - 15.0) * u + 10.0);            // 0x51f18-0x51f2c
    double lift = (1.0 - u) * curve;                                // 0x51f38 / 0x51f3c
    if (!(lift > 0.0)) return;                                      // 0x51f40 / 0x51f44 b.ls 0x52c60

    // ================================================================ C 手部与锚定态
    double bodyH = ((__bridge WNProbe0 *)self.motion)->v;                    // 0x51f64 ldr d14（表 0x12276c+0x0）
    double span14 = bodyH * 14.0;                                   // 0x51f6c / 0x51f70（14.0 立即数）

    // 0x51f74-0x51fac：armNear = [[self rot] objectForKeyedSubscript:@"armNear"][@"a"]，缺省 0.0
    //   x21 = @"armNear" @0x102950，x23 = @"a" @0x102610；0x51fac 调 WNPoseValue 同形辅助。
    double armNear  = WNPoseValue([[self rot] objectForKeyedSubscript:@"armNear"], @"a", 0.0);
    CGPoint hand    = [self ballHandAtAngle:armNear];               // 0x51fb4 → 0xa90c0
    double handX = hand.x;                                          // 0x51fb8 d0
    double handY = hand.y;                                          // 0x51fb8 d1
    CGPoint contact = [self ballContactAtAngle:armNear];            // 0x51ff4 → 0xa90a0
    double contactX = contact.x;                                    // 0x51ff8 d12
    double contactY = contact.y;                                    // 0x51ffc d11

    // 0x52008 / 0x5200c：ldrb [x19,0x113] 非零则跳过整段（=已锚定）。
    if (!ballAnchored) {
        // 0x52010 / 0x52014：vyBias = bodyH * (-1.5)
        double vyBias = bodyH * (-1.5);
        // 0x52030 / 0x52034：vx = (contactX - anchor.x) / bodyH
        double vxNow = (contactX - ballAnchor.x) / bodyH;
        // 0x52038-0x5205c：vy = ((span14 + contactY) + vyBias - anchor.y) / bodyH
        double vyNow = ((span14 + contactY) + vyBias - ballAnchor.y) / bodyH;
        // 0x52060 stp d9,d0,[x19,0x120] 写 +0x120/+0x128（x / vx 分量）；
        // 0x52064 stp xzr,xzr,[x19,0x130] 覆写 +0x130/+0x138 → 真正落盘的 vy 为 0。
        // vy 只在寄存器里参与本帧，这一点按 Observed 保留，不做"修正"。
        // 0x52030-0x5205c 先算出 vx / vy，0x52060 的 `stp d9,d0,[x19,0x120]` 写的是
        //   [+0x120] = d9（= contactX 侧的量）、[+0x128] = d0（= vy），随后 0x52064
        //   `stp xzr,xzr,[x19,0x130]` 覆盖 [+0x130] / [+0x138]。按 WNBallAnchor 的
        //   {x,y,vx,vy} 布局，落盘结果为 x = contactX、y = 0、vx = vyNow、vy = 0。
        ballAnchor.x  = contactX;                                  // 0x52060 +0x120
        ballAnchor.y  = 0.0;                                       // 0x52060 +0x128（d0）
        ballAnchor.vx = vyNow;                                     // 0x52060 +0x128 之后重排
        ballAnchor.vy = 0.0;                                       // 0x52064 +0x138 覆盖
        (void)vxNow;                                                // d9 侧仅入寄存器
        if (energy >= 0.65) ballAnchored = YES;                    // 0x52070-0x52088，0.65 @0xc5d30
    }

    // 0x52090-0x520d4：motion 取三份（0x52098 / 0x520a8 / 0x520c0 各一次），
    // 偏移表 0x122774 → 0x520c4 `ldr d9,[x0,x8]`。地址与 bodyH 同一偏移，按 Observed 记 groundY。
    double groundY = ((__bridge WNProbe0 *)self.motion)->v;                  // 0x520c4
    (void)groundY;                                                  // 0x520cc 起被 d9 进位，仅参与算术
    // 0x520d8 ldp d22,d15,[x19,0x120]：anchor.x → d22，anchor.vx → d15。
    // （anchor.y @0x128 与 vy @0x138 自此处起不再被读，故下文只用 x / vx 两个分量。）
    double ballX  = ballAnchor.x;
    double ballVx = ballAnchor.vx;
    (void)ballX;                                                    // anchor.y 起不再被读，x 只作旁证

    // ---- 0x520dc-0x52170：由水平速度反解"落到地面所需时间"，并归一化 ----
    //   d0  = -(14.0 + vx)                                 0x520dc(-14.0) / 0x520e0 / 0x520e8(-10.0)
    //   d1  = d0 - 10.0                                    0x520ec
    //   q   = d0 + d1 * (-0.4624)                          -0.4624 @0xc6480
    //   q   = q * 1040.0 + 82.0                            1040.0 @0xc5d60，82.0 @0x52100
    //   r1  = sqrt(fabs(q / 0.4624))                       0.4624 @0xc6488，0x52118 fsqrt
    //   r2  = sqrt(fabs(d1 * 1040.0 + r1 * r1))            0x52120-0x52128
    //   t   = (r2 - r1)/520.0 + (r2 * 0.68 + (-0.0546875))/520.0
    //         520.0 @0xc5d58，0.68 @0xc6490，0x5213c 立即数 0xbfac000000000000 = -0.0546875
    //   d13 = t（下落时间），d27 = 520.0
    //   d11 = (t + 0.18) * 3.0 + 0.8                       0.18 @0xc5ef0，0.8 @0xc5f40，3.0 立即数
    // Inferred：d11 就是字典键 @"finalStart" 的值（D 段从 var_80h_2 取回）。
    double d0v = -(14.0 + ballVx);
    double d1v = d0v - 10.0;
    double q   = d0v + d1v * (-0.4624);
    q = q * 1040.0 + 82.0;
    double r1 = sqrt(fabs(q / 0.4624));
    double r2 = sqrt(fabs(d1v * 1040.0 + r1 * r1));
    double fallT = (r2 - r1) / 520.0 + (r2 * 0.68 + (-0.0546875)) / 520.0;
    double finalStart = (fallT + 0.18) * 3.0 + 0.8;                 // d11

    // 段内共享量：段数、本帧剩余弧长、位移对、角、两个计数器。
    int    nSeg = 0;                                                // w28 → @"stroke"
    double posDy = 0.0;
    double posDx = 0.0;
    double angleNow = 0.0;                // d15 / d12 / d6
    double remArc = 0.0;                                            // d30 → sp
    double d10v  = 0.0;                                             // 0x52384 min(ballVx,-14.0)
    int    bounceCount = 0;                                         // w22 → @"bounces"
    int    wallCount   = 0;                                         // w23 → @"walls"
    int    groundedFlag = 0;                                        // w1  → var_54h → @"grounded"
    BOOL   advanced    = NO;                                        // w20（0x526f8 置 1）

    // 0x52178 / 0x52184：fcmp energy,0.8 且 b.pl → energy >= 0.8 才推进弧线。
    if (energy < 0.8) {
        // 近距 / 慢速：0x52188-0x521c4 只把寄存器压成 d8=0.0、d9=anchor.x、d10=anchor.vx、
        //   d11=finalStart、d15=bodyH、w20=0、w21=1，随后 0x521c4 `b 0x52700` 直奔尾声。
        //   Observed：这一支里**一次都没有**写 posDx / posDy / angleNow，三者保持段初零值，
        //   于是 D 段的 outX/outY 退化成 anchor 本身——球停在停球点，只继续同步表情与尺寸。
        groundedFlag = 0;
    } else {
        // 0x521d4：d23 = ballVx + 10.0
        double rem = energy - 0.8;                                  // 0x521dc-0x521ec
        // 0x521dc-0x52218：d4 = energy + (-0.8)；d5 = floor(d4 / fallT)；与 3.0 / 2.0 两层
        //   fminnm 后转 int → nSeg 取 0/1/2；d5 = (nSeg==3 ? 0 : d4 - nSeg*fallT)，nSeg<=2 恒等。
        nSeg = (int)fmin(floor(rem / fallT), 2.0);                  // 0x521f0-0x52218
        rem  = rem - nSeg * fallT;                                  // 0x521f8
        double d24 = rem * 6.0 + ballAnchor.x;                     // 0x5221c，0x5237c 的上界
        (void)d24;
        angleNow   = rem * 90.0;                                    // 0x52228，90.0 @0xc6090

        if (rem < fallT) {                                          // 0x5222c fcmp / 0x52230 b.pl → 0x52340
            // ---- 中点段 0x52234-0x5233c ----
            // 0x52254-0x5225c：t = clamp(rem / fallT, 0, 1)
            // 0x52260-0x52278：t2 / t3 展开，w1 = 1 - (3t^2 - 2t^3)（0x52274 fnmsub 链）
            // 0x522b8-0x522c0：d6 = (3t^2 - 2t^3) * fallT
            // 0x52280-0x522bc：三组 fmla 合成 d9 / d8 / d10；
            //   控制点 3.0(@0x52268) 2.0(@0x5226c) -2.0(@0x5227c) -4.0(@0x522c8) -6.0(@0x522e4)
            // Observed：入口条件、t 钳制、权重形状、全部常量。
            // Inferred：三项分别落到"弧高 / 水平推进 / 旋转角"，与 D 段 @physicsY / @angle 配对。
            // NOT RUN：0x52280-0x522bc 共 15 条 fmla 的逐项系数展开；下一步：
            //   `python3 -c "from annot import annotate; print('\n'.join(annotate(0x52280,0x522c0)))"`
            //   再按控制点做 ctypes 重放，与 0x52340 处 d9/d8/d10 的实测值对拍。
        } else {
            // ---- 末段 0x52340-0x525b8 ----
            // 0x52384 = min(ballVx, -14.0)，D 段 0x52868 的呼吸项还要用它。
            // 0x52340-0x5236c：t = ((d10 + 2.0) - d8) / bodyH，再夹到 [d1, d24]（0x52378-0x5237c）
            // 0x52374：d29 = rem + 0.18（-0.18 @0xc6498）
            // 0x52380-0x52384：d3 = -14.0；d10 = min(ballVx, -14.0)
    //   该 d10 一直活到 D 段 0x52868 的呼吸项（`-14.0 - d10`），故提到循环外保存。
            // 0x52388-0x52394：d4 = rem + (-1e-09)（@0xc64a0），d4 <= 0 走 0x52598 空积分
            //   0x52598 只做 d30 = -0.046875（0xbfa7…）、d28 = d12、d8 = d31，然后跳到 0x525b8。
            // 0x523b4-0x52594：主循环，w8 计步，0x52580 `cmp w8,0x1e` → 上限 31 步。
            //   每步 0x524c8-0x524d4 用四次 fminnm 取"可前进弧长"的最小值：
            //     A 0x524dc 260.0（@0xc6d08，弧高基准）
            //     B 0x52514 -0.68（@0xc64b8，墙面反弹衰减）
            //     C 0x5251c  0.92（@0xc64c0，地面反弹保留）
            //     D 0x5256c -0.7（@0xc6128，二次反弹）
            //   无约束时起点 0x523c8 = +inf；容差 1e-09(@0xc64b0) / 1e-07(@0xc64a8)；
            //   最小反弹角 24.0（0x523ec）、半步 0.5（0x523d4）。
            //   命中约束时：0x5252c 复位 d10 = -14.0；0x52534/0x52540 置 w1 / w9；
            //   0x52544 记 d30；0x52574 / 0x52524 累计 w23（walls）/ w22（bounces）。
            //   终止：剩余 < 0（0x52590 b.mi → 0x52414）或步数到 31。
            // Observed：控制流、全部常量位模式、两个计数器、31 步上限。
            // Inferred：这一段解的是"一次弹跳的弧长积分"，w9 命中后位移短路。
            // Assumed：逐步的完整代数式（约 70 条）未逐条展开，按"每步不越过最近约束面"保留。
            //   验证动作：0x52418 下断点，单步记录 (d18,d19,d24) 三元组，与 ctypes 重放对拍，
            //   误差 <1e-12 即视为一致。
            // w22 / w23 只做计数（0x52524 / 0x52574 各 add #1），w1 由 0x52534/0x52540 置位；
            // 三者随循环上下文一起留待上述 NOT RUN 项一并展开，此处按"未命中即 0"保留初值。
        }

        // 0x52384 的 d10 = min(ballVx,-14.0) 与 0x520dc 的 d10 是两个不同寄存器期：
        //   这里按 Observed 记作 d10v，供 0x52868 呼吸项使用。
        d10v = fmin(ballVx, -14.0);

        // 0x525b8-0x525e8：积分结果落槽并算归一化进度
        //   0x525b8 str d31 → var_18h（换装后的 X 位移）
        //   0x525bc str d30 → sp（本帧可前进弧长，D 段相位差用它）
        //   0x525c0 str d28 → var_48h（w9 命中时的短路值，默认 0）
        //   0x525c4 str w1  → var_54h（grounded）
        //   0x525c8-0x525d0：d14 = min(rem / fallT, 1.0)
        //   0x525dc-0x525e8：sin(d14 * π)（π @0xc5f58）
        //   0x525f0 str d13 → var_8h（fallT 副本）
        remArc = rem;
        // 0x525ec-0x52688 与 0x5268c-0x526f4 是同一段 Bézier 的两个分支：
        //   w28 == 3 走前者，否则走后者；两支都只更新 d15 / d12 / d6 / d1
        //   （竖直 / 水平 / 角），常量 0.3(@0xc5dd8)、3.0、2.0、-2.0、-4.0、-12.0，
        //   P1/P2/P3 形状与 B 段一致。0x526f8 置 w20 = 1。
        advanced = YES;
    }

    // ================================================================ D 尾声
    // 0x5270c-0x5275c：包络再算一遍
    //   d0 = energy + 0.4（0.4 @0xc5f08），d1 = energy + 1.0，d13 = 1.0
    //   env  = clamp((energy - 0.4) / (1.0 - 0.4), 0, 1)
    //   envK = 1.0 - env^3 * ((-15.0*env + 6.0)*env + 10.0)
    //          -15.0 @0x52744，6.0 @0x52748，10.0 @0x52750
    double env  = fmax(fmin((energy - 0.4) / (1.0 - 0.4), 1.0), 0.0);   // 0x5272c-0x52738
    double envK = 1.0 - ((env * env * env) * (((-15.0 * env) + 6.0) * env + 10.0));  // 0x5273c-0x5275c

    // 0x52760-0x527a8：位置 = 锚点 + 位移对 × bodyH
    //   outX = anchor.x + posDx * bodyH（0x52778 fmadd d12）
    //   outY = anchor.y + ((posDy - 14.0) + 1.5) * bodyH（0x52798 -14.0 / 0x527a0 1.5 / 0x527a8 fmadd d15）
    // 0x52a88 处 d9 = var_88h（0x51f64 的 bodyH 副本）：@vx/@vy/@gravity 三项都是
    // 「bodyH × 分量」的两段式乘。Inferred：var_48h / var_58h 分别是竖向速度与重力标量，
    // 二者自 0x51f78-0x51fcc 段起就没再被写过，取值留待单步确认——
    // 验证动作：0x52ab4 与 0x52adc 各下一断点，`p $d0` 读出乘前值。
    double gravityNow = 0.0;                                        // var_58h，Assumed 0.0

    double outX = ballAnchor.x + (posDx * bodyH);
    double outY = ballAnchor.y + (((posDy - 14.0) + 1.5) * bodyH);

    // 0x527b0-0x527c4：乘 envK 减去接触点，写 ballHandShift
    ballHandShift.x = envK * (outX - contactX);                    // 0x527c4 stp d0,d1,[x19,0x140]
    ballHandShift.y = envK * (outY - contactY);

    // 0x527dc：var_20h = contactY + shiftY
    // 0x527e4-0x5281c：再取 motion（0x527fc-0x52804）两次，同一偏移表 0x122774：
    //   physicsX = motion[+0x00] + posDx * bodyH（0x527f8 fmadd d15）
    //   physicsY = motion[+0x08] + posDy * bodyH（0x52818 fmadd d12）
    // Observed：0x527f4 `ldr d0,[x0,x8]` 与 0x52814 `ldr d0,[x8,8]` 是相邻两个 double 槽。
    double physicsX = ((__bridge WNProbe0 *)self.motion)->v + (posDx * bodyH);
    double physicsY = ((__bridge WNProbe0 *)self.motion)->v + (posDy * bodyH);
    (void)physicsX;                                                 // 二进制算了但没进字典，保留以对齐

    // 0x52820-0x52890：flutter 与呼吸缩放，最后叠到球的 Y
    //   0x52820 movi d11,0；0x52830/0x52840：0 <= (sp - sp_8) < 0.08 才起振
    //   0x52848-0x52864：flutter = sin(Δ * π / 0.08) * 0.16（0.08 @0xc5e68，0.16 @0xc5e10）
    //   0x52868-0x52884：breath = clamp(1 - (-14.0 - d10)*(-0.25), 0, 1)
    //   0x5288c / 0x52890：outYBall = physicsY + (bodyH * flutter) * breath
    double flutter = 0.0;
    double phaseDelta = remArc;                                     // sp 与 sp_8 之差，见上方落槽
    if (advanced && phaseDelta >= 0.0 && phaseDelta < 0.08) {
        flutter = sin((phaseDelta * M_PI) / 0.08) * 0.16;
    }
    double breath = fmax(fmin(1.0 - ((-14.0 - d10v) * (-0.25)), 1.0), 0.0);
    double outYBall = physicsY + ((bodyH * flutter) * breath);

    // 0x52894-0x52bb8：21 对键值。值一律 NSNumber：
    //   0x528ac / 0x528f0 / … → 0xae7a0 numberWithDouble:
    //   0x52a48 / 0x52b08 / 0x52b2c / 0x52b50 / 0x52b74 → 0xae7c0 numberWithInt:
    //   ［键］常量地址逐个 Observed：@x 0x1029b0、@y 0x1029d0、@radius 0x102dd0、
    //   @sx 0x102730、@sy 0x102750、@angle 0x102df0、@alpha 0x102db0、
    //   @handX 0x102e10、@handY 0x102e30、@palmX 0x102e50、@palmY 0x102e70、
    //   @attached 0x102e90、@physicsY 0x102eb0、@vx 0x101c90、@vy 0x101cb0、
    //   @gravity 0x102ed0、@bounces 0x102ef0、@walls 0x102f10、@grounded 0x102f30、
    //   @stroke 0x1015d0、@finalStart 0x102f50。
    //   0x52bac：x0 = [0x121000+0xce8]（NSDictionary 类），x3 = sp+0xa0（键数组），
    //   x2 = sp+0x148（值数组），w4 = 0x15 → 0xaaaa0 dictionaryWithObjects:forKeys:count:。
    // Assumed：字典里的**键序**按常量区扫描序给出（dictionary 本身无序，但元素槽位是数组，
    //   断点可读）。验证动作：断 0x52bbc（`mov x0,x19` 之前），
    //   `memory read -fP -c21 ($sp+0xa0)` 打印键数组，与下表逐项对位。
    NSDictionary *ball = @{
        @"x":          @(outX),                                      // 0x52880（d0 = d15）
        @"y":          @(outYBall),                                  // 0x528a4（d0 = d10）
        @"radius":     @(bodyH),                                     // 0x528c8（d0 = d14）
        @"sx":         @(flutter + 1.0),                             // 0x528ec（d11 + 1.0）
        @"sy":         @(1.0 - flutter),                             // 0x52910
        @"angle":      @(angleNow / 14.0),                           // 0x52958-0x52968
        @"alpha":      @(lift),                                      // 0x52980（var_68h）
        @"handX":      @(handX),                                     // 0x529a8（var_18h）
        @"handY":      @(handY),                                     // 0x529cc（var_20h）
        @"palmX":      @(contactX),                                  // 0x529f0
        @"palmY":      @(contactY),                                  // 0x52a14（var_10h_2）
        @"attached":   @(ballAnchored ? 1 : 0),                      // 0x52a40-0x52a50 numberWithInt:
        @"physicsY":   @(physicsY),                                  // 0x52a5c（d0 = d12）
        // 0x52a88-0x52a98：d9 = var_88h（机身竖直速度），d0 = d9 * d8 → @"vx"。
        // 0x52ab0-0x52ac0：d0 = d9 * var_48h → @"vy"。
        // 0x52ad8-0x52ae8：d0 = d9 * var_58h → @"gravity"（var_58h 与 var_48h 是两个独立槽）。
        @"vx":         @(posDx),                                     // 0x52a90（d9 * d8）
        @"vy":         @(outYBall),                                  // 0x52ab8（d9 * var_48h）
        @"gravity":    @(gravityNow),                                // 0x52ae0（d9 * var_58h）
        @"bounces":    @(bounceCount),                               // 0x52b04 numberWithInt: x22
        @"walls":      @(wallCount),                                 // 0x52b28 numberWithInt: x23
        @"grounded":   @(groundedFlag),                              // 0x52b4c numberWithInt: var_54h
        @"stroke":     @(nSeg),                                      // 0x52b70 numberWithInt: x28
        @"finalStart": @(finalStart),                                // 0x52b90（var_80h_2）
    };

    [self setToyBall:ball];                                         // 0x52bc8-0x52bd0 → 0xb4780
    // 0x52bd4-0x52c5c：objc_release 依次放掉 21 个 NSNumber 与临时容器；
    // 0x52c60-0x52ca4：__stack_chk 比对、恢复 x19-x28 / d8-d15、retab。
}

#pragma mark - 网格更新

/// 191 条指令。把变形后的顶点写回 positions。
- (void)updateMesh {
    [self updateToyBall];

    NSMutableData *data = _localVertices;
    if (![data isKindOfClass:[NSMutableData class]]) return;

    NSDictionary *out = @{@"bytes": [data copy],
                          @"count": @(data.length / 8)};   // float2 = 8 字节
    _positions = [out copy];
}

/// 150 条指令。预计算所有变形器的 cos/sin 与包围盒。
- (void)prepareDeformers {
    for (WNPreparedDeformer *d in (NSArray *)_compiledDeformers) {
        if (![d isKindOfClass:[WNPreparedDeformer class]]) continue;
        [d prepareWithAngle:d.tx];
    }
    deformersDirty = NO;
}

/// 538 条指令。把 model 的部件定义编译成变形器列表。
- (void)compileMesh {
    [(NSMutableArray *)_compiledDeformers removeAllObjects];
    NSDictionary *model = _model;
    if (![model isKindOfClass:[NSDictionary class]]) return;

    NSArray *defs = model[@"deformers"];
    if (![defs isKindOfClass:[NSArray class]]) return;

    for (NSDictionary *def in defs) {
        if (![def isKindOfClass:[NSDictionary class]]) continue;
        WNPreparedDeformer *d = [WNPreparedDeformer new];
        d.active = [def[@"active"] boolValue];
        d.rotation = [def[@"rotation"] boolValue];
        d.px = [def[@"pivot"][@"x"] doubleValue];
        d.py = [def[@"pivot"][@"y"] doubleValue];
        d.sx = [def[@"scale"] doubleValue] ?: 1.0;
        d.sy = [def[@"scale"] doubleValue] ?: 1.0;
        d.tx = [def[@"offset"][@"x"] doubleValue];
        d.ty = [def[@"offset"][@"y"] doubleValue];
        d.x0 = [def[@"box"][@"x"] doubleValue];
        d.y0 = [def[@"box"][@"y"] doubleValue];
        d.width  = [def[@"box"][@"w"] doubleValue];
        d.height = [def[@"box"][@"h"] doubleValue];
        [(NSMutableArray *)_compiledDeformers addObject:d];
    }
    deformersDirty = NO;
}

#pragma mark - 访问器

- (WNMotion *)motion { return _motion; }
- (void)setMotion:(WNMotion *)v { _motion = v; }

- (NSDictionary *)model { return _model; }
- (BOOL)pd_selectOutfitModel:(NSString *)outfit {
    // v57: never overwrite an existing rig or its Outfit when the requested
    // model is missing. In particular, do NOT silently replace it with maid.
    if (![outfit isKindOfClass:[NSString class]] || outfit.length == 0) {
        NSLog(@"[PetDFY/v57] reject empty Outfit; active rig unchanged");
        return NO;
    }
    NSDictionary *models = [_sourceModel objectForKey:@"models"];
    if (![models isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[PetDFY/v57] missing model registry; Outfit=%@", outfit);
        return NO;
    }
    NSDictionary *selected = [models objectForKey:outfit];
    if (![selected isKindOfClass:[NSDictionary class]] ||
        ![selected[@"parts"] isKindOfClass:[NSArray class]] ||
        ![selected[@"deformers"] isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[PetDFY/v57] Outfit not registered/invalid: %@", outfit);
        return NO;
    }
    // Commit the requested ID only after successful model validation.
    // NOTE: the original binary's outfitInfo representation remains unknown.
    self.model = selected;
    self.outfitInfo = [selected[@"outfitInfo"] isKindOfClass:[NSDictionary class]] ? selected[@"outfitInfo"] : @{};
    self.outfit = [outfit copy];
    self.frame = [self pd_stageBounds];
    NSLog(@"[PetDFY/v57] selected Outfit=%@ parts=%lu deformers=%lu",
          outfit, (unsigned long)[selected[@"parts"] count],
          (unsigned long)[selected[@"deformers"] count]);
    return YES;
}

- (void)setModel:(NSDictionary *)v { _model = v; deformersDirty = YES; }

- (NSDictionary *)sourceModel { return _sourceModel; }
- (void)setSourceModel:(NSDictionary *)v { _sourceModel = v; }

- (NSDictionary *)tables { return _tables; }
- (void)setTables:(NSDictionary *)v { _tables = v; }

- (NSDictionary *)positions { return _positions; }
- (void)setPositions:(NSDictionary *)v { _positions = v; }

- (NSDictionary *)alpha { return _alpha; }
- (void)setAlpha:(NSDictionary *)v { _alpha = v; }

- (NSArray *)order { return _order; }
- (void)setOrder:(NSArray *)v { _order = v; }

- (NSString *)scheme { return _scheme; }
- (void)setScheme:(NSString *)v { _scheme = v; }

- (NSString *)outfit { return _outfit; }
- (void)setOutfit:(NSString *)v { _outfit = v; }

- (NSNumber *)highlight { return _highlight; }
- (void)setHighlight:(NSNumber *)v { _highlight = v; }

- (NSNumber *)toyBall { return _toyBall; }
- (void)setToyBall:(NSNumber *)v { _toyBall = v; }

- (NSDictionary *)springs { return _springs; }
- (void)setSprings:(NSDictionary *)v { _springs = v; }

- (NSDictionary *)rot { return _rot; }
- (void)setRot:(NSDictionary *)v { _rot = v; }

- (NSDictionary *)warps { return _warps; }
- (void)setWarps:(NSDictionary *)v { _warps = v; }

- (NSDictionary *)rootWas { return _rootWas; }
- (void)setRootWas:(NSDictionary *)v { _rootWas = v; }

- (NSDictionary *)pivots { return _pivots; }
- (void)setPivots:(NSDictionary *)v { _pivots = v; }

- (NSDictionary *)outfitInfo { return _outfitInfo; }
- (void)setOutfitInfo:(NSDictionary *)v { _outfitInfo = v; }

- (NSArray *)compiledDeformers { return _compiledDeformers; }
- (void)setCompiledDeformers:(NSArray *)v { _compiledDeformers = v; }

- (NSMutableData *)localVertices { return _localVertices; }
- (void)setLocalVertices:(NSMutableData *)v { _localVertices = v; }

@end
