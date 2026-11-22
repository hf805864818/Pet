//
//  PDAssetManager.m — 逆向还原：资源下载状态机
//
//  还原依据：PetDFY.dylib arm64e，32 个方法共 625 条指令
//    init                                     31
//    attemptKey                               75
//    status:progress:                         82
//    configureActive:URL:retry:request:       67
//    advance                                 284
//
//  状态流转：
//    idle → prepare → checking → downloading → validating → installing → idle
//  字典键：status / progress / operation / token / url / helper
//           importTokens / checking / prepare
//
//  ivar（size=96）：
//    _active  BOOL   _busy BOOL   _state NSDictionary *
//    _readyHandler / _willChangeHandler  block
//    _queue   dispatch_queue_t    _url NSString *
//    _retry   NSString *          _attemptedKey NSString *
//    _request NSDictionary *      _helper PDVoiceServiceConnection *
//    _generation unsigned long long
//

#import "PDAssetManager.h"
#import "PDAssetInstaller.h"
#import <UIKit/UIKit.h>

@implementation PDAssetManager

#pragma mark - 生命周期

/// 31 条指令。
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _state = @{@"status": @"idle", @"progress": @0};
    _queue = dispatch_queue_create("com.susudear.petdfy.asset-manager", DISPATCH_QUEUE_SERIAL);
    _generation = 0;
    return self;
}

/// 75 条指令。生成一次性的下载令牌。
/// 字符串：'%@\n%@\n%@\n%@' / operation / token
- (NSString *)attemptKey {
    NSUInteger gen = ++_generation;
    NSString *op = _request[@"operation"] ?: @"install";
    NSString *url = _url ?: @"";
    NSString *token = [NSString stringWithFormat:@"%@\n%@\n%@\n%llu",
                       op, url, _retry ?: @"", (unsigned long long)gen];
    _attemptedKey = [token copy];
    return token;
}

/// 82 条指令。更新状态并通知。
/// 反汇编：@{@"status": status, @"progress": @(progress)} → numberWithInteger:
/// 字典键（cfstring 0xfad10 / 0xfad30）：status / progress
- (void)status:(NSString *)status progress:(long long)progress {
    NSDictionary *next = @{@"status": status ?: @"idle",
                           @"progress": @(progress)};
    if ([_state isEqual:next]) return;

    BOOL changed = ![_state[@"status"] isEqual:next[@"status"]];
    _state = next;

    if (changed && _willChangeHandler) _willChangeHandler(next);
    if (_readyHandler) _readyHandler(_active, next);
}

/// 67 条指令。配置并启动。
- (void)configureActive:(BOOL)active
                    URL:(NSString *)url
                  retry:(NSString *)retry
                request:(NSDictionary *)request {
    _active = active;
    _url = [url copy];
    _retry = [retry copy];
    _request = [request copy];
    _attemptedKey = nil;
    [self status:@"prepare" progress:0];
}

/// 0x4a44，2 条指令：`mov x5, #0` + `b 0xa9ca0`（0xa9ca0 → selref
/// configureActive:URL:retry:request: 的 objc_msgSend trampoline）。
/// 即尾调用四参版本，request 传 nil。
- (void)configureActive:(BOOL)active URL:(NSString *)url retry:(NSString *)retry {
    [self configureActive:active URL:url retry:retry request:nil];
}

/// 284 条指令。推进状态机（核心方法）。
/// 字符串：checking / prepare / helper / importTokens / operation / token / url
- (void)advance {
    if (!_active) { [self status:@"idle" progress:0]; return; }
    if (_busy) return;

    NSString *status = _state[@"status"];
    NSString *op = _request[@"operation"] ?: @"install";

    // 阶段 1：准备
    if ([status isEqualToString:@"prepare"] || status == nil) {
        if (!_url.length) {
            [self status:@"failed" progress:0];
            return;
        }
        _busy = YES;
        [self status:@"checking" progress:0];

        // attemptKey 会更新 _attemptedKey；若立即比较两者，条件必定为真，
        // 在未设置 retry 时导致所有首次下载都停在 checking 状态。
        // 此处仅生成本次请求的 token，去重必须基于生成 token 之前的状态。
        [self attemptKey];

        // 检查 helper 是否可用（PDVoiceServiceConnection）
        id helper = _helper;
        if (!helper) {
            _busy = NO;
            [self status:@"waiting-helper" progress:0];
            return;
        }

        // 阶段 2：发起下载
        [self status:@"downloading" progress:0];
        _busy = NO;

        // 实际下载由 helper 完成，这里只推进状态
        dispatch_async(_queue, ^{
            [self status:@"validating" progress:0];
            [self status:@"installing" progress:0];
            [self status:@"idle" progress:0];
            self->_active = NO;
        });
        return;
    }

    // 阶段 3：等待 helper
    if ([status isEqualToString:@"waiting-helper"]) {
        if (_helper) {
            [self status:@"prepare" progress:0];
            [self advance];
        }
        return;
    }

    // 失败态：有 retry 时重试
    if ([status isEqualToString:@"failed"] && _retry.length) {
        _attemptedKey = nil;
        [self status:@"prepare" progress:0];
        return;
    }

    (void)op;
}

// [无法验证] 反汇编全文只含 9 个 dealloc，其余被工具链折叠。此实现按 ivar 布局推断。
- (void)dealloc {
    _readyHandler = nil;
    _willChangeHandler = nil;
}

#pragma mark - 真实安装（新增，参考包 1.2.1 install 语义）

/// 逆向结论：1.2 源码的 advance 只推进状态词，没有真实解压/落盘。
/// 这里补上真实安装入口；不改动 advance 的既有状态机行为。
- (BOOL)installAssetsIfNeeded {
    if (_busy) return NO;
    _busy = YES;
    [self status:@"installing" progress:0];

    NSString *root = nil;
    NSString *note = nil;
    BOOL ok = [PDAssetInstaller installNewestArchiveIfNeeded:&root message:&note];

    _busy = NO;
    [self status:(ok ? @"ready" : @"idle") progress:(ok ? 100 : 0)];
    if (ok) {
        _active = NO;
        _ready = YES;
    }
    NSLog(@"[PetDFY.Assets] installAssetsIfNeeded -> %@ (%@)", ok ? @"YES" : @"NO", note ?: @"");
    return ok;
}

#pragma mark - 访问器

- (BOOL)active { return _active; }
- (void)setActive:(BOOL)v { _active = v; }

- (BOOL)busy { return _busy; }
- (void)setBusy:(BOOL)v { _busy = v; }

- (NSDictionary *)state { return _state; }
- (void)setState:(NSDictionary *)v { _state = v; }

- (NSString *)url { return _url; }
- (void)setUrl:(NSString *)v { _url = v; }

- (NSString *)retry { return _retry; }
- (void)setRetry:(NSString *)v { _retry = v; }

- (NSString *)attemptedKey { return _attemptedKey; }
- (void)setAttemptedKey:(NSString *)v { _attemptedKey = v; }

- (NSDictionary *)request { return _request; }
- (void)setRequest:(NSDictionary *)v { _request = v; }

- (unsigned long long)generation { return _generation; }
- (void)setGeneration:(unsigned long long)v { _generation = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setReady:(BOOL)v { _ready = v; }
- (void)setReadyHandler:(void (^)(BOOL, NSDictionary *))v { _readyHandler = v; }
- (void)setWillChangeHandler:(void (^)(NSDictionary *))v { _willChangeHandler = v; }
- (void)setQueue:(id)v { _queue = v; }
- (void)setHelper:(id)v { _helper = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (BOOL)ready { return _ready; }
- (id)queue { return _queue; }
- (id)helper { return _helper; }

@end
