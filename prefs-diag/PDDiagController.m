//
//  PDDiagController.m — 设置里的「素材诊断」页
//
//  不链接 Preferences.framework：运行时用 objc_allocateClassPair 从
//  PSListController 派生一个子类并注册方法，避免依赖私有头文件。
//  页面内容直接读 dylib 生成的 petdfy-report.txt。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kDiagReportCandidates[] = { 0 };

static NSString *PDDiagDataDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *cands = @[
        @"/var/mobile/Library/Application Support/PetDFY",
        @"/var/jb/var/mobile/Library/Application Support/PetDFY",
    ];
    for (NSString *c in cands) {
        if ([fm fileExistsAtPath:c]) return c;
    }
    // RootHide：扫描 jbroot
    NSArray *bases = @[@"/var/containers/Bundle/Application", @"/"];
    for (NSString *base in bases) {
        NSArray *kids = [fm contentsOfDirectoryAtPath:base error:NULL];
        for (NSString *k in kids) {
            if (![k hasPrefix:@".jbroot"]) continue;
            NSString *p = [base stringByAppendingPathComponent:k];
            NSString *full = [p stringByAppendingPathComponent:@"var/mobile/Library/Application Support/PetDFY"];
            if ([fm fileExistsAtPath:full]) return full;
        }
    }
    return cands[0];
}

static NSString *PDDiagReportText(void) {
    NSString *p = [PDDiagDataDir() stringByAppendingPathComponent:@"petdfy-report.txt"];
    NSString *t = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
    if (t.length) return t;
    NSString *log = [PDDiagDataDir() stringByAppendingPathComponent:@"petdfy-diag.log"];
    NSString *l = [NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:NULL];
    if (l.length) {
        return [NSString stringWithFormat:
                @"（还没有生成结构化报告，以下为原始日志）\n\n文件: %@\n\n%@", log, l];
    }
    return [NSString stringWithFormat:
            @"还没有诊断数据。\n\n可能原因：\n"
            @"1) 插件未在 SpringBoard 加载（越狱注入未生效）\n"
            @"2) 安装后没有 respring\n\n"
            @"诊断目录: %@", PDDiagDataDir()];
}

#pragma mark - 运行时方法

static void pd_viewDidLoad(id self, SEL _cmd) {
    UIViewController *vc = (UIViewController *)self;
    vc.view.backgroundColor = [UIColor systemBackgroundColor];

    UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tv.editable = NO;
    tv.alwaysBounceVertical = YES;
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.text = PDDiagReportText();
    tv.tag = 0x50444659;   // 'PDFY'
    [vc.view addSubview:tv];

    vc.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"刷新"
                                         style:UIBarButtonItemStylePlain
                                        target:nil
                                        action:nil];
}

static void pd_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    UIViewController *vc = (UIViewController *)self;
    for (UIView *v in vc.view.subviews) {
        if (v.tag == 0x50444659 && [v isKindOfClass:[UITextView class]]) {
            ((UITextView *)v).text = PDDiagReportText();
        }
    }
}

static id pd_specifiers(id self, SEL _cmd) {
    return @[];
}

static id pd_title(id self, SEL _cmd) {
    return @"素材诊断";
}

#pragma mark - 注册子类

__attribute__((constructor))
static void PDRegisterDiagController(void) {
    Class base = NSClassFromString(@"PSListController");
    if (!base) base = NSClassFromString(@"PSViewController");
    if (!base) return;
    if (NSClassFromString(@"PDDiagListController")) return;

    Class cls = objc_allocateClassPair(base, "PDDiagListController", 0);
    if (!cls) return;

    class_addMethod(cls, @selector(viewDidLoad), (IMP)pd_viewDidLoad, "v@:");
    class_addMethod(cls, @selector(viewWillAppear:), (IMP)pd_viewWillAppear, "v@:B");
    class_addMethod(cls, @selector(specifiers), (IMP)pd_specifiers, "@@:");
    class_addMethod(cls, @selector(title), (IMP)pd_title, "@@:");

    objc_registerClassPair(cls);
}