//
//  PDPreferences.m
//  逆向还原 v2：reload 按二进制 0x42d04 (612 B) 逐条重写
//
//  二进制实测（arm64e, PetDFY.arm64e.dylib）：
//    domain      com.susudear.petdfyprefs
//    +0x08 _enabled                    ReadBool("Enabled")                 默认 YES
//    +0x09 _interactive                ReadBool("Interactive")             默认 YES
//    +0x0a _responsive                 ReadBool("Responsive")              默认 YES
//    +0x0b _soundEnabled               ReadBool("Sound")                   默认 YES
//    +0x0c _stroking                   InputMode == "stroke"               默认 "grab"
//    +0x0d _keyboardAvoidanceEnabled   ReadBool("KeyboardAvoidanceEnabled")默认 YES
//    +0x10 _size                       Size(128,72,220) * PetScale(1.0,0.5,10.0)
//    +0x18 _bottomInset                BottomInset(12,0,Size)  上限跟随 Size 读取值
//    +0x20 _keyboardAvoidanceExtra     KeyboardAvoidanceExtra(0,0,Size)
//    +0x28 _framesPerSecond            FPS(60,30,120) 量化为 {30,60,120}
//    +0x30 _scheme                     Scheme(默认 "deepseek")
//    +0x38 _outfit                     Outfit(默认 "maid")
//    +0x40 _roam                       Roam(默认 "free")
//    +0x48 _doubleTapAction            DoubleTapAction(默认 "none")
//    +0x50 _longPressAction            LongPressAction(默认 "menu")
//
//  允许集取自 dylib 字符串表候选值（Assumed，验证动作见文件尾）。
//

#import "PDPreferences.h"

static NSString * const kPDPreferencesDomain = @"com.susudear.petdfyprefs";

// 二进制中为全局 C 函数（符号 _PDAIPreference / _PDAINumber），此处等价实现
static id PDReadRaw(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key,
        (__bridge CFStringRef)kPDPreferencesDomain));
}

static BOOL PDReadBool(NSString *key) {
    id v = PDReadRaw(key);
    if (!v) return YES;                    // 二进制默认值硬编码为 1
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    return YES;
}

static NSString *PDReadString(NSString *key, NSArray *allowed, NSString *fallback) {
    id v = PDReadRaw(key);
    if ([v isKindOfClass:[NSString class]] && [allowed containsObject:v]) return v;
    return fallback;
}

static double PDReadNumber(NSString *key, double def, double lo, double hi) {
    id v = PDReadRaw(key);
    double d = [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : def;
    if (isnan(d)) d = def;
    if (d > hi) d = hi;
    if (d < lo) d = lo;
    return d;
}

@implementation PDPreferences

- (id)init {
    self = [super init];
    if (self) {
        [self reload];
    }
    return self;
}

- (void)reload {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPDPreferencesDomain);

    _enabled = PDReadBool(@"Enabled");
    _interactive = PDReadBool(@"Interactive");
    _responsive = PDReadBool(@"Responsive");
    _soundEnabled = PDReadBool(@"Sound");

    _stroking = [PDReadString(@"InputMode", @[@"grab", @"stroke"], @"grab") isEqualToString:@"stroke"];

    double sizeValue = PDReadNumber(@"Size", 128.0, 72.0, 220.0);
    _size = sizeValue * PDReadNumber(@"PetScale", 1.0, 0.5, 10.0);

    _bottomInset = PDReadNumber(@"BottomInset", 12.0, 0.0, sizeValue);

    long long fps = (long long)PDReadNumber(@"FPS", 60.0, 30.0, 120.0);
    _framesPerSecond = fps > 99 ? 120 : (fps > 44 ? 60 : 30);

    _keyboardAvoidanceEnabled = PDReadBool(@"KeyboardAvoidanceEnabled");
    _keyboardAvoidanceExtra = PDReadNumber(@"KeyboardAvoidanceExtra", 0.0, 0.0, sizeValue);

    _scheme = [PDReadString(@"Scheme", @[@"deepseek", @"harness", @"chatgpt", @"claude", @"gemini", @"qwen", @"kimi", @"minimax"], @"deepseek") copy];
    // Diagnostic: distinguish persisted Outfit from the in-memory fallback.
    // Read-only: never write a fallback value to CFPreferences.
    id rawOutfit = PDReadRaw(@"Outfit");
    NSArray *allowedOutfits = @[@"maid", @"cape", @"crew", @"sailor", @"miko", @"dragon", @"nurse", @"winter_deep", @"violet_winter", @"frost_dragon", @"formal", @"starsea", @"eclipse", @"night_gala", @"pale_nurse"];
    BOOL validOutfit = [rawOutfit isKindOfClass:[NSString class]] &&
                       [allowedOutfits containsObject:rawOutfit];
    NSString *effectiveOutfit = validOutfit ? rawOutfit : @"maid";
    if (!validOutfit && rawOutfit != nil) {
        NSLog(@"[PetDFY/OutfitAudit] invalid stored Outfit=%@; using in-memory fallback=maid (not persisted)", rawOutfit);
    }
    _outfit = [effectiveOutfit copy];
    _roam = [PDReadString(@"Roam", @[@"free", @"fixed"], @"free") copy];
    _doubleTapAction = [PDReadString(@"DoubleTapAction", @[@"none", @"voice", @"chat", @"clip"], @"clip") copy];
    _longPressAction = [PDReadString(@"LongPressAction", @[@"menu", @"chat", @"none"], @"menu") copy];
}

// ---- 兼容层：二进制中这些是内联的全局 C 调用，类方法本身不存在 ----

+ (instancetype)shared {
    static PDPreferences *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[PDPreferences alloc] init]; });
    return shared;
}

// [非二进制] - stringForKey:fallback: 二进制无此 selector；兼容层实现，走 CFPreferences。
- (NSString *)stringForKey:(NSString *)key fallback:(NSString *)fallback {
    id v = PDReadRaw(key);
    if ([v isKindOfClass:[NSString class]]) return v;
    return fallback;
}

// [非二进制] - boolForKey:fallback: 二进制无此 selector；兼容层实现，走 CFPreferences。
- (BOOL)boolForKey:(NSString *)key fallback:(BOOL)fallback {
    id v = PDReadRaw(key);
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    return fallback;
}

// [非二进制] - doubleForKey:fallback: 二进制无此 selector；兼容层实现，走 CFPreferences。
- (double)doubleForKey:(NSString *)key fallback:(double)fallback {
    id v = PDReadRaw(key);
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
    return fallback;
}

// [非二进制] - integerForKey:fallback:min:max: 二进制无此 selector；兼容层实现，走 CFPreferences。
- (long long)integerForKey:(NSString *)key fallback:(long long)fallback
                       min:(long long)lo max:(long long)hi {
    long long i = (long long)[self doubleForKey:key fallback:(double)fallback];
    if (i < lo) i = lo;
    if (i > hi) i = hi;
    return i;
}

// [非二进制] - setString:forKey: 二进制无此 selector；兼容层实现，走 CFPreferences。
- (void)setString:(NSString *)value forKey:(NSString *)key {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFStringRef)value,
                             (__bridge CFStringRef)kPDPreferencesDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPDPreferencesDomain);
    [self reload];
}

// [非二进制] - setDouble:forKey: 二进制无此 selector；兼容层实现，走 CFPreferences。
- (void)setDouble:(double)value forKey:(NSString *)key {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFNumberRef)@(value),
                             (__bridge CFStringRef)kPDPreferencesDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPDPreferencesDomain);
    [self reload];
}



@end


#pragma mark - 全局 C 辅助

id _PDAIPreference(NSString *key, id fallback) {
    id v = PDReadRaw(key);
    return v ?: fallback;
}

void _PDAIWritePreferences(NSDictionary *values) {
    if (![values isKindOfClass:[NSDictionary class]]) return;
    [values enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        CFPreferencesSetAppValue((__bridge CFStringRef)k,
                                 (__bridge CFPropertyListRef)v,
                                 (__bridge CFStringRef)kPDPreferencesDomain);
    }];
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPDPreferencesDomain);
}

NSDictionary *_PDAIDirectSettings(void) {
    CFDictionaryRef d = CFPreferencesCopyMultiple(NULL,
                                                  (__bridge CFStringRef)kPDPreferencesDomain,
                                                  kCFPreferencesCurrentUser,
                                                  kCFPreferencesAnyHost);
    NSDictionary *out = CFBridgingRelease(d);
    return out ?: @{};
}


