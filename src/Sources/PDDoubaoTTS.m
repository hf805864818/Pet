//
//  PDDoubaoTTS.m — 逆向还原：豆包 TTS 流式合成
//
//  还原依据：PetDFY.dylib arm64e，20 个方法共 516 条指令
//    initWithConfiguration:                              28
//    synthesizeText:key:speaker:instruction:options:completion:  143 (+ block invoke 6)
//    URLSession:task:willPerformHTTPRedirection:...      32
//    URLSession:dataTask:didReceiveResponse:...          64
//    URLSession:dataTask:didReceiveData:                 57
//    URLSession:task:didCompleteWithError:              114
//    cancel                                              22
//
//  端点：https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse
//  默认音色：zh_female_xiaohe_uranus_bigtts
//
//  ivar（size=56）：
//    _configuration  NSURLSessionConfiguration *
//    _session        NSURLSession *
//    _decoder        PDDoubaoSSEDecoder *
//    _completion     block
//    _failure        NSError *（setFailure: 编码 v24@0:8@16，是对象不是 block）
//

#import "PDDoubaoTTS.h"
#import "PDDoubaoSSEDecoder.h"
#import <Foundation/Foundation.h>

// ─────────────────────────────────────────────────────────────────────────────
//  _PDDoubaoRequest —— 二进制内 GLOBAL FUNC，符号地址 0x14b10。
//  调用点 0x15f14 只给出 ABI 形状（x0..x5 共 6 个整数/指针参数，返回 +0 对象）：
//    x0=text  x1=key  x2=speaker  x3=instruction  x4=&options  x5=&errorOut
//  Observed 0x14d58/0x14d5c：被调方对 *options 写回（str q0,[x25] / str x8,[x25,0x10]），
//    所以第 5 参是非 const 指针，语义是「读入 → 规整 → 写回」。
//  Observed 0x14c70：str x0,[x23] → 第 6 参是 NSError * 出参。
//  函数体不在本次还原范围内（属另一编译单元），此处只作声明。
// ─────────────────────────────────────────────────────────────────────────────
extern NSURLRequest *_PDDoubaoRequest(NSString *text,
                                      NSString *key,
                                      NSString *speaker,
                                      NSString *instruction,
                                      PDDoubaoOptions *options,
                                      NSError **errorOut);

// ─────────────────────────────────────────────────────────────────────────────
//  /tmp/shim 缺声明补齐：以下 API 在二进制里确有调用，但 shim 头没写。
//  补在本文件内，不动 shim。
// ─────────────────────────────────────────────────────────────────────────────

/// Observed 0x15fa4 / 0x15fb0 / 0x15fbc 三个 setter。
@interface NSURLSessionConfiguration (PDDoubaoTTSFill)
@property (nonatomic) BOOL HTTPShouldSetCookies;
@property (nonatomic, strong) id HTTPCookieStorage;
@property (nonatomic, strong) id URLCache;
@end

/// Observed：0x15fe0 的立即数 0x11 = 17。
/// Inferred：对应 NSQualityOfServiceUtility（userInteractive=0x21, userInitiated=0x19,
///           utility=0x11, background=0x9）。
enum { PDQualityOfServiceUtility = 17 };

@implementation PDDoubaoTTS

/// 28 条指令。
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration *)config {
    self = [super init];
    if (!self) return nil;
    _configuration = config ?: [NSURLSessionConfiguration defaultSessionConfiguration];
    _configuration.timeoutIntervalForRequest = 30;
    _configuration.timeoutIntervalForResource = 120;
    _configuration.HTTPMaximumConnectionsPerHost = 2;
    return self;
}

// ─────────────────────────────────────────────────────────────────────────────
//  IMP 0x15eac · 143 条指令（0x15eac–0x160e4 闭区间），另有 block invoke 0x160e8（6 条）
//  类型编码 v80@0:8@16@24@32@40{?=qqq}48@?72
//    x0=self  x1=_cmd  x2=text  x3=key  x4=speaker  x5=instruction
//    x6=&options（24 字节匿名结构体，>16B 故按间接传递，x6 是结构体指针）  x7=completion
//
//  控制流：
//    _PDDoubaoRequest → nil? ─yes→ dispatch_async(main, ^{ completion(nil, error); }) → ret
//                            └no─→ setCompletion → new decoder → copy config 并改参
//                                  → new NSOperationQueue → new session → dataTask resume
// ─────────────────────────────────────────────────────────────────────────────
- (void)synthesizeText:(NSString *)text
                   key:(NSString *)key
               speaker:(NSString *)speaker
           instruction:(NSString *)instruction
               options:(PDDoubaoOptions)options
            completion:(void (^)(NSData *, NSError *))completion
{
    // Observed 0x15ee4: objc_retain_x7 → ARC 在入口 retain completion 参数（→ x19）
    NSError *error = nil;

    // Observed 0x15eec–0x15ef8: ldr q0,[x20] / str q0,[sp,0x30] 把 *x6 前 16 字节搬走；
    //   ldr x8,[x20,0x10] / stp x8,xzr,[sp,0x40] 搬第三 qword 并把 sp+0x48 清零（error 出参槽）。
    //   合起来 = 按值传入的结构体在栈上的 24 字节副本 + 紧随其后的 error 槽。
    // Observed 0x15efc/0x15f00: x4 = sp+0x30（&副本），x5 = sp+0x48（&error）
    // Observed 0x15f04–0x15f10: x0=text(x25) x1=key(x24) x2=speaker(x23) x3=instruction(x21)
    // Observed 0x15f14: bl 0x14b10 _PDDoubaoRequest（GLOBAL FUNC）
    // Observed 0x15f18: objc_claimAutoreleasedReturnValue → 被调方返回 +0（autoreleased）
    NSURLRequest *request = _PDDoubaoRequest(text, key, speaker, instruction, &options, &error);

    // Observed 0x15f20/0x15f24: ldr x8,[sp,0x48] + objc_retain_x8 → error 被 retain 供 block 捕获
    // Observed 0x15f2c: cbz x20, 0x1604c → request == nil 走冷分支（先判空，后 setCompletion）
    if (request == nil) {
        // Observed 0x1604c–0x160b8: 栈 block 逐字段布局
        //   +0x00 isa        = 0xf8b70 → 导入序 365 = __NSConcreteStackBlock（pacda 签名）
        //   +0x08 flags      = 0xc2000000（自 0xc5cc0 整 8 字节以 d0 搬入，reserved=0）
        //   +0x10 invoke     = 0x160e8（pacia 签名，discriminator = 栈地址 sp+0x10）
        //   +0x18 descriptor = 0xf90b0（reserved=0, size=0x30；+0x10/+0x18 = 0x10560/0x105a8
        //                       两个 copy/dispose 桩）
        //   +0x20 error      = objc_retain(x21)
        //   +0x28 completion = objc_retain(x19)
        // Observed 0x160a0: ldr x0,[0xf8000+0xba0] → 导入序 371 = __dispatch_main_q
        // Observed 0x160ac: dispatch_async
        // Observed block invoke 0x160e8:
        //   ldp x2,x8,[x0,0x20] → x2=error, x8=completion
        //   ldr x4,[x8,0x10]!   → x4=completion->invoke, x3=&completion->invoke
        //   x0=completion, x1=0 → braa x4 → completion(nil, error)
        //   全程无 cbz：completion 为 nil 时照样直取 invoke（会崩），照搬不判空。
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, error);
        });
        return;   // Observed 0x160b0–0x160c8: 释放 error / 参数 completion / request
    }

    // Observed 0x15f30–0x15f38: x0=self(x22) x2=completion(x19); bl 0xb1800 = setCompletion:
    [self setCompletion:completion];

    // Observed 0x15f3c: adrp x8,0x121000 + ldr [x8,0xe88] → 0x121e88 → classref 'PDDoubaoSSEDecoder'
    // Observed 0x15f44: objc_opt_new（即 [X new]）
    // Observed 0x15f54: bl 0xb1b20 = setDecoder:
    PDDoubaoSSEDecoder *decoder = [PDDoubaoSSEDecoder new];
    [self setDecoder:decoder];
    // Observed 0x15f58: objc_release_x23（释放新建对象，ivar 已持有）

    // Observed 0x15f5c: bl 0xa9c60 = configuration（getter，autoreleased）
    // Observed 0x15f6c: bl 0xaa0c0 = copy → 改的是副本，不动 _configuration
    NSURLSessionConfiguration *config = [[self configuration] copy];

    // Observed 0x15f78: fmov d0, #25.0 ; 0x15f80 bl 0xb45c0 = setTimeoutIntervalForRequest:
    config.timeoutIntervalForRequest = 25.0;
    // Observed 0x15f84: adrp x8,0xc5000 + ldr d0,[x8,0xff0] → 0xc5ff0 = 0x4046800000000000 = 45.0
    // Observed 0x15f90: bl 0xb45e0 = setTimeoutIntervalForResource:
    config.timeoutIntervalForResource = 45.0;
    // Observed 0x15f98: w2=1 ; 0x15f9c bl 0xb2400 = setHTTPMaximumConnectionsPerHost:
    config.HTTPMaximumConnectionsPerHost = 1;
    // Observed 0x15fa4: w2=0 ; 0x15fa8 bl 0xb2440 = setHTTPShouldSetCookies:
    config.HTTPShouldSetCookies = NO;
    // Observed 0x15fb0: x2=0 ; 0x15fb4 bl 0xb23e0 = setHTTPCookieStorage:
    config.HTTPCookieStorage = nil;
    // Observed 0x15fbc: x2=0 ; 0x15fc0 bl 0xb48a0 = setURLCache:
    config.URLCache = nil;

    // Observed 0x15fc4: adrp x8,0x121000 + ldr [x8,0xe90] → 0x121e90 → classref 'NSOperationQueue'
    // Observed 0x15fcc: objc_opt_new
    NSOperationQueue *queue = [NSOperationQueue new];
    // Observed 0x15fd8: w2=1 ; 0x15fdc bl 0xb2fe0 = setMaxConcurrentOperationCount:
    queue.maxConcurrentOperationCount = 1;
    // Observed 0x15fe0: w2=0x11 ; 0x15fe4 bl 0xb38c0 = setQualityOfService:
    //   0x11 = 17。Inferred：枚举名 NSQualityOfServiceUtility；数值本身是 Observed。
    queue.qualityOfService = PDQualityOfServiceUtility;

    // Observed 0x15fe8: adrp x8,0x121000 + ldr [x8,0xe98] → 0x121e98 → classref 'NSURLSession'
    // Observed 0x15ffc: bl 0xb0ea0 = sessionWithConfiguration:delegate:delegateQueue:
    //   x2=config(x23)  x3=self(x22)  x4=queue(x24)
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config
                                                          delegate:self
                                                     delegateQueue:queue];
    // Observed 0x16010: bl 0xb3e60 = setSession:
    [self setSession:session];

    // Observed 0x16018: bl 0xb0e20 = session（getter，注意这里重新取而不是用局部变量）
    // Observed 0x1602c: bl 0xaa4e0 = dataTaskWithRequest:（x2 = request）
    // Observed 0x16038: bl 0xb0500 = resume
    [[[self session] dataTaskWithRequest:request] resume];
}

#pragma mark - NSURLSessionDelegate

/// 32 条。**无同主机 / HTTPS 判定**：这版直接拒掉一切重定向（携带 Key，不跟跳转）。
/// 0x16100: `mov x19,x0` → `bl @0xa8108`(objc_retain) → CFSTR("语音服务地址异常。")
///   → `int w0,#6`(NSLocalizedDescriptionKey) → `bl @0x1517c`(字典构造) → autorelease
///   → `bl @0xb2120`(setFailure: with @selector) → release
///   最后 `ldr x8,[x2,#0x10]` = block->invoke → `blraa x8,x2` 以 x1=0 调用，即 completionHandler(nil)。
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                    newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest *))completionHandler {
    (void)session; (void)task; (void)request;
    PDDoubaoFail(self, PDDoubaoError(6, @"语音服务地址异常。"));
    if (completionHandler) completionHandler(nil);
}

/// 63 条。二进制只用 `statusCode` 判，**没有 isKindOfClass 检查**。
/// 0x16180: 直调 `statusCode`（x0=response）→ `cmp x0,#0xc8`(200)
///   不等 → 组 NSError(CFSTR "语音服务连接失败（HTTP %ld）。", code) → setFailure: → disposition = 0
///   相等 → `bl 0xa96e0` = `cancelled`，`eor w1,w0,#1`，disposition = !cancelled
/// 即：**200 且未取消 → Allow(1)**；200 但已取消 → Cancel(0)；非 200 → Cancel(0)。
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    (void)session; (void)task;
    NSInteger code = ((NSHTTPURLResponse *)response).statusCode;
    NSInteger disposition;
    if (code != 200) {
        PDDoubaoFail(self, PDDoubaoError(code,
                            [NSString stringWithFormat:@"语音服务连接失败（HTTP %ld）。", (long)code]));
        disposition = 0;
    } else {
        disposition = !_cancelled;
    }
    if (completionHandler) completionHandler((NSURLSessionResponseDisposition)disposition);
}

/// 57 条。二进制不碰 `_decoder`：直接 `[self decoder]` 取新值，用完 release。
/// 0x1627c: cancelled → 跳过；decoder → appendData: → decoder → error → 非空则 setFailure:
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data {
    (void)session; (void)task;
    if (_cancelled) return;
    [[self decoder] appendData:data];
    id err = [[self decoder] error];
    if (err) PDDoubaoFail(self, err);
}

/// 114 条。**顺序与源码不同**：先组 error、再 finish 解码器、最后回调。
/// 0x16360 逐段：
///   0x16384 bl 0xa80f8 → retain 参数 error(x20)，存 x19
///   0x1638c bl 0xa8058 → retain self(_session)，存 x23
///   0x16398 bl 0xaba60 → [self failure]，存 x22
///   0x163a4 cmp x0,#0 / csel x8,x19,x0,eq → x8 = failure ?: retainedError
///   0x163ac bl 0xa8128 → `performSelector:` 带 x1=@selector(performSelector:) —— x8 就是 selector，不是参数
///   0x163b8 bl 0xa96e0 → [self cancelled]；cbz → 跳过取消分支
///   cancelled 分支：`[NSError errorWithDomain:@"com.susudear.petdfy.doubao" code:-999 userInfo:nil]` 覆盖 error
///   0x163f4 cbz x20 → 有 error 就跳过解码器
///   0x16404-0x1643c：`decoder` → `finish` → `decoder` → `error`，把 decoder.error 盖回 x20
///   0x16444 `completion` → x24；0x16458 `setCompletion:x2=0` 清掉
///   0x16460 session `finishTasksAndInvalidate:`  ← 源码漏了
///   0x16468 `setSession:x2=0` 清掉            ← 源码漏了
///   0x16474 cbz x24 → 有 completion 才回调 (audio, error)
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    (void)task;
    NSURLSession *s = _session;
    NSError *err = [self failure] ?: error;
    id audio = [self performSelector:@selector(performSelector:) withObject:err];  // 见下方说明

    if (_cancelled) {
        err = [NSError errorWithDomain:@"com.susudear.petdfy.doubao" code:-999 userInfo:nil];
    }
    if (!err) {
        [[self decoder] finish];
        err = [[self decoder] error];
    }

    void (^c)(NSData *, NSError *) = [self completion];
    [self setCompletion:nil];
    [s finishTasksAndInvalidate];
    [self setSession:nil];
    if (c) c(audio, err);
}

#pragma mark - 内部

/// 二进制里四个代理方法各自就地组 `@{NSLocalizedDescriptionKey: text}` 再喂
/// `+[NSError errorWithDomain:code:userInfo:]`，没有独立方法。这里收成 C 静态函数，
/// 不产生选择器，与二进制的方法表一致。
/// domain 是 CFString @0xfc650，源码按 `com.susudear.petdfy.doubao` 取——**Assumed**。
static NSError *PDDoubaoError(NSInteger code, NSString *text) {
    NSDictionary *ui = text ? @{ NSLocalizedDescriptionKey: text } : nil;
    return [NSError errorWithDomain:@"com.susudear.petdfy.doubao" code:code userInfo:ui];
}

static void PDDoubaoFail(PDDoubaoTTS *self, NSError *error) {
    // 二进制：csel 取 `failure ?: error`——显式 failure 覆盖传入 error，二者都是 NSError
    NSError *err = [self failure] ?: error;
    void (^c)(NSData *, NSError *) = [self completion];
    [self setCompletion:nil];
    if (c) c(nil, err);
}

/// 22 条指令。
- (void)cancel {
    [_session invalidateAndCancel];
    _session = nil;
    _decoder = nil;
    _completion = nil;
}

// [无法验证] 反汇编全文只含 9 个 dealloc，其余被工具链折叠。此实现按 ivar 布局推断。
- (void)dealloc {
    [self cancel];
}


/// 失败回调存取器（0x16b5c 区段外的两个小访问器，指令级未单列，Observed 自 ivar 直读）
- (NSError *)failure {
    return _failure;
}

- (void)setFailure:(NSError *)failure {
    _failure = failure;
}
#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setConfiguration:(id)v { _configuration = v; }
- (void)setSession:(id)v { _session = v; }
- (void)setDecoder:(id)v { _decoder = v; }
- (void)setCompletion:(id)v { _completion = v; }
- (void)setCancelled:(BOOL)v { _cancelled = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (id)configuration { return _configuration; }
- (id)session { return _session; }
- (id)decoder { return _decoder; }
- (BOOL)cancelled { return _cancelled; }



#pragma mark - 段切分（_PDDoubaoSpeechSegments）

NSArray<NSString *> *_PDDoubaoSpeechSegments(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return @[];

    NSMutableArray<NSString *> *raw = [NSMutableArray array];
    NSCharacterSet *punct = [NSCharacterSet characterSetWithCharactersInString:
                             @"。！？!?；;…\n\r"];
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ([punct characterIsMember:c]) {
            NSString *seg = [text substringWithRange:NSMakeRange(start, i - start + 1)];
            if (seg.length) [raw addObject:seg];
            start = i + 1;
        }
    }
    if (start < text.length) {
        NSString *seg = [text substringFromIndex:start];
        if (seg.length) [raw addObject:seg];
    }
    if (raw.count == 0) [raw addObject:text];

    // 长段再按 60 个字符切，避免单次请求过长。
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    const NSUInteger kMax = 60;
    for (NSString *seg in raw) {
        if (seg.length <= kMax) { [out addObject:seg]; continue; }
        NSUInteger p = 0;
        while (p < seg.length) {
            NSUInteger n = MIN(kMax, seg.length - p);
            [out addObject:[seg substringWithRange:NSMakeRange(p, n)]];
            p += n;
        }
    }
    return out;
}

@end
