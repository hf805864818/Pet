//
//  PDAIPetRuntime.m — 逆向还原：AI 运行时总调度
//
//  还原依据：PetDFY.dylib arm64e，111 个方法共 5327 条指令
//  本文件：初始化 / 生命周期 / 事件泵 / 设置应用 / 触摸响应
//
//  ivar（size=320，45 个字段）：
//    _confirmationShown / _touchWoke / _touchEnabled / _configured
//    _baseSound / _quietSound
//    _service    PDChatService *
//    _motion     WNMotion *
//    _presentationHandler / _turnHandler / _preferencesHandler
//    _devicePreparationHandler  block
//    _deviceTools  PDDeviceTools *
//    _alarms       PDAIAlarms *
//    _actions      NSMutableArray *
//    _activeAction / _walkID / _user / _displayedAppearance  NSString *
//
//  关键方法：
//    setSettings:completion:            916  应用设置（含权限校验）
//    executeTool:arguments:completion:  859  AI 工具入口
//    answer:index:text:dismissed:       505  对话应答
//    tickAt:                            423  定时泵
//    state                              354  导出状态
//    reloadPreferences                  311  重载配置
//    flushTouch                         304  合并触摸事件
//

#import "PDAIPetRuntime.h"
#import "PDChatService.h"
#import "PDDeviceTools.h"
#import "PDAIAlarms.h"
#import "WNMotion.h"
#import "PDPreferences.h"
#import <UIKit/UIKit.h>

@interface PDAIPetRuntime ()
@property (nonatomic, strong) NSMutableArray *pendingTouch;
@end

@implementation PDAIPetRuntime

#pragma mark - 初始化

/// 262 条指令。
- (instancetype)initWithDataDirectory:(NSString *)dir {
    self = [super init];
    if (!self) return nil;

    _actions = [NSMutableArray array];
    _user = @"主人";
    _activeAction = @"";
    _walkID = @"";
    _displayedAppearance = @"";
    _touchEnabled = YES;
    _configured = NO;

    // 闹钟持久化文件
    NSString *alarmPath = [dir stringByAppendingPathComponent:@"alarms.json"];
    _alarms = [[PDAIAlarms alloc] initWithFile:alarmPath];

    // 设备工具
    _deviceTools = [PDDeviceTools new];

    return self;
}

#pragma mark - 设置应用（核心）
/// 3600 字节 / 约 900 条指令。AI 修改设置的总入口。
///
/// 二进制流程（0x413b0-0x42160）：
///   1. 权限门：PDAIPreference(@"AISelfAdjust", @"default") 必须等于 @"default"
///      否则 completion(@"用户关闭了自主修改权限。", 非 nil) 直接返回
///   2. 遍历 settings，逐键校验，合法项进 changes，非法项进 errors
///   3. errors 非空 → completion(@"…；…", 非 nil)
///   4. changes 为空 → completion(@"没有需要修改的项目。", nil)
///   5. 有改动 → 合成 scheme 串 → 构造确认请求（确认后才写入）→ completion(req, nil)
///
/// 各键规则（均取自二进制常量）：
///   figure        只接受 @"whale"，否则 "figure 仅支持 whale"
///   scheme        "%@" 按 @"-" 拆两段：前段 ∈ 模型表，后段 ∈ 服装表
///   snoreSeconds  NSNumber 且 unsignedIntegerValue <= 20
///   hoverButtons  NSArray，count <= 6，元素 ∈ 按钮表
///   其余键        与当前值比较，不同才写；roam 落到 Theme 键
- (void)setSettings:(NSDictionary *)settings
         completion:(void (^)(id, NSError *))completion {
    if (![settings isKindOfClass:[NSDictionary class]]) {
        if (completion) completion(@"没有需要修改的项目。", nil);
        return;
    }

    // ---- 1. 权限门（0x413e8）----
    id mode = PDAIPreference(@"AISelfAdjust", @"default");
    if (![mode isEqual:@"default"]) {
        if (completion) completion(@"用户关闭了自主修改权限。", (__bridge NSError *)(void *)1);
        return;
    }

    NSMutableDictionary *changes = [NSMutableDictionary dictionary];
    NSMutableArray *errors = [NSMutableArray array];

    // 二进制常量 0x10f398 / 0x10f3b0 / 0x10f3c8
    NSArray *modelValues = @[@"deepseek", @"harness", @"chatgpt", @"claude",
                             @"gemini", @"qwen", @"kimi", @"minimax"];
    NSArray *outfitValues = @[@"maid", @"cape", @"crew", @"sailor", @"miko", @"dragon", @"nurse", @"winter_deep", @"violet_winter", @"frost_dragon", @"formal", @"starsea", @"eclipse", @"night_gala", @"pale_nurse"];
    NSArray *buttonValues = @[@"chat", @"voice", @"roam", @"theme",
                              @"sound", @"dress", @"hide"];

    // ---- 2. 逐键校验（枚举块，0x414b0 起）----
    [settings enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        if (![key isKindOfClass:[NSString class]]) return;
        NSString *k = key;

        if ([k isEqual:@"figure"]) {
            if (![value isEqual:@"whale"])
                [errors addObject:@"figure 仅支持 whale"];
            return;
        }

        if ([k isEqual:@"scheme"]) {
            // 服装 ID 可包含连字符，不能按所有 '-' 拆分并要求恰好两段。
            // 只匹配已知供应商前缀，余下完整字符串作为 outfit ID。
            NSString *appearance = [value isKindOfClass:[NSString class]] ? value : nil;
            NSString *matchedModel = nil;
            NSString *matchedOutfit = nil;
            for (NSString *candidate in modelValues) {
                NSString *prefix = [candidate stringByAppendingString:@"-"];
                if ([appearance hasPrefix:prefix]) {
                    NSString *candidateOutfit = [appearance substringFromIndex:prefix.length];
                    if ([outfitValues containsObject:candidateOutfit]) {
                        matchedModel = candidate;
                        matchedOutfit = candidateOutfit;
                        break;
                    }
                }
            }
            if (!matchedModel || !matchedOutfit) {
                [errors addObject:[NSString stringWithFormat:@"%@ 的值无效", k]];
                return;
            }
            changes[@"Scheme"] = matchedModel;
            changes[@"Outfit"] = matchedOutfit;
            return;
        }

        if ([k isEqual:@"snoreSeconds"]) {
            if (![value isKindOfClass:[NSNumber class]] || [value unsignedIntegerValue] > 20) {
                [errors addObject:[NSString stringWithFormat:@"%@ 的值无效", k]];
                return;
            }
            changes[@"snoreSeconds"] = value;
            return;
        }

        if ([k isEqual:@"hoverButtons"]) {
            BOOL ok = [value isKindOfClass:[NSArray class]] && [value count] <= 6;
            if (ok) {
                for (id item in value) {
                    if (![buttonValues containsObject:item]) { ok = NO; break; }
                }
            }
            if (!ok) {
                [errors addObject:[NSString stringWithFormat:@"%@ 的值无效", k]];
                return;
            }
            changes[@"HoverButtons"] = value;
            return;
        }

        // 通用键：与当前值比较
        id old = PDAIPreference(k, nil);
        if (!old) {
            [errors addObject:[NSString stringWithFormat:@"%@ 的值无效", k]];
            return;
        }
        if ([old isEqual:value]) return;          // 无变化，跳过（0x41760）
        NSString *storeKey = [k isEqual:@"roam"] ? @"Theme" : k;   // 0x41768 csel
        changes[storeKey] = value;
    }];

    // ---- 3. 有非法值 ----
    if (errors.count) {
        NSString *msg = [errors componentsJoinedByString:@"；"];
        if (completion) completion(msg, (__bridge NSError *)(void *)1);
        return;
    }

    // ---- 4. 无改动 ----
    if (!changes.count) {
        if (completion) completion(@"没有需要修改的项目。", nil);
        return;
    }

    // ---- 5. 合成 scheme 串并落盘（0x41e74 / 0x41ec0）----
    NSString *scheme = changes[@"Scheme"] ?: PDAIPreference(@"Scheme", @"deepseek");
    NSString *outfit = changes[@"Outfit"] ?: PDAIPreference(@"Outfit", @"maid");
    changes[@"scheme"] = [NSString stringWithFormat:@"%@-%@", scheme, outfit];

    // 等待用户确认：此处只能构造待确认请求，不得提前写入偏好。
    // 真正落盘由 answer:index:text:dismissed: 的同意分支完成。

    // ---- 6. 构造确认请求（0x41f20-0x42100）----
    // keys/values 为本次改动集，receipt 为一次性凭据。
    // 选项表取自二进制 0x10f3e0：可以 / 以后也允许 / 不要
    NSString *ident = [[NSUUID UUID] UUIDString];
    NSArray *keys = [changes allKeys];
    NSDictionary *request = @{
        @"kind":     @"confirm",
        @"id":       ident,
        @"question": [NSString stringWithFormat:@"我想修改这些设置，可以吗？\n%@", keys],
        @"options":  @[@"可以", @"以后也允许", @"不要"],
        @"values":   changes,
        @"keys":     keys,
        @"receipt":  ident,
        @"voice":    @YES,
    };

    if (completion) completion(request, nil);
}

#pragma mark - AI 工具入口

/// 859 条指令。AI 调用工具的入口。
/// 反汇编：visible → hasPrefix: → executeTool:arguments:
- (void)executeTool:(NSString *)tool arguments:(NSDictionary *)args
         completion:(void (^)(id, NSError *))completion {
    if (![tool isKindOfClass:[NSString class]] || !tool.length) {
        if (completion) completion(nil, [NSError errorWithDomain:@"PDAIPetRuntime"
                                                            code:-1
                                                        userInfo:@{NSLocalizedDescriptionKey: @"工具名为空"}]);
        return;
    }

    // 1) 桌宠不可见时拒绝
    if (!self.visible) {
        if (completion) completion(nil, [NSError errorWithDomain:@"PDAIPetRuntime"
                                                            code:-2
                                                        userInfo:@{NSLocalizedDescriptionKey: @"桌宠当前不可见"}]);
        return;
    }

    // 2) AISelf* 前缀 → 自主修改设置
    //    二进制签名是 (id, NSError*)：第二参非 nil 即失败
    if ([tool hasPrefix:@"AISelf"]) {
        NSDictionary *settings = [args isKindOfClass:[NSDictionary class]] ? args : @{};
        void (^cb)(id, NSError *) = ^(id info, NSError *err) {
            if (completion) {
                if (err || [info isKindOfClass:[NSString class]]) {
                    // 字符串消息（"没有需要修改的项目。" / "用户关闭了…"）按提示回传
                    completion(nil, err ?: [NSError errorWithDomain:@"PDAIPetRuntime"
                                                               code:-3
                                                           userInfo:@{NSLocalizedDescriptionKey: info}]);
                } else {
                    completion(info, nil);
                }
            }
        };
        [self setSettings:settings completion:cb];
        return;
    }

    // 3) 其它工具 → 交给设备工具执行器
    if (_deviceTools) {
        // PDDeviceTools 的回调是 (BOOL, NSDictionary *)，本类的 completion 是 (id, NSError *)
        [_deviceTools execute:tool arguments:args completion:^(BOOL ok, NSDictionary *result) {
            if (completion) completion(ok ? result : nil, ok ? nil : nil);
        }];
        return;
    }
    if (completion) completion(nil, [NSError errorWithDomain:@"PDAIPetRuntime"
                                                        code:-4
                                                    userInfo:@{NSLocalizedDescriptionKey: @"设备工具未就绪"}]);
}

#pragma mark - 定时泵

/// 423 条指令。每次 tick 处理事件队列。
/// 反汇编：visible → events → events → countByEnumerating
- (void)tickAt:(double)now {
    if (!self.visible) return;

    // 1) 取出 motion 累积的事件
    if (_motion) {
        NSArray *events = [_motion drainSoundEvents];
        for (NSDictionary *e in events) {
            if (![e isKindOfClass:[NSDictionary class]]) continue;
            // 音效事件：转给 sound 播放器
            if (self.soundHandler) self.soundHandler(e[@"name"], e[@"kind"]);
        }
    }

    // 2) 闹钟到期检查
    if (_alarms) {
        NSArray *due = [_alarms takeDue:[NSDate date]];
        for (NSDictionary *item in due) {
            NSString *text = item[@"text"];
            if (text.length) {
                if (_motion) [_motion doWord:text];
                if (self.alarmHandler) self.alarmHandler(text);
            }
        }
    }

    // 3) 主动互动心跳（AIHeartbeatMinutes）
    PDPreferences *prefs = [PDPreferences shared];
    NSInteger minutes = [prefs integerForKey:@"AIHeartbeatMinutes" fallback:0 min:0 max:120];
    if (minutes > 0) {
        double interval = minutes * 60.0;
        if (now - _nextHeartbeat >= interval) {
            _nextHeartbeat = now;
            if (self.heartbeatHandler) self.heartbeatHandler();
        }
    }
}

#pragma mark - 状态导出

/// 354 条指令。导出当前完整状态。
- (NSDictionary *)state {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"visible"] = @(self.visible);
    d[@"user"] = _user ?: @"";
    d[@"appearance"] = _displayedAppearance ?: @"";
    d[@"activeAction"] = _activeAction ?: @"";
    d[@"walkID"] = _walkID ?: @"";
    d[@"touchEnabled"] = @(_touchEnabled);

    if (_motion) {
        d[@"expression"] = _motion.expression ?: @"";
        d[@"faceName"] = [_motion currentFaceName] ?: @"neutral";
        d[@"x"] = @(_motion.x);
        d[@"gy"] = @(_motion.gy);
        d[@"mode"] = _motion.mode ?: @"idle";
    }
    if (_alarms) {
        NSArray *list = [_alarms list];
        d[@"alarms"] = @(list.count);
    }
    return [d copy];
}

#pragma mark - 偏好重载

/// 311 条指令。重载偏好，处理静音/漫游。
/// 反汇编：quietUntil → baseSound → baseRoam
- (void)reloadPreferences {
    PDPreferences *prefs = [PDPreferences shared];

    BOOL sound = [prefs boolForKey:@"Sound" fallback:YES];
    NSString *roam = [prefs stringForKey:@"Roam" fallback:@"free"];
    _baseSound = sound;

    double now = [[NSDate date] timeIntervalSince1970];
    if (_quietUntil > now) {
        // 静音期内保持静音
        if (_motion) _motion.quietSound = YES;
    } else {
        _quietUntil = 0;
        if (_motion) {
            _motion.quietSound = !sound;
            [_motion setRoamMode:roam];
        }
    }
    _configured = YES;
}

#pragma mark - 触摸

/// 205 条指令。处理触摸事件。
- (void)onTouch:(id)kind at:(double)point {
    if (!_touchEnabled || !_configured) return;

    _touchWoke = YES;

    // 合并触摸（防抖）
    if (!_pendingTouch) _pendingTouch = [NSMutableArray array];
    [_pendingTouch addObject:@{@"kind": kind ?: @"", @"point": @(point)}];

    // 300ms 内的触摸合并成一次
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(flushTouch)
                                               object:nil];
    [self performSelector:@selector(flushTouch) withObject:nil afterDelay:0.3];
}

/// 304 条指令。把累积的触摸合并成一条上下文。
- (void)flushTouch {
    if (!_pendingTouch.count) return;

    NSMutableString *desc = [NSMutableString string];
    for (NSDictionary *t in _pendingTouch) {
        NSString *kind = t[@"kind"];
        if (kind.length) {
            if (desc.length) [desc appendString:@"、"];
            [desc appendString:kind];
        }
    }
    NSUInteger n = _pendingTouch.count;
    [_pendingTouch removeAllObjects];

    // 转成 AI 上下文
    NSString *ctx = [NSString stringWithFormat:@"（%@ 交互了 %lu 次：%@）",
                     _user ?: @"主人", (unsigned long)n, desc];
    if (self.touchHandler) self.touchHandler(ctx);
}

#pragma mark - 中断

/// 99 条指令。中断当前动作。
- (void)interrupt {
    [_deviceTools cancel];
    if (_walkID.length) {
        [_motion stopWalk:_walkID];
        _walkID = @"";
    }
    _activeAction = @"";
    _pendingSettings = nil;
    _confirmationShown = NO;
}

#pragma mark - 可见性

- (BOOL)visible { return _visible; }
- (void)setVisible:(BOOL)v {
    if (_visible == v) return;
    _visible = v;
    if (v) {
        [self reloadPreferences];
    } else {
        [self interrupt];
    }
}

/// —— 属性存取器（ivar 直读，Observed 自类结构布局）——
- (id)service {
    return _service;
}

- (id)motion {
    return _motion;
}

- (id)deviceTools {
    return _deviceTools;
}

- (id)alarms {
    return _alarms;
}

- (id)actions {
    return _actions;
}

- (id)activeAction {
    return _activeAction;
}

- (id)walkID {
    return _walkID;
}

- (id)user {
    return _user;
}

- (id)displayedAppearance {
    return _displayedAppearance;
}

- (id)botAppearance {
    return _botAppearance;
}

- (id)pendingFigureEvent {
    return _pendingFigureEvent;
}

- (double)figureUntil {
    return _figureUntil;
}

- (double)actionUntil {
    return _actionUntil;
}

- (double)walkUntil {
    return _walkUntil;
}

- (double)sayUntil {
    return _sayUntil;
}

- (double)touchUntil {
    return _touchUntil;
}

- (double)confirmUntil {
    return _confirmUntil;
}

- (BOOL)confirmationShown {
    return _confirmationShown;
}

- (id)touch {
    return _touch;
}

- (BOOL)touchWoke {
    return _touchWoke;
}

- (BOOL)touchEnabled {
    return _touchEnabled;
}

- (BOOL)configured {
    return _configured;
}

- (BOOL)baseSound {
    return _baseSound;
}

- (BOOL)quietSound {
    return _quietSound;
}

- (id)touchMode {
    return _touchMode;
}

- (id)baseRoam {
    return _baseRoam;
}

- (id)quietRoam {
    return _quietRoam;
}

- (id)touchCustom {
    return _touchCustom;
}

- (id)ask {
    return _ask;
}

- (id)confirmation {
    return _confirmation;
}

- (id)pendingSettings {
    return _pendingSettings;
}

- (double)quietUntil {
    return _quietUntil;
}

- (double)bubbleSpeed {
    return _bubbleSpeed;
}

- (double)heartbeatMinutes {
    return _heartbeatMinutes;
}

- (double)lastActivity {
    return _lastActivity;
}

- (double)lastFire {
    return _lastFire;
}

- (double)nextHeartbeat {
    return _nextHeartbeat;
}

- (unsigned long long)idleTicks {
    return _idleTicks;
}


#pragma mark - 由反汇编还原（第二批）

- (BOOL)effectiveSound
{
    // 0x3d3b0: if (quietUntil > now) return quietSound; return baseSound;
    if ([[NSDate date] timeIntervalSince1970] < [self quietUntil])
        return [self quietSound];
    return [self baseSound];
}

- (id)effectiveRoam
{
    if ([[NSDate date] timeIntervalSince1970] < [self quietUntil])
        return [self quietRoam];
    return [self baseRoam];
}

- (BOOL)bodyBusy
{
    // 0x3de10: 无 motion 对象视为忙碌；否则看 mode 是否落在动作词表里
    id motion = [self motion];
    if (!motion)
        return YES;
    return [@[@"drag", @"air", @"crouch"] containsObject:[[self motion] mode]];
}

- (void)hold:(double)seconds
{
    // 0x3de90: 在 roamHoldUntil 基础上顺延
    id motion = [self motion];
    if (!motion)
        return;
    double until = [motion roamHoldUntil];
    [motion setRoamHoldUntil:fmax(until, until + seconds)];
}

- (void)tick
{
    // 0x3e54c: 以当前墙钟推进一次
    [self tickAt:[[NSDate date] timeIntervalSince1970]];
}

- (void)present:(id)sender
{
    // 0x3f4f0: 只把 self 交给 presentationHandler
    void (^handler)(id) = [self presentationHandler];
    if (handler)
        handler(self);
}

- (void)sendText:(NSString *)text
{
    // 0x3f400: 尾调用，images 走全局默认值
    [self sendText:text images:nil];
}

- (void)sendText:(NSString *)text images:(NSArray *)images
{
    // 0x3f40c: 先摸一下活动/触摸状态，再拼 [typed] 行入队
    [self activity];
    if ([self touch])
        [self flushTouch];
    NSString *line = [NSString stringWithFormat:@"[typed] %@:%@", [self user], text];
    [[self service] enqueueUserText:line images:images];
}

- (void)confirmationDidShow:(id)confirmationId
{
    // 0x3f570: 可见 + 未标记 + id 对得上，才进入 60 秒窗口
    if (![self visible])
        return;
    if ([self confirmationShown])
        return;
    id shownId = [[self confirmation] objectForKeyedSubscript:@"id"];
    if (![shownId isEqual:confirmationId])
        return;
    double now = [[NSDate date] timeIntervalSince1970];
    double until = [self confirmUntil];
    if (now < until) {
        [self setConfirmationShown:YES];
        [self setConfirmUntil:now + 60.0];
    } else {
        [self poll];
    }
}

- (void)didDisplayAppearance:(NSString *)appearance
{
    // 0x3d9d4: 装扮变更 → 清 botAppearance，必要时推一条 figure 事件
    NSString *current = [self displayedAppearance];
    if ([current isEqual:appearance])
        return;
    if (current.length == 0) {
        [self setDisplayedAppearance:appearance];
        [self setBotAppearance:nil];
        return;
    }
    id prevBot = [self botAppearance];
    BOOL sameBot = [prevBot isEqual:appearance];
    [self setDisplayedAppearance:appearance];
    [self setBotAppearance:nil];
    if (sameBot)
        return;
    if (![self configured])
        return;
    NSString *event = [NSString stringWithFormat:@"[figure] %@给你换了装扮。现在是大肥鱼 %@，表情与动作词表未改变。",
                                                 [self user], self];
    [self setPendingFigureEvent:event];
    [self setFigureUntil:[[NSDate date] timeIntervalSince1970] + 0.3];
}

- (void)setMotion:(id)motion
{
    // 0x3db4c: 换 motion 时打断旧流程并把状态清干净
    if (_motion == motion)
        return;
    void (^walk)(NSString *, BOOL) = (void (^)(NSString *, BOOL))[self walkCompletion];
    [self setWalkCompletion:nil];
    void (^confirm)(NSString *, BOOL) = (void (^)(NSString *, BOOL))[self confirmCompletion];
    [self setConfirmCompletion:nil];
    [self interrupt];
    _motion = motion;
    if (walk)
        walk(@"[interrupted] 角色装扮重新加载，移动中断。", NO);
    if (confirm)
        confirm(@"角色重新加载，尚未确认的设置没有修改。", NO);
    [[[self motion] events] removeAllObjects];
    [self setActiveAction:nil];
    [self setActionUntil:0.0];
    [[self motion] setRoamMode:[self effectiveRoam]];
    double snore = PDAINumber(PDAIPreference(@"SnoreSeconds", nil), 0.0);
    snore = fmax(0.0, fmin(snore, 3600.0));
    [[self motion] setSnoreSeconds:snore];
}

// ═══════════════════════════════════════════════════════════════════════════
//  activity / enqueueActions:  —— Observed（0x3df04 / 0x3e4e4）
// ═══════════════════════════════════════════════════════════════════════════

- (void)activity {
    [self setLastActivity:[[NSDate date] timeIntervalSince1970]];
    [self setIdleTicks:0];
}

- (void)enqueueActions:(NSArray *)actions {
    [[self actions] addObjectsFromArray:actions];
    [self hold:20.0];
}


// Observed（逐指令）  IMP = 0x3f694
- (void)answer:(id)answer index:(long long)index text:(NSString *)text dismissed:(BOOL)dismissed {
    [self activity];

    NSDictionary *confirmation = [self confirmation];
    if ([answer isEqual:confirmation[@"id"]]) {
        // ---- 命中当前 confirmation：先摘掉 pending 状态，再按 index / dismissed 分派 ----
        NSDictionary *pending = [self pendingSettings];
        // 头部把 confirmCompletion 声明成 void (^)(void)，实测调用点 0x3fdfc / 0x3faa0 传 (NSString *, BOOL)
        void (^completion)(NSString *, BOOL) = (void (^)(NSString *, BOOL))[self confirmCompletion];
        [self setPendingSettings:nil];
        [self setConfirmCompletion:nil];
        [self setConfirmation:nil];

        // Inferred: 0x3f774 `tbnz w25,0` + `cmp x26,#1 / b.hi` 为无符号比较，index 为负时也落到「未同意/超时」分支
        if (dismissed || (NSUInteger)index > 1) {
            if (completion) {
                NSString *receipt = pending[@"receipt"] ?: @"";
                completion([NSString stringWithFormat:@"%@用户未同意或确认已超时，询问的项目没有修改。", receipt], NO);
            }
            return;
        }

        NSMutableDictionary *values = [pending[@"values"] mutableCopy];

        // Inferred: 0x3f7b0 `cmp x26,#1 / b.ne` —— 只有 index == 1（同意且以后允许）才写 AISelf_* 开关
        if (index == 1) {
            [values setObject:@"AISelfAdjust" forKeyedSubscript:@"custom"];
            NSDictionary *direct = _PDAIDirectSettings();
            for (NSString *key in direct) {
                [values setObject:direct[key] forKeyedSubscript:[@"AISelf_" stringByAppendingString:key]];
            }
            // 0xf8b90 -> ___kCFBooleanTrue，即 @YES
            for (NSString *key in pending[@"keys"]) {
                [values setObject:@YES forKeyedSubscript:[@"AISelf_" stringByAppendingString:key]];
            }
        }

        // Inferred: 0x3f974 先查 Scheme，为空再查 Outfit，两者都空则整段外观刷新跳过
        if (values[@"Scheme"] || values[@"Outfit"]) {
            NSString *scheme = values[@"Scheme"] ?: _PDAIPreference(@"Scheme", @"deepseek");
            NSString *outfit = values[@"Outfit"] ?: _PDAIPreference(@"Outfit", @"maid");
            self.botAppearance = [NSString stringWithFormat:@"%@-%@", scheme, outfit];
        }

        _PDAIWritePreferences(values);
        [self reloadPreferences];

        void (^preferencesHandler)(void) = [self preferencesHandler];
        if (preferencesHandler) {
            preferencesHandler();
        }

        if (completion) {
            NSString *receipt = pending[@"receipt"] ?: @"";
            NSString *agreement = (index == 1) ? @"同意且以后允许" : @"同意";
            // Inferred: func.0003fe64 —— NSJSONSerialization + UTF-8(4) 解码，失败回落 @"{}"；
            // 注意序列化的是 pending[@"values"] 原值，不是改过的 mutableCopy（原样保留这一行为）
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:pending[@"values"] options:0 error:NULL];
            NSString *json = jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : nil;
            completion([NSString stringWithFormat:@"%@用户%@，已修改:%@", receipt, agreement, json ?: @"{}"], NO);
        }
        return;
    }

    // ---- 不是 confirmation 的 id：当成 ask 的回答处理 ----
    NSDictionary *ask = [self ask];
    if (![answer isEqual:ask[@"id"]]) {
        return;
    }

    NSDictionary *answeredAsk = [self ask];
    [self setAsk:nil];

    NSString *event;
    if (dismissed) {
        event = [NSString stringWithFormat:@"[answer] %@关掉了提问「%@」，没有作答。",
                                           [self user], answeredAsk[@"question"]];
    } else if (index >= 0 && (NSUInteger)index < [answeredAsk[@"options"] count]) {
        // Inferred: 0x3faec `tbnz x26,0x3f`（负 index）+ `cmp x22,x26 / b.ls`（越界）才走自由文本
        event = [NSString stringWithFormat:@"[answer] %@回答「%@」:选了第 %ld 项「%@」。",
                                           [self user], answeredAsk[@"question"],
                                           (long)(index + 1), answeredAsk[@"options"][(NSUInteger)index]];
    } else {
        // Inferred: func.0003ff00 —— 按行枚举，最多保留前 500 行，再 substringToIndex: 截断
        NSString *source = text ?: @"";
        __block NSUInteger lineIndex = 0;
        __block NSUInteger cut = 0;
        [source enumerateSubstringsInRange:NSMakeRange(0, source.length)
                                   options:NSStringEnumerationByLines
                                usingBlock:^(NSString *substring, NSRange substringRange,
                                             NSRange enclosingRange, BOOL *stop) {
            if (lineIndex >= 500) {
                *stop = YES;
                return;
            }
            lineIndex++;
            cut = substringRange.location + substringRange.length;
        }];
        NSString *body = [source substringToIndex:cut];
        event = [NSString stringWithFormat:@"[answer] %@回答「%@」:%@",
                                           [self user], answeredAsk[@"question"], body];
    }

    [[self service] enqueueEvent:event wake:YES preempt:NO];
}

// Observed（逐指令）  IMP = 0x401c0
- (void)poll {
    if (![self visible]) {
        return;
    }

    double now = [[NSDate date] timeIntervalSince1970];

    // ---- quiet 时段到点：解除静默，恢复 roam 模式 ----
    if ([self quietUntil] != 0.0 && now >= [self quietUntil]) {
        [self setQuietUntil:0.0];
        id roam = [self effectiveRoam];
        [[self motion] setRoamMode:roam];
        void (^preferencesHandler)(void) = [self preferencesHandler];
        if (preferencesHandler) {
            preferencesHandler();
        }
    }

    // ---- confirmation 超时：弹一个 closeAsk 面板再按「已超时」回执 ----
    NSDictionary *confirmation = [self confirmation];
    if (confirmation) {
        if (now >= [self confirmUntil]) {
            id confirmationID = [self confirmation][@"id"];
            [self present:@{@"kind": @"closeAsk", @"id": confirmationID}];
            // 0x40360：index = -1、text = @""、dismissed = YES
            [self answer:confirmationID index:-1 text:@"" dismissed:YES];
        }
    }

    if (![self configured]) {
        return;
    }

    // ---- 到点的闹钟：逐个走 service ----
    NSArray *dueEvents = [[self alarms] takeDue:[NSDate date]];
    for (NSString *event in dueEvents) {
        [self activity];
        [[self service] enqueueEvent:event wake:YES preempt:NO];
    }

    // ---- 心跳 ----
    if ([self heartbeatMinutes] <= 0.0) {
        return;
    }
    if (now < [self nextHeartbeat]) {
        return;
    }

    double lastActivity = [self lastActivity];
    double lastFire = [self lastFire];
    NSUInteger idle;
    if (lastActivity > lastFire) {
        idle = 0;
    } else {
        // Inferred: 0x404b8 `cmp x8,#3 / csinc` —— MIN(idleTicks + 1, 3)
        NSUInteger next = [self idleTicks] + 1;
        idle = (next >= 3) ? 3 : next;
    }
    [self setIdleTicks:idle];
    [self setLastFire:now];

    // Inferred: 0x404e0 常量 60.0 + exp2 —— 退避间隔 = heartbeatMinutes * 60 * 2^idleTicks
    double interval = [self heartbeatMinutes] * 60.0 * exp2((double)[self idleTicks]);
    [self setNextHeartbeat:now + interval];

    double quiet = fmax(now - [self lastActivity], 0.0);
    [[self service] enqueueEvent:[NSString stringWithFormat:@"[system] 已安静 %.0f 秒。", quiet]
                            wake:YES
                         preempt:NO];
}

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setService:(id)v { _service = v; }
- (void)setPresentationHandler:(id)v { _presentationHandler = v; }
- (void)setTurnHandler:(id)v { _turnHandler = v; }
- (void)setPreferencesHandler:(id)v { _preferencesHandler = v; }
- (void)setDevicePreparationHandler:(id)v { _devicePreparationHandler = v; }
- (void)setDeviceTools:(id)v { _deviceTools = v; }
- (void)setAlarms:(id)v { _alarms = v; }
- (void)setActions:(id)v { _actions = v; }
- (void)setActiveAction:(id)v { _activeAction = v; }
- (void)setWalkID:(id)v { _walkID = v; }
- (void)setUser:(id)v { _user = v; }
- (void)setDisplayedAppearance:(id)v { _displayedAppearance = v; }
- (void)setBotAppearance:(id)v { _botAppearance = v; }
- (void)setPendingFigureEvent:(id)v { _pendingFigureEvent = v; }
- (void)setFigureUntil:(double)v { _figureUntil = v; }
- (void)setActionUntil:(double)v { _actionUntil = v; }
- (void)setWalkUntil:(double)v { _walkUntil = v; }
- (void)setSayUntil:(double)v { _sayUntil = v; }
- (void)setTouchUntil:(double)v { _touchUntil = v; }
- (void)setConfirmUntil:(double)v { _confirmUntil = v; }
- (void)setConfirmationShown:(BOOL)v { _confirmationShown = v; }
- (void)setWalkCompletion:(id)v { _walkCompletion = v; }
- (void)setTouch:(id)v { _touch = v; }
- (void)setTouchWoke:(BOOL)v { _touchWoke = v; }
- (void)setTouchEnabled:(BOOL)v { _touchEnabled = v; }
- (void)setConfigured:(BOOL)v { _configured = v; }
- (void)setBaseSound:(BOOL)v { _baseSound = v; }
- (void)setQuietSound:(BOOL)v { _quietSound = v; }
- (void)setTouchMode:(id)v { _touchMode = v; }
- (void)setBaseRoam:(id)v { _baseRoam = v; }
- (void)setQuietRoam:(id)v { _quietRoam = v; }
- (void)setTouchCustom:(id)v { _touchCustom = v; }
- (void)setAsk:(id)v { _ask = v; }
- (void)setConfirmation:(id)v { _confirmation = v; }
- (void)setPendingSettings:(id)v { _pendingSettings = v; }
- (void)setConfirmCompletion:(id)v { _confirmCompletion = v; }
- (void)setQuietUntil:(double)v { _quietUntil = v; }
- (void)setBubbleSpeed:(double)v { _bubbleSpeed = v; }
- (void)setHeartbeatMinutes:(double)v { _heartbeatMinutes = v; }
- (void)setLastActivity:(double)v { _lastActivity = v; }
- (void)setLastFire:(double)v { _lastFire = v; }
- (void)setNextHeartbeat:(double)v { _nextHeartbeat = v; }
- (void)setIdleTicks:(unsigned long long)v { _idleTicks = v; }

@end
