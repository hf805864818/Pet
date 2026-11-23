//
//  PDOverlayController.m — 逆向还原：悬浮层控制器
//
//  还原依据：PetDFY.dylib arm64e，76 个方法共 5148 条指令
//  本文件：窗口创建 / 生命周期 / 布局 / 可见性（核心 10 个方法）
//
//  ivar 布局（size=280）：
//    +8   isa
//    +9   BOOL pendingEntrance        +10 BOOL lastAvoidingKeyboard
//    +16  PDWindow * window           +24 PDRootController * root
//    +32  PDPetView * pet             +40 PDPreferences * preferences
//    +48  PDAssetManager * assets     +56 NSTimer * monitor
//    +64  id backlightController
//    +72  PDActiveInterfaceOrientationMonitor * orientationMonitor
//    +80  PDKeyboardMonitor * keyboardMonitor
//    +88  double lastPetSize          +96 double lastBottom
//    +104 double lastSafeTop          +112 NSString * loadedAppearance
//    +120 NSString * lastError        +128 NSArray * hoverButtons
//    +136 NSArray * hoverActions      +144 PDAIPetRuntime * ai
//    +152 PDChatController * chatController
//    +160 UIWindow * previousKeyWindow
//    +168 double hoverButtonDiameter  +176 block hoverDismissBlock
//    +184 CGSize lastSize             +200 keyboardAnimation{active,started,...}
//

#import "PDOverlayController.h"
#import "PDWindow.h"
#import "PDRootController.h"

// 0x703c0 GLOBAL FUNC：隐藏 layer 后执行 block，再还原（返回 block 的返回值）
extern id _PDPerformScreenCaptureWithExcludedLayer(CALayer *layer, id (^block)(void));


// ---- 桩头补齐：以下 API 在 /tmp/shim 中未声明，按 UIKit 真实签名补 ---- //
@interface NSTimer (PDOverlayTolerance)
@property (nonatomic) NSTimeInterval tolerance;
@end
@interface UIView (PDOverlayAnim)
+ (void)animateWithDuration:(NSTimeInterval)duration animations:(void (^)(void))animations;
+ (void)animateWithDuration:(NSTimeInterval)duration animations:(void (^)(void))animations completion:(void (^)(BOOL))completion;
@end
@interface UIWindowScene (PDOverlaySpace)
@property (nonatomic, readonly) id coordinateSpace;
@end
@interface UIViewController (PDOverlayContainment)
- (void)removeFromParentViewController;
@end
@interface CALayer (PDOverlayStroke)
@property (nonatomic) CGColorRef borderColor;
@end
@interface UIImage (PDOverlaySymbols)
+ (UIImage *)systemImageNamed:(NSString *)name;
@end
extern void dispatch_block_cancel(dispatch_block_t block);

// ---- 桩头补齐（第二批 · 随 0x93cc / 0x9d30 还原补入）---- //
// 下面 4 项在 /tmp/shim 里没有声明，但 0x93cc / 0x9d30 的指令确实调用它们；
// 按 iOS 13 SDK 真实签名在 .m 内本地补，未改 /tmp/shim。
//   0x9634 +[UIImageSymbolConfiguration configurationWithPointSize:weight:]（weight=4 = UIImageSymbolWeightRegular）
//   0x96bc -[UIButton setPreferredSymbolConfiguration:forImageInState:]
//   0x969c setBorderWidth:（CALayer，桩头只有 cornerRadius/lineWidth）
//   0xa2bc dispatch_block_create / 0xa25c dispatch_block_cancel（libdispatch 块 API）
extern dispatch_block_t dispatch_block_create(unsigned long flags, dispatch_block_t block);
extern void dispatch_block_cancel(dispatch_block_t block);

@interface UIImage (PDOverlaySymbol)
+ (UIImage *)systemImageNamed:(NSString *)name;
@end

@interface UIButton (PDOverlaySymbolConfig)
- (void)setPreferredSymbolConfiguration:(UIImageSymbolConfiguration *)configuration
                       forImageInState:(unsigned long)state;
@end

@interface CALayer (PDOverlayBorderWidth)
@property (nonatomic) CGFloat borderWidth;
@end

#import "PDPetView.h"
#import "PDPreferences.h"
#import "PDAssetManager.h"
#import "PDKeyboardMonitor.h"
#import "PDActiveInterfaceOrientationMonitor.h"
// ── 素材导入修复（v1.2.1 对齐）──
#import "PDJailbreak.h"
#import "PDAssetInstaller.h"
#import "PDZipExtract.h"
#import "PDDiag.h"
#import "PDDiagnostics.h"
#import "PDToast.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

@protocol PDBoundsSpace <NSObject>
@property (nonatomic, readonly) CGRect bounds;
@end
#import <math.h>
#import <spawn.h>
#import <sys/wait.h>
#import <fcntl.h>
#import <unistd.h>
extern char **environ;

// 前置声明（定义在文件后段）
static NSString *PDResourceBundlePath(void);
static BOOL PDIsDeviceLocked(void);
static NSString *PDFindUnzip(void);
static BOOL PDZIPContains(NSString *zipPath, NSString *needle);
static BOOL PDInstallCombinedArchive(void);

// 0x75e4 / 0x6eec：对 Class 对象做 performSelector:NSSelectorFromString(name)。
static id PDClassPerformSelector(Class cls, NSString *name) {
    if (!cls) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
}

@implementation PDOverlayController

/// Observed 0x5f28（class method，dispatch_once 单例）：
/// __DATA_CONST 0xfb70 存 once 谓词，块内 [[self alloc] init] 后写回。
+ (instancetype)sharedController {
    static PDOverlayController *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

#pragma mark - 窗口

/// 391 条指令。创建覆盖窗口（幂等）。
/// 反汇编：ready → mainScene → window → windowScene → pet
- (void)ensureWindow {
    if (_window) return;

    UIWindowScene *scene = [self mainScene];
    if (!scene) {
        _lastError = @"no active scene";
        return;
    }

    PDWindow *w = [[PDWindow alloc] initWithWindowScene:scene];
    w.frame = ((id<PDBoundsSpace>)scene.coordinateSpace).bounds;
    w.windowLevel = UIWindowLevelStatusBar + 1;   // 盖在状态栏之上
    w.backgroundColor = [UIColor clearColor];
    w.rootViewController = _root;
    w.hidden = NO;
    _window = w;

    // 首次创建时建桌宠
    if (!_pet) {
        NSString *root = PDResourceBundlePath();
        NSURL *resURL = [NSURL fileURLWithPath:root isDirectory:YES];
        // 诊断：把资源根与关键文件存在性打到 Console，便于真机排障
        {
            NSFileManager *dfm = [NSFileManager defaultManager];
            NSString *live = [root stringByAppendingPathComponent:@"live/model.json"];
            NSString *orig = [root stringByAppendingPathComponent:@"originals/model.json"];
            NSString *clips = [root stringByAppendingPathComponent:@"clips.plist"];
            NSString *metal = [root stringByAppendingPathComponent:@"Whale.metal"];
            PDDiagLog(@"root=%@", root);
            PDDiagLog(@"live/model=%@ originals/model=%@ clips=%@ whale.metal=%@ outfit=%@ scheme=%@",
                  [dfm fileExistsAtPath:live] ? @"Y" : @"N",
                  [dfm fileExistsAtPath:orig] ? @"Y" : @"N",
                  [dfm fileExistsAtPath:clips] ? @"Y" : @"N",
                  [dfm fileExistsAtPath:metal] ? @"Y" : @"N",
                  _preferences.outfit ?: @"?", _preferences.scheme ?: @"?");
        }
        PDPetView *pet = [[PDPetView alloc] initWithResourceURL:resURL];
        if (!pet) {
            _lastError = @"pet view init failed";
            PDDiagLog(@"PDPetView init FAILED (renderer/rig nil) root=%@", root);
            PDRecordRenderState(NO, NO, @"PDPetView/renderer 初始化失败");
            return;
        }
        PDDiagLog(@"PDPetView init OK size=%@", NSStringFromCGSize(pet.frame.size));
        PDRecordRenderState(YES, YES, nil);
        pet.frame = CGRectMake(0, 0, 104, 104);
        pet.doubleTapAction = _preferences.doubleTapAction ?: @"clip";
        pet.longPressAction = _preferences.longPressAction ?: @"menu";
        pet.interactionEnabled = _preferences.interactive;
        [_root.view addSubview:pet];
        _pet = pet;
    }
}

/// 114 条指令。找当前活跃的窗口场景。
- (UIWindowScene *)mainScene {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
    }
    // 回退：任意 window scene
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
    }
    return nil;
}

/// 资源根目录（Observed，fcn 0x42c98）：二进制是 C 函数，直接返回硬编码串。
/// 姊妹函数 0x42ca4 返回数据目录 `/var/mobile/Library/Application Support/PetDFY`。
///
/// 修复点（v1.2.1 对齐）：
///   1) 所有硬编码越狱路径统一经 PDJailbreak 展开，RootHide 的 jbroot 也能命中；
///   2) 候选根按「结构完整度 + 修改时间」打分，避免不完整的旧目录压过新导入的完整包；
///   3) 加入素材 bundle 根（参考包 1.2.1 的真实安装位置）。
static NSString *PDResourceBundlePath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *roots = [NSMutableArray array];

    // 1) 既有导入位置（保留 1.2 源码候选，全部经越狱根展开）
    for (NSString *p in PDLegacyImportedRoots()) {
        if (![roots containsObject:p]) [roots addObject:p];
    }

    // 2) 素材 bundle 根（参考包 1.2.1 的读取位置）
    for (NSString *p in PDAssetBundleRoots()) {
        if (![roots containsObject:p]) [roots addObject:p];
    }

    // 3) 导入投递目录下的一层子目录（有的导入器解到 AssetImports/<uuid>/）
    for (NSString *base in PDImportSpoolDirectories()) {
        NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:base error:NULL];
        for (NSString *child in children) {
            NSString *p = [base stringByAppendingPathComponent:child];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:p isDirectory:&isDir] || !isDir) continue;
            if (![roots containsObject:p]) [roots addObject:p];
        }
    }

    // 4) 打分：结构越完整越优先；同分按 live/model.json 修改时间取新
    NSString *best = nil;
    NSInteger bestScore = -1;
    NSTimeInterval bestTime = -1;
    for (NSString *r in roots) {
        NSInteger score = 0;
        NSString *live = [r stringByAppendingPathComponent:@"live/model.json"];
        NSString *orig = [r stringByAppendingPathComponent:@"originals/model.json"];
        BOOL hasLive = [fm fileExistsAtPath:live];
        BOOL hasOrig = [fm fileExistsAtPath:orig];
        if (hasLive) score += 100;
        if (hasOrig) score += 50;
        if ([fm fileExistsAtPath:[r stringByAppendingPathComponent:@"originals"]]) score += 20;
        if ([fm fileExistsAtPath:[r stringByAppendingPathComponent:@"clips.plist"]]) score += 10;
        if ([fm fileExistsAtPath:[r stringByAppendingPathComponent:@"frames"]]) score += 10;
        if (score == 0) continue;                       // 完全空目录不参与

        NSString *probe = hasLive ? live : (hasOrig ? orig : nil);
        NSDictionary *attrs = probe ? [fm attributesOfItemAtPath:probe error:NULL] : nil;
        NSTimeInterval t = attrs ? [attrs[NSFileModificationDate] timeIntervalSince1970] : 0;

        if (score > bestScore || (score == bestScore && t > bestTime)) {
            bestScore = score;
            bestTime = t;
            best = r;
        }
    }

    // 5) 兜底：仍在所有候选中找第一个「只少 clips/frames」但模型可用的根
    if (!best) {
        for (NSString *r in roots) {
            if ([fm fileExistsAtPath:[r stringByAppendingPathComponent:@"live/model.json"]]) {
                best = r;
                break;
            }
        }
    }
    if (!best) best = [PDAssetBundleRoots() firstObject] ?: @"/Library/Application Support/PetDFY.bundle";
    return best;
}

#pragma mark - 合并素材包导入（补齐 1.2 缺失的解压步骤）

static NSString *PDFindUnzip(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *fixed = @[
        @"/usr/bin/unzip",
        @"/var/jb/usr/bin/unzip",
        @"/var/jb/basebin/unzip",
        @"/usr/local/bin/unzip"
    ];
    for (NSString *p in fixed) {
        if ([fm isExecutableFileAtPath:p]) return p;
    }
    NSArray<NSString *> *apps = [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:NULL];
    for (NSString *name in apps) {
        if (![name hasPrefix:@".jbroot-"]) continue;
        NSString *base = [@"/var/containers/Bundle/Application" stringByAppendingPathComponent:name];
        for (NSString *rel in @[@"usr/bin/unzip", @"basebin/unzip"]) {
            NSString *p = [base stringByAppendingPathComponent:rel];
            if ([fm isExecutableFileAtPath:p]) return p;
        }
    }
    return nil;
}

static BOOL PDZIPContains(NSString *zipPath, NSString *needle) {
    NSData *data = [NSData dataWithContentsOfFile:zipPath options:NSDataReadingMappedIfSafe error:NULL];
    if (!data.length || !needle.length) return NO;
    NSData *n = [needle dataUsingEncoding:NSUTF8StringEncoding];
    return [data rangeOfData:n options:0 range:NSMakeRange(0, data.length)].location != NSNotFound;
}

static BOOL PDInstallCombinedArchive(void) {
    NSFileManager *fm = [NSFileManager defaultManager];

    // ── 阶段 1：进程内安装器（不依赖 /usr/bin/unzip）──
    // RootHide 下 /usr/bin/unzip 这个绝对路径并不存在，旧实现在这里静默失败，
    // 表现就是“面板抖一下、素材没反应”。改为先用 zlib 进程内解压安装。
    NSString *installedRoot = nil;
    NSString *note = nil;
    BOOL installed = [PDAssetInstaller installNewestArchiveIfNeeded:&installedRoot message:&note];
    if (installed) {
        NSLog(@"[PetDFY.Import] in-process install ok: %@", note);
        return YES;
    }
    // 已经装过同一份包：直接返回，避免每秒重复解压。
    if ([note isEqualToString:@"already imported"]) return NO;
    if ([note isEqualToString:@"no zip in spool"]) {
        // 每 60 秒最多提示一次，避免每秒刷屏
        static NSTimeInterval lastWarn = 0;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - lastWarn > 60) {
            lastWarn = now;
            NSArray *spool = [PDAssetInstaller spoolDirectories];
            NSMutableString *list = [NSMutableString string];
            NSFileManager *lfm = [NSFileManager defaultManager];
            for (NSString *d in spool) {
                NSArray *kids = [lfm contentsOfDirectoryAtPath:d error:NULL];
                if (kids) [list appendFormat:@"  ✓ %@\n", d];
            }
            PDShowToast([NSString stringWithFormat:
                @"没有找到待导入的素材 ZIP\n\n已扫描目录:\n%@\n请确认导入后在下列目录出现 .zip 文件。",
                list.length ? list : @"（投递目录都不存在）"], 12);
        }
        return NO;
    }
    if (note.length && ![note isEqualToString:@"no zip in spool"]) {
        NSLog(@"[PetDFY.Import] in-process install declined: %@; trying external unzip", note);
    }

    // ── 阶段 2：回退到外部 unzip（保留 1.2 原有能力，不再作为唯一路径）──
    NSString *combined = [PDDataDirectory() stringByAppendingPathComponent:@"Imported/combined"];
    NSString *dest = [combined stringByAppendingPathComponent:@"current"];
    NSString *marker = [combined stringByAppendingPathComponent:@".imported"];

    NSString *newest = nil;
    NSTimeInterval newestTime = -1;
    for (NSString *dir in [PDAssetInstaller spoolDirectories]) {
        NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:dir error:NULL];
        for (NSString *name in names) {
            if (![[name.pathExtension lowercaseString] isEqualToString:@"zip"]) continue;
            NSString *path = [dir stringByAppendingPathComponent:name];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) continue;
            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
            if (!attrs) continue;
            NSTimeInterval t = [attrs[NSFileModificationDate] timeIntervalSince1970];
            if (t < newestTime) continue;
            // 放宽判定：有分层模型（live）或部件模型（originals）任一即可；
            // 纯服装包不含 clips.plist 也接受（逐帧动作可选）。
            if (!PDZIPContains(path, @"live/model.json") &&
                !PDZIPContains(path, @"originals/model.json")) continue;
            newest = path;
            newestTime = t;
        }
    }
    if (!newest) return NO;

    NSDictionary *attrs = [fm attributesOfItemAtPath:newest error:NULL];
    NSString *token = [NSString stringWithFormat:@"%@|%llu|%.0f",
                       newest.lastPathComponent,
                       [attrs[NSFileSize] unsignedLongLongValue],
                       newestTime];
    NSString *old = [NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:NULL];
    if ([old isEqualToString:token]) return NO;

    NSString *unzip = PDFindUnzip();
    if (!unzip) {
        NSLog(@"[PetDFY.Import] no unzip binary and in-process install failed for %@", newest.lastPathComponent);
        return NO;
    }
    [fm createDirectoryAtPath:combined withIntermediateDirectories:YES attributes:nil error:NULL];
    [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:NULL];

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull >= 0) {
        posix_spawn_file_actions_adddup2(&fa, devnull, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&fa, devnull, STDERR_FILENO);
    }
    char *argv[] = {
        (char *)unzip.fileSystemRepresentation,
        "-o", "-q",
        (char *)newest.fileSystemRepresentation,
        "-d", (char *)dest.fileSystemRepresentation,
        NULL
    };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    if (devnull >= 0) close(devnull);
    if (rc != 0) {
        NSLog(@"[PetDFY.Import] posix_spawn failed %d", rc);
        return NO;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        NSLog(@"[PetDFY.Import] unzip failed status=%d", status);
        return NO;
    }
    BOOL ok = [PDAssetInstaller assetRootIsComplete:dest];
    if (ok) {
        [token writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        // 回写素材状态，让偏好页的“素材已移除”文字切换成“素材已就绪”。
        CFPreferencesSetAppValue((__bridge CFStringRef)@"AssetDownloadStatus",
                                 (__bridge CFStringRef)@"ready",
                                 (__bridge CFStringRef)@"com.susudear.petdfyprefs");
        CFPreferencesAppSynchronize((__bridge CFStringRef)@"com.susudear.petdfyprefs");
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)@"com.susudear.petdfy/assets-status", NULL, NULL, true);
        NSLog(@"[PetDFY.Import] installed combined assets from %@", newest.lastPathComponent);
    }
    return ok;
}

/// 每秒轮询 AssetImports。偏好 bundle 的“从文件导入 ZIP”把包拷进 AssetImports
/// 后不会重启 SpringBoard，这里检测到新包就解压安装并重载，免重启生效。
- (void)pd_pollAssetImports {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!PDInstallCombinedArchive()) return;
        __weak typeof(self) w = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            PDOverlayController *s = w;
            if (!s) return;
            [s discardAssetViews];
            [s setStarted:NO];
            [s start];
        });
    });
}

#pragma mark - 启动

/// 372 条指令。启动悬浮层。
- (void)start {
    if (_started) return;

    // 1) 建偏好
    if (!_preferences) _preferences = [PDPreferences new];

    // 2) 建资源管理器
    if (!_assets) {
        _assets = [PDAssetManager new];
        __weak typeof(self) weakSelf = self;
        _assets.readyHandler = ^(BOOL active, NSDictionary *state) {
            PDOverlayController *s = weakSelf;
            if (!s) return;
            if (!active) [s updateVisibility];
        };
    }

    // 3) 后台补齐合并素材包的解压/安装（1.2 原导入只写状态，不解压）
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!PDInstallCombinedArchive()) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            PDOverlayController *s = weakSelf;
            if (!s) return;
            [s discardAssetViews];
            [s setStarted:NO];
            [s start];
        });
    });

    // 4) 建窗口
    [self ensureWindow];
    if (!_window) return;

    // 4) 监听器
    if (!_orientationMonitor) {
        _orientationMonitor = [PDActiveInterfaceOrientationMonitor new];
        __weak typeof(self) weakSelf = self;
        void (^oriHandler)(UIInterfaceOrientation, double) = ^(UIInterfaceOrientation o, double d) {
            [weakSelf rotateHostWindowWithDuration:d];
        };
        id boxedOri = (id)oriHandler;
        object_setIvar(_orientationMonitor,
                       class_getInstanceVariable([PDActiveInterfaceOrientationMonitor class], "_changeHandler"),
                       boxedOri);
    }
    if (!_keyboardMonitor) {
        _keyboardMonitor = [PDKeyboardMonitor new];
        __weak typeof(self) weakSelf = self;
        // PDKeyboardMonitor 的 changeHandler 在头文件里是 void(^)(void)，
        // 实际语义是 void(^)(BOOL)。用 ivar 直接赋值绕过属性检查。
        void (^kbHandler)(BOOL) = ^(BOOL shown) {
            [weakSelf advanceKeyboardAnimation:@(shown)];
        };
        id boxedKb = (id)kbHandler;
        object_setIvar(_keyboardMonitor,
                       class_getInstanceVariable([PDKeyboardMonitor class], "_changeHandler"),
                       boxedKb);
    }
    [_keyboardMonitor refresh];

    // 5) 定时器：每秒检查可见性与布局
    if (!_monitor) {
        __weak typeof(self) weakSelf = self;
        _monitor = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            PDOverlayController *s = weakSelf;
            if (!s) { [t invalidate]; return; }
            [s updateVisibility];
            [s layoutPet];
            [s pd_pollAssetImports];
        }];
    }

    _started = YES;
    _pendingEntrance = YES;

    // 诊断：确认 dylib 已注入并运行（每次启动一次，3 秒消失）
    {
        static BOOL showedOnce = NO;
        if (!showedOnce) {
            showedOnce = YES;
            PDShowToast([NSString stringWithFormat:
                @"PetDFY 插件已加载\n进程: SpringBoard (pid %d)\n素材根: %@\n\n若导入后无反应，请把屏幕内容截图给我。",
                (int)getpid(), PDResourceBundlePath()], 6);
        }
    }

    [self applyAppearance];
    [self layoutPet];
    [self updateVisibility];
}

/// 355 条指令。应用外观（配色/服装）。
- (void)applyAppearance {
    if (!_pet || !_preferences) return;
    _pet.doubleTapAction = _preferences.doubleTapAction ?: @"clip";
    _pet.longPressAction = _preferences.longPressAction ?: @"menu";
    _pet.interactionEnabled = _preferences.interactive;
    NSString *scheme = _preferences.scheme ?: @"deepseek";
    NSString *outfit = _preferences.outfit ?: @"maid";
    NSString *sig = [NSString stringWithFormat:@"%@|%@", scheme, outfit];
    if ([_loadedAppearance isEqualToString:sig]) return;

    WNRenderer *renderer = _pet.renderer;
    if (!renderer || !renderer.liveRig) {
        NSLog(@"[PetDFY.OutfitDiag] deferred: %@ (renderer/rig missing)", sig);
        return;
    }

    // 限制同一失败签名的重复重建：避免布局/通知回调引发高 CPU 和耗电。
    // 成功后由 _loadedAppearance 缓存；失败后至少等待 5 秒再尝试。
    static NSString *lastAttemptSignature = nil;
    static CFAbsoluteTime lastAttemptTime = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if ([lastAttemptSignature isEqualToString:sig] && (now - lastAttemptTime) < 5.0) return;
    lastAttemptSignature = [sig copy];
    lastAttemptTime = now;

    // Do not mutate the active rig: failed preflight must retain old appearance.
    BOOL rebuilt = [renderer pd_resetLiveWithScheme:scheme outfit:outfit freeGround:YES];
    if (!rebuilt) {
        NSLog(@"[PetDFY.OutfitDiag] rebuild rejected; active rig preserved: %@", sig);
        return;
    }
    renderer.liveRig.highlight = @(1.0);

    WNLiveRig *rig = renderer.liveRig;
    // 此处只验证重建后状态与非空模型，不等同于验证纹理已成功绘制。
    BOOL stateMatches = (rig != nil && [rig.outfit isEqualToString:outfit] &&
                         [rig.scheme isEqualToString:scheme]);
    BOOL hasModel = [rig.model isKindOfClass:[NSDictionary class]] && rig.model.count > 0;
    if (stateMatches && hasModel) {
        _loadedAppearance = [sig copy];
        NSLog(@"[PetDFY.OutfitDiag] state accepted: %@", sig);
    } else {
        NSLog(@"[PetDFY.OutfitDiag] state NOT confirmed: requested=%@ rig=%@ model=%@",
              sig, rig.outfit, hasModel ? @"present" : @"missing");
    }
}

#pragma mark - 布局

/// 786 条指令。布局桌宠（最大的方法）。
/// 反汇编：isPaused → isHidden → root → root → root → safeAreaInsets
- (void)layoutPet {
    if (!_pet || !_window || !_preferences) return;

    // 1) 计算尺寸
    double scale = _preferences.size;             // 默认 128
    double baseW = 104.0 * scale / 128.0;
    double baseH = baseW;
    if (fabs(baseW - _lastPetSize) < 0.5) {
        // 尺寸没变，跳过重排（避免每帧抖动）
    } else {
        _lastPetSize = baseW;
    }

    // 2) 位置（归一化 → 实际坐标）
    CGSize win = _window.bounds.size;
    CGPoint norm = CGPointMake(0.7, 0.76);        // 默认位置
    // 实际从 preferences 读
    double px = norm.x, py = norm.y;

    double x = (win.width - baseW) * px;
    double bottom = _preferences.bottomInset;     // 默认 12
    double y = win.height - baseH - bottom - py * 0;

    // 3) 安全区修正
    UIEdgeInsets safe = _window.safeAreaInsets;
    if (safe.bottom > _lastSafeTop) _lastSafeTop = safe.bottom;
    y -= safe.bottom;

    // 4) 键盘避让
    if (_preferences.keyboardAvoidanceEnabled && _keyboardMonitor.state.visible) {
        y -= _preferences.keyboardAvoidanceExtra;
        _lastAvoidingKeyboard = YES;
    } else {
        _lastAvoidingKeyboard = NO;
    }

    CGRect f = CGRectMake(x, y, baseW, baseH);
    if (!CGRectEqualToRect(_pet.frame, f)) {
        _pet.frame = f;
    }
    _lastBottom = bottom;
    _lastSize = win;
}

/// 325 条指令。更新可见性。
/// 反汇编：preferences → enabled → containsObject: → configureActive:URL:retry:request:
- (void)updateVisibility {
    if (!_window || !_preferences || !_pet) return;

    BOOL enabled = _preferences.enabled;
    BOOL locked = PDIsDeviceLocked();
    BOOL hideOnLock = YES;                        // 锁屏隐藏

    BOOL shouldHide = !enabled || (locked && hideOnLock);
    _pet.hidden = shouldHide;
    _window.hidden = shouldHide;
    _pet.paused = shouldHide;

    if (!shouldHide) {
        [_pet updateFrameRate];
        if (_pendingEntrance) {
            _pendingEntrance = NO;
            // 首次出现：从顶部进入
            WNMotion *m = _pet.renderer.liveRig.motion;
            if (m) [m enterFromTop];
        }
    }
}

/// 锁屏检测。
static BOOL PDIsDeviceLocked(void) {
    // 0x6804 func.00006804：三段探测，任一不可用即保守判为锁定。
    Class managerClass = NSClassFromString(@"SBLockScreenManager");          // cfstr 0xfb610
    id manager = PDClassPerformSelector(managerClass, @"sharedInstance");    // 0x75e4
    Class backlightClass = NSClassFromString(@"SBBacklightController");      // cfstr 0xfb6b0
    id backlight = PDClassPerformSelector(backlightClass, @"sharedInstanceIfExists"); // 0x6eec

    UIApplication *app = [UIApplication sharedApplication];

    SEL isUILockedSel = NSSelectorFromString(@"isUILocked");                 // cfstr 0xfb630
    BOOL hasUILocked = [manager respondsToSelector:isUILockedSel];
    BOOL uiLocked = hasUILocked ? ((BOOL (*)(id, SEL))objc_msgSend)(manager, isUILockedSel) : NO;

    SEL isLockedSel = NSSelectorFromString(@"isLocked");                     // cfstr 0xfb650
    BOOL hasIsLocked = [app respondsToSelector:isLockedSel];
    BOOL appLocked = hasIsLocked ? ((BOOL (*)(id, SEL))objc_msgSend)(app, isLockedSel) : NO;

    SEL screenIsOnSel = NSSelectorFromString(@"screenIsOn");                 // cfstr 0xfb670
    BOOL hasScreenIsOn = [backlight respondsToSelector:screenIsOnSel];
    BOOL screenOff = hasScreenIsOn ? !((BOOL (*)(id, SEL))objc_msgSend)(backlight, screenIsOnSel) : NO;

    // 0x693c-0x6964：(uiLocked | appLocked | screenOff) | ~(hasUILocked | hasIsLocked)
    return (BOOL)((uiLocked | appLocked | screenOff) | !(hasUILocked | hasIsLocked));
}

#pragma mark - 旋转与键盘

/// 199 条指令。跟随设备旋转。
- (void)rotateHostWindowWithDuration:(double)duration {
    if (!_window) return;
    UIWindowScene *scene = _window.windowScene;
    if (!scene) return;

    CGRect b = ((id<PDBoundsSpace>)scene.coordinateSpace).bounds;
    if (CGRectEqualToRect(_window.bounds, b)) return;

    if (duration <= 0) {
        _window.bounds = b;
        _root.view.bounds = b;
        [self layoutPet];
        return;
    }
    [UIView animateWithDuration:duration animations:^{
        self->_window.bounds = b;
        self->_root.view.bounds = b;
        [self layoutPet];
    }];
}

/// ⚠️ 保真缺口：二进制 184 条指令（0xc0ec–0xc3a0），当前仅为摘要。
/// Observed：形参是对象（objc_retain_x2），不是 BOOL；函数体对 self 的多个 ivar
/// 做弹簧步进并调用 -layoutPet / -setFrame: 等。逐指令还原列入 HANDOFF 保真队列。
/// Assumed：下方分支结构按键盘通知语义推测。
- (void)advanceKeyboardAnimation:(id)shown {
    if (!_preferences.keyboardAvoidanceEnabled) return;
    [UIView animateWithDuration:0.25 animations:^{
        [self layoutPet];
    }];
}

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setWindow:(id)v { _window = v; }
- (void)setRoot:(id)v { _root = v; }
- (void)setPet:(id)v { _pet = v; }
- (void)setPreferences:(id)v { _preferences = v; }
- (void)setAssets:(id)v { _assets = v; }
- (void)setMonitor:(id)v { _monitor = v; }
- (void)setBacklightController:(id)v { _backlightController = v; }
- (void)setOrientationMonitor:(id)v { _orientationMonitor = v; }
- (void)setKeyboardMonitor:(id)v { _keyboardMonitor = v; }
- (void)setStarted:(BOOL)v { _started = v; }
- (void)setPendingEntrance:(BOOL)v { _pendingEntrance = v; }
- (void)setLastPetSize:(double)v { _lastPetSize = v; }
- (void)setLastBottom:(double)v { _lastBottom = v; }
- (void)setLastSafeTop:(double)v { _lastSafeTop = v; }
- (void)setLastAvoidingKeyboard:(BOOL)v { _lastAvoidingKeyboard = v; }
- (void)setLoadedAppearance:(id)v { _loadedAppearance = v; }
- (void)setLastError:(id)v { _lastError = v; }
- (void)setHoverButtons:(id)v { _hoverButtons = v; }
- (void)setHoverActions:(id)v { _hoverActions = v; }
- (void)setAi:(id)v { _ai = v; }
- (void)setChatController:(id)v { _chatController = v; }
- (void)setPreviousKeyWindow:(id)v { _previousKeyWindow = v; }
- (void)setHoverButtonDiameter:(double)v { _hoverButtonDiameter = v; }
- (void)setHoverDismissBlock:(id)v { _hoverDismissBlock = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (id)window { return _window; }
- (id)root { return _root; }
- (id)pet { return _pet; }
- (id)preferences { return _preferences; }
- (id)assets { return _assets; }
- (id)monitor { return _monitor; }
- (id)backlightController { return _backlightController; }
- (id)orientationMonitor { return _orientationMonitor; }
- (id)keyboardMonitor { return _keyboardMonitor; }
- (BOOL)started { return _started; }
- (BOOL)pendingEntrance { return _pendingEntrance; }
- (double)lastPetSize { return _lastPetSize; }
- (double)lastBottom { return _lastBottom; }
- (double)lastSafeTop { return _lastSafeTop; }
- (BOOL)lastAvoidingKeyboard { return _lastAvoidingKeyboard; }
- (id)loadedAppearance { return _loadedAppearance; }
- (id)lastError { return _lastError; }
- (id)hoverButtons { return _hoverButtons; }
- (id)hoverActions { return _hoverActions; }
- (id)ai { return _ai; }
- (id)chatController { return _chatController; }
- (double)hoverButtonDiameter { return _hoverButtonDiameter; }
// 0xc81c：`ldr x0, [x0, 0xb0] / ret`，纯 ivar 读。原还原漏了这条 getter，
// 而 0x9260（hideHoverButtons）、0x9d30（petHoverChanged:point:）都要先读它判空，补回。
- (void (^)(void))hoverDismissBlock { return _hoverDismissBlock; }

- (void)setVisibilityPolling:(BOOL)polling {
    NSTimer *monitor = self.monitor;
    if (polling) {
        if (monitor) {
            return;
        }
        self.monitor = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                        target:self
                                                      selector:@selector(updateVisibility)
                                                      userInfo:nil
                                                       repeats:YES];
        self.monitor.tolerance = 0.5;
        return;
    }
    [monitor invalidate];
    self.monitor = nil;
}

- (void)stopKeyboardAnimation {
    PDKeyboardAnimation animation = self.keyboardAnimation;
    animation.active = NO;
    [self setKeyboardAnimation:animation];
    self.pet.layoutAnimating = NO;
}

- (void)reloadPreferences {
    [self.pet cancelInteraction];
    [self.preferences reload];
    [self.ai reloadPreferences];
    if (self.preferences.enabled) {
        if (!PDIsDeviceLocked()) {
            [self.chatController reloadPreferences];
            [self applyAppearance];
            [self layoutPet];
        }
    }
    [self updateVisibility];
}

- (void)systemAppearanceDidChange {
    if (!self.pet) {
        return;
    }
    id theme = _PDAIPreference(@"Theme", @"auto");
    NSInteger style = 0;
    if ([theme isEqualToString:@"dark"]) {
        style = 2;
    } else if ([theme isEqualToString:@"light"]) {
        style = 1;
    }
    self.root.overrideUserInterfaceStyle = style;
    self.pet.renderer.darkAppearance = (self.root.traitCollection.userInterfaceStyle == 2);
}

- (void)setChatKeyboardFocus:(BOOL)focus {
    if (focus) {
        if (![self.window isKeyWindow]) {
            for (UIWindow *candidate in ((UIWindowScene *)self.window.windowScene).windows) {
                if ([candidate isKeyWindow] && candidate != self.window) {
                    self.previousKeyWindow = candidate;
                    break;
                }
            }
        }
        if (![self.window pdAllowsKey]) {
            self.window.pdAllowsKey = YES;
            [self.window resignKeyWindow];
            [self.previousKeyWindow makeKeyWindow];
        }
    } else {
        self.window.pdAllowsKey = NO;
        [self.window makeKeyWindow];
    }
}

/// IMP 0x84a8（约 1740 条，主体 0x84a8–0x8b48，另含 10 个块体 0x8c08–0x9104）。
/// 懒建聊天面板：已存在则返回 → 锁屏则返回 → 无 root 则返回 →
/// 以宠物气泡锚点构造 PDChatController，装 9 个回调，插进 root 并铺满，
/// 最后把气泡位置回调挂到宠物视图上。
///
/// 块地址 → 目标（逐条核对 bl 前的 x2/x3 装载）：
///   0x8c08 → initWithAnchorPoint:completion:（收尾块）
///   0x8cdc → setKeyboardFocusHandler:        void (^)(BOOL)
///   0x8d2c → setConfirmationShownHandler:    void (^)(NSString *)
///   0x8d98 → setTalkHandler:                 void (^)(void)
///   0x8e50 → setSendHandler:                 void (^)(NSString *, NSArray *)
///   0x8ed8 → setAnswerHandler:               void (^)(NSString *, long long, NSString *, BOOL)
///   0x8f78 → setActionsHandler:              void (^)(NSArray *)
///   0x8fe4 → setBodyBusyProvider:            BOOL (^)(void)
///   0x9034 → setSoundEnabledProvider:        BOOL (^)(void)
///   0x9084 → [pet setBubblePositionHandler:] void (^)(CGPoint)
- (void)ensureChat {
    if (self.chatController) {                          // 0x84b0 ldr [x0,#ivar]; cbnz → 0x84d0 返回
        return;
    }
    if (PDIsDeviceLocked()) {                        // 0x84c0 bl func.00006804; cbz → 继续
        return;
    }
    PDRootController *root = self.root;                 // 0x8518 ldr x19
    if (root == nil) {                                  // 0x851c cbz x19, 0x8b24（返回）
        return;
    }

    __weak PDOverlayController *weakSelf = self;        // 0x854c objc_initWeak(sp-0x80)，10 个块各自 copyWeak

    // 0x8554 bl bubbleAnchorInSuperview → 0x8588 initWithAnchorPoint:completion:
    // 块体 0x8c08：摘掉键盘焦点、卸掉气泡回调、把聊天视图从父控制器与父视图上摘干净。
    PDChatController *chat = [[PDChatController alloc] initWithAnchorPoint:[self.pet bubbleAnchorInSuperview]
                                                                completion:^{
        PDOverlayController *s = weakSelf;
        if (s == nil) {
            return;
        }
        [s setChatKeyboardFocus:NO];                    // 0x8c6c
        [[s pet] setBubblePositionHandler:nil];         // 0x8c84 setBubblePositionHandler: x2=0
        [[s chatController] willMoveToParentViewController:nil];   // 0x8c94
        [[[s chatController] view] removeFromSuperview];           // 0x8ca4 / 0x8cb0
        [[s chatController] removeFromParentViewController];       // 0x8cc4
        [s setChatController:nil];                                 // 0x8cd0
    }];
    [self setChatController:chat];                      // 0x85b8

    [chat setKeyboardFocusHandler:^(BOOL focused) {     // 0x8604 块 0x8cdc
        PDOverlayController *s = weakSelf;
        if (s == nil) {
            return;
        }
        [s setChatKeyboardFocus:focused];               // 0x8d20
    }];

    [chat setConfirmationShownHandler:(void (^)(BOOL))^(NSString *confirmation) {   // 0x8648 块 0x8d2c
        PDOverlayController *s = weakSelf;
        if (s == nil) {
            return;
        }
        [[s ai] confirmationDidShow:confirmation];      // 0x8d7c / 0x8d8c
    }];

    // 属性声明是 void (^)(NSString *, BOOL)，块体实测无参（0x8d98 只读捕获，不读 x2/x3）
    [chat setTalkHandler:(void (^)(NSString *, BOOL))^{   // 0x8688 块 0x8d98（无参）
        PDOverlayController *s = weakSelf;
        if (s == nil) {
            return;
        }
        PDPetView *pet = [s pet];                       // 0x8dbc
        if (pet == nil) {
            return;
        }
        // 0x8de0：motion + ivar 表项(WNMotion.p=+8) + 0x1b0 → p.talkK = 1.0
        [[[[pet renderer] liveRig] motion] setTalkPulse:1.0];
    }];

    [chat setSendHandler:(void (^)(NSString *))^(NSString *text, NSArray *images) {       // 0x86c8 块 0x8e50
        PDOverlayController *s = weakSelf;
        if (s == nil) {
            return;
        }
        [[s ai] sendText:text images:images];           // 0x8f1c（x2=text, x3=images）
    }];

    [chat setAnswerHandler:(void (^)(NSString *))^(NSString *answer, long long index, NSString *text, BOOL dismissed) {   // 0x8708 块 0x8ed8
        PDOverlayController *s = weakSelf;
        if (s == nil) {
            return;
        }
        [[s ai] answer:answer index:index text:text dismissed:dismissed];   // 0x8fa4
    }];

    [chat setActionsHandler:^(NSArray *actions) {       // 0x8748 块 0x8f78
        PDOverlayController *s = weakSelf;
        if (s == nil) {
            return;
        }
        [[s ai] enqueueActions:actions];                // 0x8fc8
    }];

    [chat setBodyBusyProvider:^BOOL{                    // 0x8794 块 0x8fe4（raw 7f000006d503237f，无捕获以外的引用）
        PDOverlayController *s = weakSelf;
        if (s == nil) {
            return NO;
        }
        return [[s ai] bodyBusy];                       // 0x9014
    }];

    [chat setSoundEnabledProvider:^BOOL{                // 0x87e4 块 0x9034
        PDOverlayController *s = weakSelf;
        if (s == nil) {
            return NO;
        }
        return [[s ai] effectiveSound];                 // 0x9064
    }];

    [self.pet setBubblePositionHandler:^(CGPoint position) {        // 0x8840 块 0x9084
        PDOverlayController *s = weakSelf;
        if (s == nil) {
            return;
        }
        [[s chatController] updateAnchorPoint:position];            // 0x90d4
    }];

    [root addChildViewController:chat];                 // 0x899c
    chat.view.frame = root.view.bounds;                 // 0x89d4–0x89f4（d8..d11 = root.view.bounds）
    chat.view.autoresizingMask = 18;                    // 0x8a00 w2=0x12 = FlexibleWidth|FlexibleHeight
    [root.view addSubview:chat.view];                   // 0x8a14
    [chat didMoveToParentViewController:root];          // 0x8a24

    // 0x8a34–0x8b44：objc_destroyWeak ×10（9 个块 + init 块）
}

- (void)showChat {
    if (PDIsDeviceLocked()) {
        return;
    }
    if (!self.root || self.root.presentedViewController) {
        return;
    }
    [self hideHoverButtons];
    [self ensureChat];
    [self.chatController showComposer];
}

- (void)showVoiceInput {
    if (PDIsDeviceLocked()) {
        return;
    }
    if (!self.root || self.root.presentedViewController) {
        return;
    }
    [self hideHoverButtons];
    [self ensureChat];
    [self.chatController startVoiceInput];
}

/// 0x7fc8（404 条）：卸载所有视图与外部引用，回到未启动状态。
- (void)discardAssetViews {
    [self stopKeyboardAnimation];                      // 0x7fe0
    self.pet.paused = YES;                             // 0x7fec setPaused:
    self.window.hidden = YES;                          // 0x8004 setHidden:
    [self.ai setVisible:NO];                           // 0x8014
    [self.pet cancelInteraction];                      // 0x8024
    [self hideHoverButtons];                           // 0x802c
    [self.chatController close];                       // 0x803c  // Inferred: 关闭面板
    [self setChatKeyboardFocus:NO];                    // 0x804c
    [self.ai setMotion:nil];                           // 0x805c
    [[PDSoundPlayer sharedPlayer] setVisible:NO];       // 0x8070
    self.window.rootViewController = nil;               // 0x8088
    [self.pet removeFromSuperview];                     // 0x8098
    self.chatController = nil;                          // 0x80a8
    self.pet = nil;                                     // 0x80b8
    self.root = nil;                                    // 0x80c8
    self.window = nil;                                  // 0x80d8
    self.loadedAppearance = nil;                        // 0x8120
    self.lastSize = CGSizeZero;                         // 0x812c-0x8134（CGSizeZero @0xf8a28）
    self.pendingEntrance = YES;                        // 0x8138-0x8158 尾调用 setPendingEntrance:YES
}

/// Observed @0x7364（46 条）：
/// 取 +[NSThread isMainThread]（0xad320 = selref 0x11f020）；
/// 真 → 尾调用 -updateVisibility（0xb6620）；假 → 组块 dispatch_async 到主队列，
/// 块体（0x7418）为 ldr x0,[x0,0x20]; b updateVisibility，即捕获 self 后调 updateVisibility。
/// 参数 didTransitionToBacklightState / source 在两条路径上均未被读取，按 ABI 保留。
- (void)backlightController:(id)controller
 didTransitionToBacklightState:(long long)state
                     source:(long long)source {
    if ([NSThread isMainThread]) {
        [self updateVisibility];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateVisibility];
    });
}

/// Observed 0x7078（0x2ec 字节）：把「隐藏自身层 → 取景 → 还原」整段包成 block，
/// 主线程直接跑，否则 dispatch_sync 到主队列；结果用 __block 变量带出来。
///   0x7098-0x70d0 栈上 byref（isa=0 / forwarding=&self / flags=0xc2000000 /
///                keep=0x71e0 / destroy=0x71f0），payload 槽在 +0x28
///   0x70d4-0x7114 blockA（isa=__NSConcreteStackBlock / flags=0xc2000000 /
///                invoke=0x71f8 / descriptor=0xf8e40），捕获 self(+0x20)、block(+0x28)、byref(+0x30)
///   0x712c objc_retainBlock；0x7144 tbnz isMainThread → 0x716c 直接调 invoke；
///                否则 0x7154 dispatch_sync(main, blockA)
///   0x716c-0x7180 取 byref payload → objc_retain → objc_autoreleaseReturnValue
/// block 体 0x71f8：preferences.enabled 为假 / isDeviceLocked 为真 / window 为空 → 都不取景；
///   否则 _PDPerformScreenCaptureWithExcludedLayer([window layer], 传入 block)
- (id)performDeviceScreenCapture:(id (^)(void))capture {
    __block id result = nil;

    void (^work)(void) = ^{
        if (![[self preferences] enabled]) {
            return;
        }
        if (PDIsDeviceLocked()) {
            return;
        }
        UIWindow *window = [self window];
        if (window == nil) {
            return;
        }
        result = _PDPerformScreenCaptureWithExcludedLayer([window layer], capture);
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return result;
}

/// 0x90f4（364 条）：造一个圆形悬浮按钮（图标 + 无障碍标签 + 触控回调）。
- (UIButton *)hoverIcon:(NSString *)iconName label:(NSString *)label action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];      // 0x9138 w2=1
    button.layer.borderColor = UIColor.whiteColor.CGColor;               // 0x914c-0x9180
    button.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.86];   // 0x9194/0x919c @0xc5cf0/@0xc5cf8
    button.accessibilityLabel = label;                                   // 0x91c4
    [button setImage:[UIImage systemImageNamed:iconName] forState:UIControlStateNormal]; // 0x91d8/0x91f4
    button.tintColor = UIColor.whiteColor;                               // 0x91fc/0x9210
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];  // 0x9228 w4=0x40
    return button;                                                       // 0x9230
}

/// 0x9260（364 条）：取消自动收起、拆掉所有悬浮按钮并清空状态。
- (void)hideHoverButtons {
    if (self.hoverDismissBlock) {                                        // 0x9290
        dispatch_block_cancel(self.hoverDismissBlock);                   // 0x92b4
        self.hoverDismissBlock = nil;                                    // 0x92c4
    }
    self.pet.hoverPositionHandler = nil;                                 // 0x92cc-0x92dc
    for (UIButton *button in self.hoverButtons) {                        // 0x92f4 枚举
        [button removeFromSuperview];                                    // 0x9344
    }
    self.hoverButtons = nil;                                             // 0x937c
    self.hoverActions = nil;                                             // 0x9388
    self.hoverButtonDiameter = 0;                                        // 0x938c movi d0,#0
}


#pragma mark - 0x93cc layoutHoverButtonsAt:reach:

/// Observed 0x93cc（0x4cc 字节 / 307 条）：把 hoverButtons 排成「3 个一竖列」的网格，贴到 point 附近。
/// 常量锚点：@0xc5d00 = 0.075（直径比例）、fmov #34.0 @0x94a0、fmov #8.0 @0x94b4、fmov #10.0 @0x9538、
///          fmov #16.0 @0x9640、fmov #0.5 @0x9684、fmov #-0.5 @0x9780。
/// 注意：直径取的是 bounds 的「宽」×0.075（0x9440 d8 = d10 * 0.075，d10 = bounds.size.width）；
///      reach 只参与水平偏移 offset = unit*10 + reach（0x9534-0x9548），不参与直径与半径。
- (void)layoutHoverButtonsAt:(CGPoint)point reach:(double)reach {
    if (self.hoverButtons.count == 0) return;                           // 0x9408-0x9438 count == 0 → 0x9854 直接返回
    CGRect bounds = self.root.view.bounds;                              // 0x9418-0x9434 d13=x d14=y d10=w d15=h
    double diameter = bounds.size.width * 0.075;                        // 0x9440-0x9448 d8 = d10 * [0xc5d00]
    if (!(diameter > 0)) return;                                        // 0x944c-0x9484 fcmp d8,#0.0 + b.ls（含 NaN）
    if (!isfinite(point.x) || !isfinite(point.y)) return;               // 0x9488-0x949c fabs 后与 +inf 比：b.eq（等）+ b.vs（无序/NaN）
    double unit = diameter / 34.0;                                      // 0x9490-0x94a0 d9 = d8 / 34.0
    double radius = unit * 8.0;                                         // 0x94a4-0x94b4 d13 = d9 * 8.0
    NSUInteger rows = MIN(self.hoverButtons.count, 3);                  // 0x94bc-0x94d0 csel ... lo → MIN(count,3)
    NSUInteger cols = (self.hoverButtons.count + 2) / 3;                // 0x94d4-0x9500 umulh 0xaaabaaaaaaaaaaaa + lsr（/3 优化）
    double totalW = cols * diameter + radius * (cols - 1);              // 0x9504-0x9530
    double offset = unit * 10.0 + reach;                                // 0x9534-0x9548 fmov #10.0 + fadd
    double originX;
    if (point.x + offset + totalW > CGRectGetMaxX(bounds) - radius) {   // 0x9560-0x9590 fcmp/fcsel gt
        originX = point.x - offset - totalW;                            // 右边放不下 → 整组翻到左边
    } else {
        originX = point.x + offset;
    }
    CGFloat minX = CGRectGetMinX(bounds), maxX = CGRectGetMaxX(bounds); // 0x9594-0x95a8
    CGFloat minY = CGRectGetMinY(bounds), maxY = CGRectGetMaxY(bounds); // 0x95ac-0x95c4

    [CATransaction begin];                                              // 0x95c8-0x95d8
    [CATransaction setDisableActions:YES];                              // 0x95e0-0x9610

    if (self.hoverButtonDiameter != diameter) {                         // 0x9614-0x961c fcmp d0,d8 + b.eq 跳过
        [self setHoverButtonDiameter:diameter];                         // 0x9628-0x9630
        UIImageSymbolConfiguration *config =                            // 0x9634-0x964c pointSize = unit*16.0，w2 = 4（UIImageSymbolWeightRegular）
            [UIImageSymbolConfiguration configurationWithPointSize:unit * 16.0 weight:4];
        for (UIButton *button in self.hoverButtons) {                   // 0x9664-0x9730 快速枚举
            button.layer.cornerRadius = diameter * 0.5;                 // 0x9684-0x968c fmov #0.5 + fmul
            button.layer.borderWidth = unit * 2.0;                      // 0x9690-0x969c fadd d14,d14,d14
            [button setPreferredSymbolConfiguration:config forImageInState:0]; // 0x96a0-0x96c4（w4 = 0 = UIControlStateNormal）
        }
    }

    double totalH = rows * diameter + radius * (rows - 1);              // 0x9760-0x977c（rows 在 0x9768 重取）
    CGFloat x0 = MIN(maxX - totalW - radius, originX);                  // 0x9788-0x97a8 fminnm
    CGFloat y0 = MIN(maxY - totalH - radius, point.y - totalH * 0.5);   // 0x9780-0x97b0 fmov #-0.5 + fminnm
    x0 = MAX(minX + radius, x0);                                        // 0x97a4-0x97b4 fmaxnm
    y0 = MAX(minY + radius, y0);                                        // 0x97ac-0x97b8 fmaxnm
    double step = diameter + radius;                                    // 0x97bc d13 = d8 + d5

    for (NSUInteger i = 0; i < self.hoverButtons.count; i++) {          // 0x97c0-0x9834 每轮重取 count
        double x = (i / 3) * step + x0;                                 // 0x97c4-0x97d8 umulh 0xaaab… → i/3
        double y = (i % 3) * step + y0;                                 // 0x97dc-0x97e4 sub x8,x8,x8,lsl 2 → i%3
        UIButton *button = self.hoverButtons[i];                        // 0x97fc objectAtIndexedSubscript:
        button.frame = CGRectMake(x, y, diameter, diameter);            // 0x9808-0x9810 setFrame:（d0=x d1=y d2=d3=diameter）
    }

    [CATransaction commit];                                             // 0x9818-0x9844
}
// 一句话：直径 = bounds 宽 × 7.5%，unit = 直径/34，radius = unit×8，按「每列 3 个、列数 ceil(n/3)」排布，
//        整组先在 bounds 内做两次 fminnm/fmaxnm 夹取，再逐颗 setFrame，全程关掉隐式动画。
#pragma mark - 0x9964 hoverPressed:

/// Observed 0x9964（0x3cc 字节 / 243 条）：hover 按钮点击分发。
///   入参 x19 = sender（0x998c objc_retain_x2 后落位）；x20 = self
///   0x99a0 / 0x99ac / 0x99e8 三次取 sender.tag（源写法即三处 `sender.tag` 引用，此处收成一个局部量，语义等价）
- (void)hoverPressed:(id)sender {
    if ([sender tag] < 0) return;                                        // 0x99a0-0x99b4 bl -tag → tbnz x0,#0x3f
    NSInteger tag = [sender tag];                                        // 0x99ac-0x99b8
    if ((NSUInteger)tag >= self.hoverActions.count) return;              // 0x99bc-0x99e8 b.hs（越界直接退）
    id action = self.hoverActions[tag];                                  // 0x99ec-0x9a10 objectAtIndexedSubscript:

    if ([action isEqual:@"chat"]) {                                      // 0x9a14 -isEqual: → 0x9a18 cbz w0,#0 → 0x9a28（@fb030 'chat'）
        [self showChat];                                                 // 0x9a20 -showChat
        return;                                                          // 0x9a24 b 0x9b94（chat/voice 不走 hideHoverButtons）
    }
    if ([action isEqual:@"voice"]) {                                     // 0x9a34 -isEqual: → 0x9a38 cbz w0,#0 → 0x9a48（@fb010 'voice'）
        [self showVoiceInput];                                           // 0x9a40 -showVoiceInput
        return;                                                          // 0x9a44 b 0x9b94
    }
    if ([action isEqual:@"roam"]) {                                      // 0x9a4c @fb090 'roam'
        // 0x9a58 @10ef48 NSConstantArray = @[@"free", @"calm", @"off"]（3 元，非 4 元）
        NSArray *roams = @[@"free", @"calm", @"off"];                    // 0x9a58-0x9a64
        NSUInteger next = ([roams indexOfObject:self.preferences.roam] + 1) % 3;  // 0x9a68-0x9ac0：+1 后 umulh 0xaaab…/lsr → %3
        _PDAIWritePreferences(@{@"Roam": roams[next]});                  // 0x9ac4 @fb110 'Roam' → 0x9ae0 objectAtIndexedSubscript: → 0x9b7c
        [self hideHoverButtons];                                         // 0x9b8c-0x9b90
        return;
    }
    if ([action isEqual:@"sound"]) {                                     // 0x9b00 @fb130 'sound'
        _PDAIWritePreferences(@{@"Sound": @(!self.preferences.soundEnabled)});   // 0x9b0c-0x9b38：w2 = soundEnabled ^ 1（numberWithInt:）；@fb150 'Sound'
        [self hideHoverButtons];                                         // 0x9b8c-0x9b90
        return;
    }
    if ([action isEqual:@"theme"]) {                                     // 0x9b40 @fb170 'theme'
        // 0x9b60-0x9bc8：x8 = @fb1d0 'dark'、x9 = @fb1b0 'light'，csel x8,x9,x8,ne → isDarkAppearance 为真取 'light'（写入即反转）
        _PDAIWritePreferences(@{@"Theme": self.pet.renderer.isDarkAppearance ? @"light" : @"dark"});   // 0x9b78 @fb190 'Theme' → 0x9bd8
        [self hideHoverButtons];                                         // 0x9b8c-0x9b90
        return;
    }
    if ([action isEqual:@"dress"]) {                                     // 0x9bdc @fb1f0 'dress'
        // 0x9be8 @10ef60 NSConstantArray = @[@"maid", @"cape", @"crew", @"sailor"]（4 元）
        NSArray *outfits = @[@"maid", @"cape", @"crew", @"sailor", @"miko", @"dragon", @"nurse", @"winter_deep", @"violet_winter", @"frost_dragon", @"formal", @"starsea", @"eclipse", @"night_gala", @"pale_nurse"];
        NSUInteger idx = [outfits indexOfObject:self.preferences.outfit]; // 0x9bf8-0x9c14
        // 防止运行时尚未识别第五套时，dress 按钮把未知服装静默重置为 maid。
        // 未知 ID 不写偏好，保留当前选择；仅已识别服装参与轮换。
        if (idx == NSNotFound) {
            NSLog(@"[PetDFY/OutfitAudit] dress ignored unknown Outfit=%@", self.preferences.outfit);
            [self hideHoverButtons];
            return;
        }
        NSUInteger next = (idx + 1) % outfits.count;
        _PDAIWritePreferences(@{@"Outfit": outfits[next]});              // 0x9c2c @fb290 'Outfit' → 0x9c48 → b 0x9ae8 建单键字典
        [self hideHoverButtons];                                         // 0x9b8c-0x9b90
        return;
    }
    if ([action isEqual:@"hide"]) {                                      // 0x9c4c @fb2b0 'hide'
        // 0x9c58 @110208 静态单键字典 {@"Enabled": @NO}
        //   值槽 @0x10cba8 为 8 字节立即数 0x4008000000000170；同批静态字典里 get-task-allow=…171（真）、
        //   UseLegacyElementType=…170（假）→ …170 即 @NO。Inferred。
        _PDAIWritePreferences(@{@"Enabled": @NO});                       // 0x9c58-0x9c60 @fb2d0 'Enabled'
        [self hideHoverButtons];                                         // 0x9b8c-0x9b90
        return;
    }
    [self hideHoverButtons];                                             // 0x9cd4 cbz w0 → 0x9b8c：五个 isEqual: 全不中也要收
}
// 一句话：按 sender.tag 索引 hoverActions 取动作名，五路 isEqual: 分发（chat/voice 转调、roam/sound/theme/dress/hide 写偏好），除前两路外一律 hideHoverButtons 收尾。
#pragma mark - 0x9d30 petHoverChanged:point:

/// Observed 0x9d30（0x660 字节 / 408 条）：宠物 hover 状态切换的总入口。
///   hover=NO → 起 1.5s 延时的「收起块」（0xa224 起）；hover=YES → 现搭按钮组（0x9d6c 起）。
- (void)petHoverChanged:(BOOL)hover point:(CGPoint)point {
    if (!hover) {                                                        // 0x9d68 tbz w2,#0 → 0xa224
        if (self.hoverDismissBlock) {                                    // 0xa22c-0xa23c 先探空
            dispatch_block_cancel(self.hoverDismissBlock);                // 0xa244-0xa254
        }
        __weak typeof(self) weakSelf = self;                             // 0xa258-0xa260 objc_initWeak
        dispatch_block_t block = dispatch_block_create(0, ^{             // 0xa2b8-0xa2c0 flags=0；块体 @0xa3cc
            [weakSelf setHoverDismissBlock:nil];                         // 0xa3ec-0xa3fc
            [weakSelf hideHoverButtons];                                 // 0xa400-0xa408
        });
        self.hoverDismissBlock = block;                                  // 0xa2d0 setHoverDismissBlock:
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500000000LL),    // 0xa2d8-0xa2e0 w0=0、w1=0x59682f00=1.5e9ns
                       dispatch_get_main_queue(), block);                // 0xa2e4-0xa2f0 __dispatch_main_q
        return;                                                          // 0xa308
    }
    if (PDIsDeviceLocked()) return;                                   // 0x9d6c-0x9d70（内联静态函数 0x6804）
    if (!self.preferences.enabled) return;                               // 0x9d78-0x9d8c -[enabled] → tbz w0,#0 → 0xa340
    if (!self.root) return;                                              // 0x9d90-0x9db0 cbz x20 → 0xa308
    if (self.hoverDismissBlock) {                                        // 0x9db4-0x9dc8
        dispatch_block_cancel(self.hoverDismissBlock);                    // 0x9dd0-0x9de0
        [self setHoverDismissBlock:nil];                                 // 0x9de4-0x9df0（x2 = 0）
    }
    if (self.hoverButtons.count != 0) return;                            // 0x9df4 起：已挂着就不再重建
    // 标签表：7 键（UTF-16 中文，@0xfb3d0 区；flags=0x7d0 → 按 UTF-16LE 解，不是 ASCII）
    NSDictionary *labels = @{                                            // 0x9e14-0x9f40 w4 = 7
        @"chat":  PDLocalizedString(@"打开聊天输入框"),                    // key @0xfb030 → 值 @0xfb3d0
        @"voice": PDLocalizedString(@"语音输入"),                          // key @0xfb010 → 值 @0xfb3f0
        @"roam":  PDLocalizedString(@"切换自主活动"),                      // key @0xfb090 → 值 @0xfb410
        @"theme": PDLocalizedString(@"切换深浅色"),                        // key @0xfb170 → 值 @0xfb430
        @"sound": PDLocalizedString(@"切换声音"),                          // key @0xfb130 → 值 @0xfb450
        @"dress": PDLocalizedString(@"切换服装"),                          // key @0xfb1f0 → 值 @0xfb470
        @"hide":  PDLocalizedString(@"隐藏角色"),                          // key @0xfb2b0 → 值 @0xfb490
    };
    id order = _PDAIPreference(@"HoverButtons", @[@"chat", @"voice"]);    // 0x9f68-0x9f78 key @0xfb4b0，默认 @0x10ef78
    if (![order isKindOfClass:[NSArray class]]) {                        // 0x9f84-0x9fac tst w0,#1
        order = @[@"chat", @"voice"];                                    // 兜底 @0x10ef90
    }
    NSMutableArray *buttons = [NSMutableArray array];                    // 0x9fb0-0x9fc8
    NSMutableArray *actions = [NSMutableArray array];                    // 0x9fcc-0x9fd4
    for (NSString *key in order) {                                       // 0x9fd8-0xa158 快速枚举
        if (![key isKindOfClass:[NSString class]]) continue;             // 0xa038-0xa050
        NSString *icon = [@{@"chat": @"bubble.left", @"dress": @"tshirt", // 0xa054-0xa068 图标字典 @0x110230
                            @"hide": @"eye.slash", @"roam": @"figure.walk",  //   （原始指针字 @0x10cba0）
                            @"sound": @"speaker.wave.2",                     //   chat→bubble.left、dress→tshirt、
                            @"theme": @"circle.lefthalf.filled",             //   hide→eye.slash、roam→figure.walk、
                            @"voice": @"mic"} objectForKeyedSubscript:key];  //   sound→speaker.wave.2、
        if (!icon) continue;                                             // 0xa06c-0xa070 cbz x0
        if ([buttons count] > 5) continue;                               // 0xa070-0xa084 cmp x0,#5 + cset hi → 上限 6 颗
        // 注：0xa088-0xa0a0 又把图标重取了一次才喂给 hoverIcon:（源为内联写法），此处复用上面的 icon，行为等价。
        UIButton *button = [self hoverIcon:icon                             // 0xa0c0 直接调用（LTO 内联成 bl）
                                    label:[labels objectForKeyedSubscript:key]   // 0xa0a0-0xa0b0
                                   action:@selector(hoverPressed:)];             // x4/x0 = SELREF
        [button setTag:[buttons count]];                                 // 0xa0d4-0xa0e4 tag 即插入序号
        [buttons addObject:button];                                      // 0xa0e8-0xa0f0
        [actions addObject:key];                                         // 0xa0f4-0xa0fc
        [self.root.view addSubview:button];                              // 0xa100-0xa120
    }
    [self setHoverButtons:buttons];                                      // 0xa15c-0xa164
    [self setHoverActions:actions];                                      // 0xa168-0xa170
    __weak typeof(self) weakSelf = self;                                 // 0xa174-0xa17c objc_initWeak
    self.pet.hoverPositionHandler = ^(CGPoint point, CGSize reach) {      // 0xa1e8 setHoverPositionHandler:
        [weakSelf layoutHoverButtonsAt:point reach:reach.width];          // 块体 @0xa41c-0xa458（d2 = size.width）
    };
}
// 一句话：锁屏/偏好/root 三道闸放行后，按 HoverButtons 顺序（默认 chat、voice）建最多 6 颗钮、tag 编号、挂到 root.view，并把「跟随位置重排」的弱引用回调装到 pet 上；hover=NO 时改为取消旧块、起 1.5s 延时收起块。
#pragma mark - 0xc3c8 performCommand:

/// Observed 0xc3c8（0x228 字节 / 138 条）：外部命令串的总分发。
- (void)performCommand:(id)command {
    if ([command isEqual:@"dataMaintenance"]) {                          // 0xc3ec-0xc3fc @fb5b0
        // 0xc400-0xc418：CFPreferencesCopyAppValue(CFSTR("DataMaintenanceRequest") @0xfb5d0,
        //                                           CFSTR("com.susudear.petdfyprefs") @0xf9bb8)
        id request = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("DataMaintenanceRequest"),
                                                                    CFSTR("com.susudear.petdfyprefs"));
        [self.ai.service handleDataMaintenanceRequest:request];           // 0xc41c-0xc43c
        return;                                                          // 0xc448
    }
    if (!self.preferences.enabled) return;                               // 0xc44c-0xc460 -[enabled] → cbz w0
    if (PDIsDeviceLocked()) return;                                   // 0xc464-0xc470（内联静态函数 0x6804）
    [self updateVisibility];                                             // 0xc474-0xc478
    if (!self.pet) return;                                               // 0xc47c-0xc490 cbz x20
    if ([command isEqual:@"chat"]) {                                     // 0xc494-0xc4a4 @fb030
        [self showChat];                                                 // 0xc4a8
        return;                                                          // 0xc4b0
    }
    [self.pet cancelInteraction];                                        // 0xc4b4-0xc4c8 任何非 chat 命令先掐掉当前交互
    WNMotion *motion = self.pet.renderer.liveRig.motion;                 // 0xc4cc-0xc508（renderer→liveRig→motion）
    if ([command isEqual:@"reset"]) {                                    // 0xc50c-0xc51c @fb5f0
        [self.pet.renderer resetLiveWithScheme:self.loadedAppearance     // 0xc520-0xc558（scheme = loadedAppearance）
                                    freeGround:NO];                      //   w3 = 0
        [self setLastSize:CGSizeZero];                                   // 0xc568-0xc578 ldp d0,d1,[_CGSizeZero]
        [self applyAppearance];                                          // 0xc57c-0xc580
        [self layoutPet];                                                // 0xc584-0xc588
        return;                                                          // 0xc58c
    }
    if ([motion doWord:command]) {                                       // 0xc590-0xc59c 其余命令都当「动作词」
        [motion setRoamHoldUntil:motion.roamHoldUntil + 8.0];            // 0xc5a0-0xc5bc fmov d1,#8.0 → fadd → setter
    }
}
// 一句话：dataMaintenance 走 CFPreferences 读请求转发给 ai.service；其余命令过偏好/锁屏闸后先 updateVisibility，chat 直转 showChat，reset 重置渲染与尺寸，剩下全部交给 motion doWord: 并把 roam 冻结期推到 now+8s。

@end
