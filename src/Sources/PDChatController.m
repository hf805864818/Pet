//
//  PDChatController.m — 逆向还原：聊天界面
//
//  还原依据：PetDFY.dylib arm64e，189 个方法共 9364 条指令（全包最大）
//  本文件：UI 构建 / 气泡布局 / 发送 / 逐字显示 / 语音（核心 15 个方法）
//
//  ivar（size=472，62 个字段）：
//    _optionsVisible / _preparingImages / _returnSends / _busy / _closed
//    _talkSound / _usingDoubao / _pendingDictation / _dictationManualSend
//    _dictationScrollPending  BOOL
//    _keyboardFocusHandler / _talkHandler / _sendHandler / _answerHandler
//    _confirmationShownHandler / _actionsHandler / _bodyBusyProvider
//    _soundEnabledProvider  block
//    _queue  NSMutableArray *      待播队列
//    _current / _beat  NSDictionary *  当前/正在播放的条目
//    _optionButtons  NSMutableArray *
//    _beatIndex  long long         _anchorIndex  NSUInteger
//    _bubbleSize double
//
//  关键方法：
//    layoutBubbles     1130  气泡布局（最大）
//    updateColors       571  深色模式配色
//    buildUI            415  建界面
//    revealNext         396  逐字显示
//    layoutComposer:unit: 379  输入框布局
//    reloadPreferences  301  重载配置
//    beginBeat          293  开始播放一条
//    send               263  发送
//    startSpeech        261  朗读
//    applyDictationText: 235  听写回填
//    refreshImages      234  图片按钮刷新
//    startVoiceInput    232  语音输入
//

#import "PDChatController.h"
#import "PDChatService.h"
#import "PDPreferences.h"
#import "PDSpeechBubbleView.h"
#import "PDComposerTextView.h"
#import "PDSoundPlayer.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>





@interface PDChatController ()
// [非二进制] 以下三个为编造模型：二进制无 card / table / messages。
//   真实结构：_queue(NSMutableArray 待播队列) + _current + _beat(逐字播放条目)
//            + _userBubbles / _replyBubble / _replyScroll 手动布局，无 UITableView。
//   待重写：layoutBubbles(1130) / beginBeat(293) / revealNext(396)
//          / enqueuePresentation: / rushQueuedLines(1333)
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) id composer;
@end

@implementation PDChatController


#pragma mark - 生命周期

/// 0x181c0  232 B。只做三件事 + 两个键盘通知；不建视图、不读偏好。
- (void)viewDidLoad {
    [super viewDidLoad];
    [[self view] setAccessibilityIdentifier:@"pet-chat-bubbles"];
    [self buildUI];
    [self updateColors];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self
           selector:@selector(keyboardChanged:)
               name:UIKeyboardWillChangeFrameNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(keyboardHidden:)
               name:UIKeyboardWillHideNotification
             object:nil];
}

#pragma mark - 建界面

/// 415 条指令。建卡片 + 表格 + 输入框。
/// 0x18330  1660 B。真实视图层级：根 → 回复气泡(内含 scroll+label+3 点) / 输入气泡(内含 frame+outline+composer+send+close+tray)。
- (void)buildUI {
    self.replyBubble = [PDSpeechBubbleView new];
    [self.replyBubble setTail:YES];
    [self.replyBubble setHidden:YES];
    [[self view] addSubview:self.replyBubble];

    self.replyScroll = [UIScrollView new];
    [self.replyScroll setShowsVerticalScrollIndicator:NO];
    [self.replyScroll setDelegate:self];
    [self.replyScroll setContentInsetAdjustmentBehavior:2];
    [self.replyBubble addSubview:self.replyScroll];

    self.replyLabel = [UILabel new];
    [self.replyLabel setNumberOfLines:0];
    [self.replyLabel setLineBreakMode:1];
    [self.replyScroll addSubview:self.replyLabel];

    // 三个思考点，倒序建、正序动画
    NSMutableArray *dots = [NSMutableArray new];
    for (NSInteger i = 3; i > 0; i--) {
        CAShapeLayer *dot = [CAShapeLayer layer];
        [[self.replyBubble layer] addSublayer:dot];
        [dots addObject:dot];
    }
    [self setDots:dots];

    self.inputBubble = [PDSpeechBubbleView new];
    [self.inputBubble setTail:YES];
    [self.inputBubble setHidden:YES];
    [[self view] addSubview:self.inputBubble];

    self.inputFrame = [UIView new];
    [self.inputBubble addSubview:self.inputFrame];

    self.inputOutline = [CAShapeLayer layer];
    [[self.inputFrame layer] addSublayer:self.inputOutline];

    self.composer = [PDComposerTextView new];
    [self.composer setDelegate:self];
    [self.composer setImagePasteHandler:^(NSArray *images) {
        [self pasteImages:images];
    }];

    self.imageTray = [UIView new];
    [self.inputBubble addSubview:self.imageTray];

    [self.composer setAccessibilityLabel:PDLocalizedString(@"输入想说的话")];
    [self.composer setReturnKeyType:[self returnSends] ? 7 : 0];
    [self.inputFrame addSubview:self.composer];

    self.sendButton = [self button:PDLocalizedString(@"发送") action:@selector(send)];
    [self.inputFrame addSubview:self.sendButton];

    self.closeButton = [self button:@"×" action:@selector(hideComposer)];
    [self.closeButton setAccessibilityLabel:PDLocalizedString(@"关闭输入框")];
    [self.inputBubble addSubview:self.closeButton];
}

/// 571 条指令。深浅色配色。
- (void)updateColors {
    BOOL dark = NO;
    if (@available(iOS 12.0, *)) {
        dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    UIColor *cardBG = dark
        ? [UIColor colorWithRed:0.13 green:0.13 blue:0.15 alpha:0.96]
        : [UIColor colorWithRed:0.97 green:0.97 blue:0.98 alpha:0.96];
    UIColor *text = dark ? [UIColor whiteColor] : [UIColor blackColor];

    _card.backgroundColor = cardBG;
    _composer.textColor = text;
    [_table reloadData];
}

#pragma mark - 布局

/// 0x1d53c。属性串：行距 = 字号 × 0.25，按词换行。
static NSAttributedString *PDAttributedLine(NSString *text, UIFont *font, UIColor *color) {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    [ps setLineSpacing:[font pointSize] * 0.25];
    [ps setLineBreakMode:NSLineBreakByWordWrapping];
    return [[NSAttributedString alloc] initWithString:(text ?: @"")
                                          attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: ps,
    }];
}

/// 0x1c3b0  4492 B。全部气泡的手工排版，全程关掉隐式动画。
/// 顺序：回复气泡（思考点 / 文字 + 选项 + 自带输入框）→ 用户气泡自底向上堆。
- (void)layoutBubbles {
    CGFloat viewW = [[self view] bounds].size.width;
    if (viewW <= 0) return;
    if ([self closed]) return;

    // 缩放基准：视宽 0.46 摊到 255 上，再乘气泡尺寸倍率
    CGFloat s = viewW * 0.46 / 255.0;
    double unit = s * [self bubbleSize];
    [self setUnit:unit];

    // 锚点：拖过确认条就用拖过的位置，否则默认屏幕下方 72%
    CGPoint anchor = [self confirmationPinned] ? [self confirmationAnchor] : [self anchorPoint];
    CGFloat ax = anchor.x;
    CGFloat ay = anchor.y;
    if (ax == 0 && ay == 0) {
        ax = viewW * 0.5;
        ay = [[self view] bounds].size.height * 0.72;
    }

    CGFloat maxBubbleW = MIN(viewW - 20 * unit, viewW * 0.46 * [self bubbleSize]);
    ay = MIN(ay, [[self view] bounds].size.height);

    // 可用底边：锚点往上让 8；键盘弹出且与视图相交时再压到键盘顶
    CGFloat avail = ay - 8 * unit;
    if ([[self composer] isFirstResponder]) {
        CGFloat saved = avail;
        if (CGRectIntersectsRect([[self view] bounds], [self keyboardFrame])) {
            avail = MIN(saved, CGRectGetMinY([self keyboardFrame]) - 8 * unit);
        }
    }

    CGFloat anchorX = ax;
    CGFloat replyCenter = ax + 26 * unit;
    CGFloat lastBottom = avail;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    if ([[self inputBubble] isHidden]) {
        /* ---- 回复气泡 ---- */
        if (![[self replyBubble] isHidden]) {
            if ([self busy]) {
                lastBottom = [self placeBubble:[self replyBubble]
                                          size:CGSizeMake(50 * unit, 40 * unit)
                                        bottom:avail
                                        center:replyCenter];
                NSArray *dots = [self dots];
                NSUInteger dotCount = [dots count];
                if (dotCount) {
                    CGFloat dotY = 14 * unit;
                    CGFloat dotSide = 3 * unit;
                    NSUInteger dotX = 18;
                    for (NSUInteger i = 0; i < dotCount; i++) {
                        UIView *dot = dots[i];
                        [dot setFrame:CGRectMake(unit * dotX, dotY, dotSide, dotSide)];
                        ((CAShapeLayer *)[dot layer]).path = [UIBezierPath bezierPathWithOvalInRect:[dot bounds]].CGPath;
                        dotX += 5;
                    }
                }
            } else {
                BOOL isAsk = [[[self current] objectForKeyedSubscript:@"kind"] isEqual:@"ask"];

                UIFont *font = [UIFont systemFontOfSize:(s * 14.5) * [self fontSize]];
                [[self replyLabel] setFont:font];

                NSString *text = [[self replyLabel] text];
                if ([text length] == 0) text = @" ";
                [[self replyLabel] setAttributedText:PDAttributedLine(text,
                                                                     [[self replyLabel] font],
                                                                     [[self replyLabel] textColor])];

                CGSize measured = [[[self replyLabel] attributedText]
                    boundingRectWithSize:CGSizeMake(maxBubbleW - 33 * unit, CGFLOAT_MAX)
                                 options:3
                                 context:NULL].size;

                // ask 一律占满最大宽，say 按实测宽度收
                CGFloat bubbleW = maxBubbleW;
                if (!isAsk) {
                    bubbleW = MAX(50 * unit, ceil(measured.width) + 33 * unit);
                    bubbleW = MIN(maxBubbleW, bubbleW);
                }

                CGFloat labelW = bubbleW - 32 * unit;
                CGFloat contentH = MAX([[[self replyLabel] font] lineHeight], ceil(measured.height));
                [[self replyLabel] setFrame:CGRectMake(0, 0, labelW, contentH)];

                // 选项按钮：量宽用 bubbleW-48，实际框用 bubbleW-32
                if (isAsk && [self optionsVisible]) {
                    CGFloat optFontBase = s * 13;
                    CGFloat optInsetV = 6 * unit;
                    CGFloat optInsetH = 8 * unit;
                    CGFloat optMeasureW = bubbleW - 48 * unit;
                    for (UIButton *btn in [self optionButtons]) {
                        [[btn titleLabel] setFont:[UIFont systemFontOfSize:optFontBase * [self fontSize]]];
                        [btn setContentEdgeInsets:UIEdgeInsetsMake(optInsetV, optInsetH,
                                                                   optInsetV, optInsetH)];
                        CGSize sz = [[btn titleLabel] sizeThatFits:CGSizeMake(optMeasureW, CGFLOAT_MAX)];
                        CGFloat btnH = MAX(28 * unit, sz.height + 12 * unit);
                        [btn setFrame:CGRectMake(0, contentH + 6 * unit, labelW, btnH)];
                        [btn layer].cornerRadius = optInsetH;
                        [btn layer].borderWidth = unit;
                        contentH += btnH + 6 * unit;
                    }
                }

                // own 的条目自带输入框
                if ([[[self current] objectForKeyedSubscript:@"own"] boolValue]) {
                    double composerH = [self layoutComposer:labelW unit:unit];
                    [[self inputFrame] setFrame:CGRectMake(0, contentH + 8 * unit, labelW, composerH)];
                    contentH += composerH + 8 * unit;
                }

                CGFloat bubbleH = 35 * unit + [[[self replyLabel] font] lineHeight];
                bubbleH = MAX(bubbleH, MIN([[self view] bounds].size.height * 0.35,
                                           avail - [[self view] safeAreaInsets].top - 65 * unit));
                bubbleH = MIN(bubbleH, contentH + 35 * unit);

                lastBottom = [self placeBubble:[self replyBubble]
                                          size:CGSizeMake(bubbleW, bubbleH)
                                        bottom:avail
                                        center:replyCenter];

                [[self replyScroll] setFrame:CGRectMake(16 * unit, 12.5 * unit,
                                                        labelW, bubbleH - 35 * unit)];
                [[self replyScroll] setContentSize:CGSizeMake(labelW, contentH)];

                if (isAsk) {
                    [[self closeButton] setFrame:CGRectMake(bubbleW - 25 * unit, 2 * unit,
                                                            22 * unit, 22 * unit)];
                    [[[self closeButton] titleLabel] setFont:[UIFont systemFontOfSize:18 * unit]];
                }
            }
        }
    } else {
        /* ---- 输入气泡 ---- */
        CGFloat composerW = maxBubbleW - 46 * unit;
        double composerH = [self layoutComposer:composerW unit:unit];

        // 图片按钮一行排开，单边最大 42u，按剩余宽均分
        NSArray *images = [self imageButtons];
        NSUInteger imageCount = [images count];
        CGFloat itemSide = 0;
        if (imageCount) {
            CGFloat fit = (-4 * unit) * (imageCount - 1) + composerW;
            itemSide = MIN(42 * unit, fit / imageCount);
        }
        CGFloat trayH = (itemSide > 0) ? (8 * unit + itemSide) : 0;

        [[self imageTray] setHidden:(imageCount == 0)];
        [[self imageTray] setFrame:CGRectMake(16 * unit, 12.5 * unit, composerW, trayH)];

        if (imageCount) {
            CGFloat step = itemSide + 4 * unit;
            for (NSUInteger i = 0; i < imageCount; i++) {
                UIView *btn = images[i];
                [btn setFrame:CGRectMake(step * i, 0, itemSide, itemSide)];
            }
        }

        lastBottom = [self placeBubble:[self inputBubble]
                                  size:CGSizeMake(maxBubbleW, 35 * unit + composerH + trayH)
                                bottom:avail
                                center:replyCenter];

        [[self inputFrame] setFrame:CGRectMake(16 * unit, 12.5 * unit + trayH,
                                               composerW, composerH)];
        [[self closeButton] setFrame:CGRectMake(maxBubbleW - 30 * unit, 5 * unit,
                                                24 * unit, 24 * unit)];
    }

    // 中心线跟着当前气泡走；两个都藏起来时退回锚点
    CGFloat centerX = anchorX;
    if ([[self inputBubble] isHidden]) {
        if (![[self replyBubble] isHidden]) centerX = CGRectGetMidX([[self replyBubble] frame]);
    } else {
        centerX = CGRectGetMidX([[self inputBubble] frame]);
    }

    // 用户气泡自底向上堆，每页 7 行，超了挪进 toRemove 换页
    NSMutableArray *toRemove = [NSMutableArray array];
    CGFloat bottom = lastBottom - 8 * unit;
    CGFloat labelMaxW = maxBubbleW - 33 * unit;
    CGFloat userFontBase = s * 14.5;
    NSUInteger linesSoFar = 0;

    for (UIView *bubble in [[self userBubbles] reverseObjectEnumerator]) {
        UILabel *label = [[bubble subviews] firstObject];
        [label setFont:[UIFont systemFontOfSize:userFontBase * [self fontSize]]];
        [label setAttributedText:PDAttributedLine([label text], [label font], [label textColor])];

        CGSize sz = [label sizeThatFits:CGSizeMake(labelMaxW, CGFLOAT_MAX)];
        UIFont *labelFont = [label font];
        CGFloat lineH = [labelFont lineHeight] + [labelFont pointSize] * 0.25;
        CGFloat bubbleH = MIN(sz.height, 6 * lineH);
        CGFloat bubbleW = MIN(maxBubbleW, MAX(46 * unit, ceil(sz.width) + 33 * unit));

        // 这条占几行（1~6），用来算换页
        NSUInteger pages = (NSUInteger)ceil(sz.height / lineH - 0.01);
        if (pages < 1) pages = 1;
        if (pages > 6) pages = 6;

        NSUInteger lines = linesSoFar + pages;
        if (linesSoFar != 0 && lines >= 7) {
            [toRemove addObject:bubble];
            continue;
        }

        CGFloat top = bottom - (bubbleH + 25 * unit);
        [bubble setHidden:(top < [[self view] safeAreaInsets].top + 8 * unit)];
        bottom = [self placeBubble:bubble
                              size:CGSizeMake(bubbleW, bubbleH + 25 * unit)
                            bottom:bottom
                            center:centerX];
        bottom = bottom - 8 * unit;
        [label setFrame:CGRectMake(16 * unit, 12.5 * unit, bubbleW - 32 * unit, bubbleH)];
        linesSoFar = lines;
    }

    for (UIView *bubble in [toRemove copy]) {
        [bubble removeFromSuperview];
        [[self userBubbles] removeObject:bubble];
    }

    [CATransaction commit];
    [self notifyConfirmationShown];
}

/// 379 条指令。输入框布局与字号。
- (double)layoutComposer:(CGFloat)width unit:(double)unit {
    double u = unit > 0 ? unit : 1.0;
    CGFloat size = 15.0 * u;
    if (size < 11) size = 11;
    if (size > 26) size = 26;

    UIFont *f = [UIFont systemFontOfSize:size];
    if (![_composer.font isEqual:f]) _composer.font = f;

    CGFloat inset = 8.0 * u;
    _composer.textContainerInset = UIEdgeInsetsMake(inset, 10, inset, 10);

    // 输入框高度 = 文本实测高 + 上下内边距，返回给调用方做气泡让位
    CGSize fit = [_composer sizeThatFits:CGSizeMake(width, 1.0e9)];
    double height = MAX(fit.height, 36.0 * u);
    return height;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _card.frame = self.view.bounds;
    [self layoutBubbles];
}

#pragma mark - 偏好

/// 1204 字节。重载配置。
/// 反汇编 0x1b490：回车键 → 气泡/字号/速度 → 声音 → speechSettings → 失效处理
static inline double PDClampD(double v, double lo, double hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

- (void)reloadPreferences {
    // 1. 回车键：send → UIReturnKeySend(7)，否则 Default(0)
    NSString *action = PDAIPreference(@"ChatReturnKeyAction", @"newline");
    [self setReturnSends:[action isEqual:@"send"]];

    NSUInteger wantKey = [self returnSends] ? 7 : 0;
    if ([self composer] && [[self composer] returnKeyType] != wantKey) {
        [[self composer] setReturnKeyType:wantKey];
        if ([[self composer] isFirstResponder])
            [[self composer] reloadInputViews];
    }

    // 2. 气泡尺寸 / 字号 / 速度（默认 1.0，钳制范围见下）
    [self setBubbleSize:PDClampD(PDAINumber(PDAIPreference(@"BubbleSize", @""), 1.0), 0.8, 1.6)];
    [self setFontSize:PDClampD(PDAINumber(PDAIPreference(@"FontSize", @""), 1.0), 0.8, 1.6)];
    [self setBubbleSpeed:PDClampD(PDAINumber(PDAIPreference(@"BubbleSpeed", @""), 1.0), 0.5, 2.0)];

    // 3. 提示音
    [self setTalkSound:[PDAIPreference(@"AIChatSound", @YES) boolValue]];

    // 4. 语音参数快照（8 项，参与相等比较以决定是否打断当前朗读）
    NSDictionary *settings = @{
        @"mode":         PDAIPreference(@"AISpeechMode", @"native"),
        @"speaker":      PDAIPreference(@"AIDoubaoSpeaker", @""),
        @"instruction":  PDAIPreference(@"AIDoubaoInstruction", @""),
        @"pitch":        PDAIPreference(@"AIDoubaoPitch", @""),
        @"speechRate":   PDAIPreference(@"AIDoubaoSpeechRate", @""),
        @"loudnessRate": PDAIPreference(@"AIDoubaoLoudnessRate", @""),
        @"keyRevision":  PDAIPreference(@"AIDoubaoKeyRevision", @""),
        @"enabled":      @([self speechAllowed]),
    };

    if ([self speechSettings] && ![[self speechSettings] isEqual:settings]) {
        [self stopSpeech];
        // 已读完 → 提前收起
        if ([self answer] && [self shownLength] >= [[self answer] length])
            [self scheduleDismiss];
    }
    [self setSpeechSettings:settings];

    if ([self isViewLoaded])
        [[self view] setNeedsLayout];
}

#pragma mark - 发送

/// 263 条指令。发送消息。
/// 反汇编：pendingDictation → dictation → isActive → setDictationManualSend:
- (void)send {
    if (_busy || _closed) return;

    NSString *text = [_composer.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) return;

    // 听写中的情况：先结束听写
    if (_pendingDictation && _dictation && [_dictation respondsToSelector:@selector(isActive)]) {
        _dictationManualSend = YES;
    }

    _busy = YES;
    _composer.text = @"";

    // 加入消息列表
    [_messages addObject:@{@"role": @"user", @"text": text}];
    [_table reloadData];
    [self layoutBubbles];

    // 回调
    if (_sendHandler) _sendHandler(text);

    // 占位：AI 回复中
    [_messages addObject:@{@"role": @"assistant", @"text": @"…", @"pending": @YES}];
    [_table reloadData];
    [self layoutBubbles];
}

/// 263→追加：接收 AI 回复。

#pragma mark - 逐字显示

/// 293 条指令。开始播放一条（逐字显示）。
// 0x1ff58  1164 B。为 current 铺一个 beat：ask 走 question 单拍，say 走 beats 数组逐拍。
- (void)beginBeat {
    if (![self current]) return;

    [self stopReveal];
    [[self replyScroll] setContentOffset:CGPointZero];
    [self setAnchorIndex:0];
    [self setShownLength:0];
    [self stopSpeech];

    if ([[[self current] objectForKeyedSubscript:@"kind"] isEqual:@"ask"]) {
        NSDictionary *inner = @{
            @"text":    [[self current] objectForKeyedSubscript:@"question"] ?: @"",
            @"actions": @[],
            @"anchors": @[]
        };
        [self setBeat:inner];

        // ask 单拍时关闭钮挂在回复气泡上，且立刻可见
        [[self replyBubble] addSubview:[self closeButton]];
        [[self closeButton] setHidden:NO];
    } else {
        id beats = [[self current] objectForKeyedSubscript:@"beats"];
        [self setBeatIndex:[self beatIndex] + 1];
        if ([self beatIndex] >= [beats count]) {
            [self finishCurrent];
            return;
        }
        [self setBeat:[beats objectAtIndexedSubscript:[self beatIndex]]];
    }

    [self setAnswer:[[self beat] objectForKeyedSubscript:@"text"]];
    [[self replyLabel] setText:@""];

    BOOL empty = ([self answer].length == 0);
    [[self replyBubble] setHidden:empty];

    NSArray *actions = [[self beat] objectForKeyedSubscript:@"actions"];
    if ([actions count] != 0) {
        void (^handler)(id) = [self actionsHandler];
        if (handler) handler(actions);
    }

    [[self view] setNeedsLayout];

    // 有按钮时留 0.45s 让按钮先落位，再开播
    NSTimeInterval wait = [actions count] ? 0.45 : 0.0;
    __weak typeof(self) weakSelf = self;
    [self delay:wait block:^{
        typeof(self) s = weakSelf;
        if (!s) return;
        if ([[s answer] length] != 0) {
            [s startSpeech];
            [s revealNext];
        } else {
            [s scheduleDismiss];
        }
    }];
}

// 0x20e10  1576 B。按组合字符（不是 UTF-16 码元）推进一格，
// 顺带触发 anchors 回调、选音效、算下一格延迟。
- (void)revealNext {
    if ([self closed]) return;
    NSDictionary *snapshot = [self current];
    if (!snapshot) return;
    if ([self shownLength] >= [[self answer] length]) return;

    NSString *answer = [self answer];
    NSRange range = [answer rangeOfComposedCharacterSequenceAtIndex:[self shownLength]];
    NSString *chunk = [answer substringWithRange:range];   // 本格字符（可能是组合序列）

    [self setShownLength:range.location + range.length];
    [[self replyLabel] setText:[[self answer] substringToIndex:[self shownLength]]];

    // anchors：at <= shownLength 的全部触发，触发完推进 anchorIndex
    NSArray *anchors = [[self beat] objectForKeyedSubscript:@"anchors"];
    while ([self anchorIndex] < [anchors count]) {
        id anchor = [anchors objectAtIndexedSubscript:[self anchorIndex]];
        NSUInteger at = [[anchor objectForKeyedSubscript:@"at"] unsignedIntegerValue];
        if (at > [self shownLength]) break;

        void (^handler)(id) = [self actionsHandler];
        if (handler) {
            handler([anchor objectForKeyedSubscript:@"actions"]);
        }
        [self setAnchorIndex:[self anchorIndex] + 1];
    }

    [self layoutBubbles];

    // anchors 回调里可能已经把 current 换掉，那就别再往下排下一格
    if ([self current] != snapshot) return;

    // 纯标点/空白格不发声，用短延迟；有实字才走语音与音效
    NSCharacterSet *allPunct = [NSCharacterSet characterSetWithCharactersInString:@" \n\t,.!?;:…，。！？；：、「」『』()（）"];
    BOOL punctuationOnly = ([chunk rangeOfCharacterFromSet:[allPunct invertedSet]].location == NSNotFound);

    if (!punctuationOnly) {
        if (![[[self current] objectForKeyedSubscript:@"silent"] boolValue]) {
            void (^talk)(NSString *, BOOL) = [self talkHandler];
            if (talk) talk(chunk, YES);

            if ([self speechAllowed] && ![self usingDoubao]) {
                PDSoundPlayer *player = [PDSoundPlayer sharedPlayer];
                NSArray *arguments = [NSArray arrayWithObjects:&chunk count:1];
                CGFloat anchorX = [self anchorPoint].x;
                CGFloat width = MAX([self view].bounds.size.width, 1.0);
                float pan = (float)((anchorX / width) * 2.0 - 1.0);
                [player playSound:@"babble" kind:@"talk" arguments:arguments pan:pan];
            }
        }
    }

    if ([self shownLength] >= [[self answer] length]) {
        // 本拍播完
        if ([[[self current] objectForKeyedSubscript:@"kind"] isEqual:@"ask"]) {
            [self showOptions];
        } else {
            [self scheduleDismiss];
        }
        return;
    }

    NSCharacterSet *sentencePunct = [NSCharacterSet characterSetWithCharactersInString:@",.!?;:…，。！？；：、"];
    BOOL noBreak = ([chunk rangeOfCharacterFromSet:sentencePunct].location == NSNotFound);

    // 无标点：按字符数 × 0.05s 起算；遇标点：固定 0.25s 停顿
    NSTimeInterval base = noBreak ? (double)range.length * 0.05 : 0.25;
    NSTimeInterval speed = [self bubbleSpeed];
    BOOL rush = [[[self current] objectForKeyedSubscript:@"rush"] boolValue];
    NSTimeInterval delay = base / (speed * (rush ? 6.0 : 1.0));

    __weak typeof(self) weakSelf = self;
    [self delay:delay block:^{
        [weakSelf revealNext];
    }];
}

/// 停止揭示。
- (void)stopReveal {
    _revealing = NO;
    _beat = nil;
}

#pragma mark - 语音输入

/// 232 条指令。启动语音输入。
/// 反汇编：closed → pendingDictation → dictation → isActive
- (void)startVoiceInput {
    if (_closed || _pendingDictation) return;

    _pendingDictation = YES;
    _dictationManualSend = NO;

    if (_dictation && [_dictation respondsToSelector:@selector(isActive)] &&
        [[_dictation valueForKey:@"isActive"] boolValue]) {
        return;   // 已在听写
    }
    if (_voiceHandler) _voiceHandler();
}

/// 235 条指令。听写结果回填。
/// 反汇编：dictationPrefix → dictationSuffix → typingAttributes
- (void)applyDictationText:(NSString *)text {
    if (![text isKindOfClass:[NSString class]]) return;
    _pendingDictation = NO;

    NSString *prefix = _dictationPrefix ?: @"";
    NSString *suffix = _dictationSuffix ?: @"";
    NSString *full = [NSString stringWithFormat:@"%@%@%@", prefix, text, suffix];

    _composer.text = full;

    // 手动发送模式：直接发
    if (_dictationManualSend) {
        _dictationManualSend = NO;
        [self send];
        return;
    }
    // 否则回填草稿，等用户确认
    _dictationScrollPending = YES;
}

#pragma mark - 表格数据源


#pragma mark - 关闭


#pragma mark - 初始化（批次 A · 逐指令核对）

// initWithCompletion: 0x17fb4（4 条）：取默认锚点常量后尾调 initWithAnchorPoint:completion:
// Assumed：默认锚点槽 0xf8a10 是导入符号 CGPointZero（bind #321）。
//   验证动作：dyld bind 序号表比对 0x141 → 符号名。
- (id)initWithCompletion:(void (^)(void))completion {
    return [self initWithAnchorPoint:CGPointZero completion:completion];
}

// initWithAnchorPoint:completion: 0x17fc4（80 条）
//   objc_msgSendSuper2(initWithNibName:nil bundle:nil)
//   → 锚点 stp d9,d8 写入 ivar[0x450]（CGPoint）
//   → [completion copy] 写入 ivar[0x454]（dismissHandler）
//   → 五次 objc_opt_new 写入 0x458/0x45c/0x460/0x464/0x468
//   → reloadPreferences
// Assumed：五个数组依次为 queue / optionButtons / images / imageButtons / userBubbles
//   （按 ivar 偏移顺序对应，未逐个验证偏移值）。
- (id)initWithAnchorPoint:(CGPoint)anchorPoint completion:(void (^)(void))completion {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _anchorPoint = anchorPoint;
        _dismissHandler = [completion copy];
        _queue = [NSMutableArray new];
        _optionButtons = [NSMutableArray new];
        _images = [NSMutableArray new];
        _imageButtons = [NSMutableArray new];
        _userBubbles = [NSMutableArray new];
        [self reloadPreferences];
    }
    return self;
}

// loadView 0x18104（47 条）：[[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds]，
//   backgroundColor = clearColor，setView:。
/// 0x18104  188 B。根视图是自绘透传容器，不是 UIView。
- (void)loadView {
    self.view = [[PDChatPassthroughView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    [[self view] setBackgroundColor:[UIColor clearColor]];
}

// viewDidAppear: 0x1945c（19 条）：super + notifyConfirmationShown
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self notifyConfirmationShown];
}

// button:action: 0x182a8（34 条）：UIButton buttonWithType:1(System)，
//   setTitle:forState:0，addTarget:self action: forControlEvents:0x40(TouchUpInside)
- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark - 确认状态（批次 A）

// confirmationPinned 0x194a8（47 条）
- (BOOL)confirmationPinned {
    NSDictionary *cur = self.current;
    if (![cur[@"confirm"] boolValue]) return NO;
    return [cur[@"id"] isEqual:self.shownConfirmationID];
}

// notifyConfirmationShown 0x19564（195 条）：可见性链 + 祖先 alpha 检查 + 提交
//   current[@"confirm"] 为假 / id 为空 / id 已上报 / 已关闭 → 直接返回
//   可见性：view.window 非空、window/view/replyBubble 均未隐藏、replyLabel 有文字、
//           replyBubble.frame 与 view.bounds 相交
//   透明度：replyBubble 及其所有 superview 的 alpha 必须 > 0.01（常量 0xc5cc8）
//   通过后：shownConfirmationID = id；confirmationAnchor = anchorPoint；回调 handler(id)
- (void)notifyConfirmationShown {
    if (self.closed) return;
    NSDictionary *cur = self.current;
    if (![cur[@"confirm"] boolValue]) return;

    NSString *cid = cur[@"id"];
    if (![cid isKindOfClass:[NSString class]] || cid.length == 0) return;
    if ([cid isEqual:self.shownConfirmationID]) return;

    UIWindow *window = self.view.window;
    if (!window) return;
    if (window.isHidden) return;
    if (self.view.isHidden) return;
    if (self.replyBubble.isHidden) return;
    if (self.replyLabel.text.length == 0) return;
    if (!CGRectIntersectsRect(self.replyBubble.frame, self.view.bounds)) return;

    const CGFloat kMinAlpha = 0.01;
    if (self.replyBubble.alpha <= kMinAlpha) return;
    for (UIView *v = self.replyBubble.superview; v != nil; v = v.superview) {
        if (v.isHidden) return;
        if (v.alpha <= kMinAlpha) return;
    }

    self.shownConfirmationID = cid;
    self.confirmationAnchor = self.anchorPoint;
    void (^handler)(NSString *) = self.confirmationShownHandler;
    if (handler) handler(cid);
}

// updateAnchorPoint: 0x19870（47 条）
//   x/y 非有限 → 返回；与当前锚点相等 → 返回；写入；
//   视图未加载 → 返回；未关闭 → 尾调 repositionBubbles
- (void)updateAnchorPoint:(CGPoint)point {
    if (!isfinite(point.x) || !isfinite(point.y)) return;
    if (CGPointEqualToPoint(point, self.anchorPoint)) return;
    _anchorPoint = point;
    if (!self.isViewLoaded) return;
    if (!self.closed) [self repositionBubbles];
}

// keyboardChanged: 0x1992c（76 条）：从通知 userInfo 取
//   UIKeyboardFrameEndUserInfoKey（0x11fc18 槽）→ 转为 view 坐标 → 存 keyboardFrame
//   → setNeedsLayout
- (void)keyboardChanged:(NSNotification *)note {
    NSValue *value = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    CGRect frame = value.CGRectValue;
    if (self.isViewLoaded) {
        frame = [self.view convertRect:frame fromView:nil];
    }
    _keyboardFrame = frame;
    [self.view setNeedsLayout];
}

// keyboardHidden: 0x19a5c（25 条）：keyboardFrame = CGRectZero → setNeedsLayout
- (void)keyboardHidden:(NSNotification *)note {
    _keyboardFrame = CGRectZero;
    [self.view setNeedsLayout];
}

#pragma mark - 关闭（批次 A）

// close 0x22010（85 条）
//   closed 已置位 → 返回
//   置 closed → cancelVoiceInput / stopSpeech / stopReveal
//   dismissTimer invalidate + 置 nil → setThinking:NO → composer resignFirstResponder
//   有 parent 且有 presenting → dismissViewControllerAnimated:NO completion:dismissHandler
//   否则直接调用 dismissHandler
- (void)close {
    if (self.closed) return;
    self.closed = YES;
    [self cancelVoiceInput];
    [self stopSpeech];
    [self stopReveal];
    [self.dismissTimer invalidate];
    self.dismissTimer = nil;
    [self setThinking:NO];
    [_composer resignFirstResponder];

    if (self.parentViewController && self.presentingViewController) {
        [self dismissViewControllerAnimated:NO completion:self.dismissHandler];
        return;
    }
    void (^handler)(void) = self.dismissHandler;
    if (handler) handler();
}

// dealloc 0x22164（60+ 条）：释放前把进行中的听写取消
//   dictation 非空 → cancelWithCompletion:（带一个捕获 block）
//   dictation 为空但 pendingDictation → 走取消路径
// Inferred：block 体内具体动作未逐条还原，这里只保留必要的清理顺序。
- (void)dealloc {
    if (_dictation) {
        [_dictation cancelWithCompletion:^{}];
    } else if (self.pendingDictation) {
        [self cancelVoiceInput];
    }
}

// MARK: - 输入框与听写（批次 B）

// Observed 0x19ac0
- (void)showComposer {
    if ([self closed]) {
        return;
    }
    [self cancelVoiceInput];
    [self loadViewIfNeeded];
    // 0xfaf10 / 0xfc770：kind == ask 时不弹输入框
    if ([self.current[@"kind"] isEqual:@"ask"]) {
        return;
    }
    [self stopSpeech];
    [self stopReveal];
    [[self dismissTimer] invalidate];
    [self setDismissTimer:nil];
    [self setCurrent:nil];
    [self resetOptions];
    [[self inputBubble] setHidden:NO];
    [[self inputBubble] addSubview:[self inputFrame]];
    [[self inputBubble] addSubview:[self closeButton]];
    [[self inputFrame] setHidden:NO];
    [[self closeButton] setHidden:NO];
    // 0xfc670
    [[self composer] setText:PDLocalizedString(@"输入想说的话…")];
    [self setThinking:NO];
    [[self view] setNeedsLayout];
}

// Observed 0x1a998
- (void)stopDictationRevealTimer {
    [[self dictationRevealTimer] invalidate];
    [self setDictationRevealTimer:nil];
}

// Observed 0x1a598
- (void)updateDictationText:(id)text {
    if (text == nil) {
        return;
    }
    if ([self closed]) {
        return;
    }
    if ([self dictationReveal] == nil) {
        [self setDictationReveal:[PDVoiceTextReveal new]];
    }
    [[self dictationReveal] updateText:text
                               atTime:[[NSProcessInfo processInfo] systemUptime]];
    [self scheduleDictationReveal];
}

// Observed 0x1a670
- (void)scheduleDictationReveal {
    [self stopDictationRevealTimer];
    if (![[self dictationReveal] isPending]) {
        return;
    }
    if ([self closed]) {
        return;
    }
    double now = [[NSProcessInfo processInfo] systemUptime];
    double delay = [[self dictationReveal] nextAdvanceTime] - now;
    if (delay < 0.0) {
        delay = 0.0;
    }
    __weak typeof(self) weakSelf = self;
    unsigned long long request = [self dictationRequest];
    NSTimer *timer = [NSTimer timerWithTimeInterval:delay
                                            repeats:NO
                                              block:^(NSTimer *t) {
        __strong typeof(weakSelf) self_ = weakSelf;
        if (self_ == nil) {
            return;
        }
        if ([self_ closed]) {
            return;
        }
        if ([self_ dictationRequest] != request) {
            return;
        }
        if ([self_ dictationRevealTimer] != t) {
            [t invalidate];
            return;
        }
        [self_ setDictationRevealTimer:nil];
        [[self_ dictationReveal] advanceAtTime:[[NSProcessInfo processInfo] systemUptime]];
        [self_ applyDictationText:[[self_ dictationReveal] displayedText]];
        [self_ scheduleDictationReveal];
    }];
    [self setDictationRevealTimer:timer];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

// Observed 0x1a9e4
- (void)finishDictationText:(id)text {
    [self stopDictationRevealTimer];
    if ([text length] != 0) {
        [[self dictationReveal] finishWithText:text];
    } else {
        [[self dictationReveal] flush];
    }
    [self applyDictationText:[[self dictationReveal] displayedText]];
    if (text == nil || [self closed]) {
        return;
    }
    NSString *prefix = [self dictationPrefix] ?: @"";
    NSString *suffix = [self dictationSuffix] ?: @"";
    NSString *assembled = [NSString stringWithFormat:@"%@%@%@", prefix, text, suffix];
    if ([[[self composer] text] isEqualToString:assembled]) {
        [self setDictationScrollPending:YES];
        return;
    }
    NSMutableDictionary *attrs = [[[self composer] typingAttributes] mutableCopy];
    if (attrs != nil) {
        if ([[self composer] font] != nil) {
            attrs[NSFontAttributeName] = (__bridge id)[[self composer] font];
        }
        if ([[self composer] textColor] != nil) {
            attrs[NSForegroundColorAttributeName] = [[self composer] textColor];
        }
    }
    NSAttributedString *as =
        [[NSAttributedString alloc] initWithString:assembled attributes:attrs];
    NSTextStorage *storage = [[self composer] textStorage];
    NSRange all = NSMakeRange(0, [storage length]);
    [storage beginEditing];
    [storage replaceCharactersInRange:all withAttributedString:as];
    [storage endEditing];
    [[self composer] setSelectedRange:NSMakeRange([prefix length] + [text length], 0)];
    [self textViewDidChange:[self composer]];
    [[self composer] setNeedsLayout];
    [self setDictationScrollPending:YES];
}

// Observed 0x1ae54（尾段两个 setVoiceInputActive 分支为 Inferred）
- (void)cancelVoiceInput {
    [self stopDictationRevealTimer];
    [[self dictationReveal] flush];
    [self applyDictationText:[[self dictationReveal] displayedText]];
    [self setDictationReveal:nil];
    if ([self pendingDictation]) {
        [self setPendingDictation:NO];
        [self setDictationRequest:0];
        [self setDictation:nil];
        [self setDictationManualSend:NO];
        id placeholder = [self dictationPlaceholder];
        if (placeholder != nil) {
            [[(PDComposerTextView *)[self composer] placeholder] setText:placeholder];
            [self setDictationPlaceholder:nil];
        }
        [self setDictationPrefix:nil];
        [self setDictationSuffix:nil];
    }
    unsigned long long lease = [self dictationAudioLease];
    if (lease != 0) {
        [[self dictation] cancelWithCompletion:nil];
    }
    BOOL wasActive = (lease != 0);
    if (wasActive) {
        [[PDSoundPlayer sharedPlayer] setVoiceInputActive:NO completion:nil];
    } else {
        [[PDSoundPlayer sharedPlayer] setVoiceInputActive:NO completion:^{
            // Inferred：仅刷新一次布局，未观察到其它副作用
        }];
    }
}

// Observed 0x1b0ec（四个域名分支逐条比对）
- (void)dictationFailed:(NSError *)error {
    [self cancelVoiceInput];
    NSString *domain = error.domain;
    BOOL permissionDenied = ([domain isEqualToString:@"PetDFY.CloudVoiceInput"] && error.code == 1);
    BOOL storageFailed = [domain isEqualToString:@"PetDFY.VoiceStorage"];
    BOOL serviceFailed = [domain isEqualToString:@"PetDFY.VoiceService"];  // Observed：串池 0xbc977

    NSString *message = PDLocalizedString(@"语音识别未完成，已保留输入内容，请重试或手动发送。");
    if (permissionDenied) {
        message = PDLocalizedString(@"麦克风暂不可用，已保留输入内容，请检查录音权限后重试。");
    } else if (storageFailed) {
        message = PDLocalizedString(@"语音服务无法保存识别数据，已保留输入内容，可手动发送。");
    } else if (serviceFailed) {
        message = PDLocalizedString(@"语音识别未完成，已保留输入内容，请检查网络后重试或手动发送。");
    }

    if ([[[self current] objectForKeyedSubscript:@"kind"] isEqualToString:@"ask"]) {
        [[(PDComposerTextView *)[self composer] placeholder] setText:PDLocalizedString(@"语音输入暂不可用")];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
        return;
    }

    // Inferred：内层步骤字典的 actions/anchors 取空数组常量（GOT 0xf8b78）
    NSDictionary *step = @{ @"text": message, @"actions": @[], @"anchors": @[] };
    // Inferred：外层 kind/silent/beats（GOT 0xf8b90 两处同源，按空数组还原）
    [self enqueuePresentation:@{ @"kind": @"say", @"silent": @[], @"beats": @[], @"actions": @[ step ] }];
}

// Observed 0x1b3cc
- (void)hideComposer {
    [self cancelVoiceInput];
    if ([[[self current] objectForKeyedSubscript:@"kind"] isEqualToString:@"ask"]) {
        [self submitAnswer:-1 text:@"" dismissed:YES];
        return;
    }
    [[self composer] resignFirstResponder];
    [[self inputBubble] setHidden:YES];
    [self advanceQueue];
}

// Observed 0x1ba20
- (void)textViewDidBeginEditing:(UITextView *)textView {
    void (^handler)(BOOL) = [self keyboardFocusHandler];
    if (handler) {
        handler(YES);
    }
    [self setKeyboardFrame:CGRectZero];
    [self updateColors];
    [[self view] setNeedsLayout];
}

// Observed 0x1bac8
- (void)textViewDidChange:(UITextView *)textView {
    BOOL empty = ([textView text].length == 0);
    [[(PDComposerTextView *)[self composer] placeholder] setHidden:empty];
    [[self view] setNeedsLayout];
}

// Observed 0x1b968
- (void)textViewDidEndEditing:(UITextView *)textView {
    void (^handler)(BOOL) = [self keyboardFocusHandler];
    if (handler) {
        handler(NO);
    }
}

// Observed 0x1bb74
- (BOOL)textView:(UITextView *)textView
        shouldChangeTextInRange:(NSRange)range
        replacementText:(NSString *)text {
    if (textView != [self composer]) {
        return YES;
    }
    if (![self returnSends]) {
        return YES;
    }
    if ([textView markedTextRange] != nil) {
        return YES;
    }
    if ([[self dictation] isActive]) {
        return YES;
    }
    if ([text isEqualToString:@"\n"]) {
        [self send];
        return NO;
    }
    return YES;
}

- (void)setTurnBusy:(BOOL)arg1 error:(id)arg2 {
    // 0x1f05c  496 指令
    if ([self closed]) {
        return;
    }
    [self loadViewIfNeeded];
    [self setTurnBusy:arg1];
    if (!arg2) {
        if ([self current] == nil) {
            [self advanceQueue];
        }
        return;
    }
    NSString *detail = [(NSError *)arg2 localizedDescription];
    NSString *text = [NSString stringWithFormat:PDLocalizedString(@"没连上：%@"), detail];
    NSDictionary *inner = @{ @"text": text, @"actions": @[], @"anchors": @[] };
    NSDictionary *op = @{ @"kind": @"say", @"silent": @YES, @"beats": @[ inner ] };
    [self enqueuePresentation:op];
}

- (void)enqueuePresentation:(id)arg1 {
    // 0x1f24c  856 指令
    NSDictionary *op = (NSDictionary *)arg1;
    if ([self closed]) {
        return;
    }
    [self loadViewIfNeeded];
    NSString *opKind = [op objectForKeyedSubscript:@"kind"];
    if ([[op objectForKeyedSubscript:@"silent"] boolValue]) {
        if (![[self inputBubble] isHidden]) {
            [self cancelVoiceInput];
            [[self composer] resignFirstResponder];
            [[self inputBubble] setHidden:YES];
        }
    }
    if ([opKind isEqual:@"closeAsk"]) {
        NSArray *queue = [self queue];
        NSIndexSet *hits = [queue indexesOfObjectsPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
            return [[obj objectForKeyedSubscript:@"id"] isEqual:[op objectForKeyedSubscript:@"id"]];
        }];
        [[self queue] removeObjectsAtIndexes:hits];
        if ([[[self current] objectForKeyedSubscript:@"id"] isEqual:[op objectForKeyedSubscript:@"id"]]) {
            [self finishCurrent];
        }
        return;
    }
    {
        NSArray *queue = [self queue];
        NSIndexSet *hits = [queue indexesOfObjectsPassingTest:^BOOL(id obj, NSUInteger idx, BOOL *stop) {
            return [[obj objectForKeyedSubscript:@"kind"] isEqual:@"ask"]
                && ![[obj objectForKeyedSubscript:@"confirm"] boolValue];
        }];
        [[self queue] removeObjectsAtIndexes:hits];
    }
    if ([[[self current] objectForKeyedSubscript:@"kind"] isEqual:@"ask"]) {
        if (![[[self current] objectForKeyedSubscript:@"confirm"] boolValue]) {
            [self stopSpeech];
            [self stopReveal];
            [self resetOptions];
            [self setCurrent:nil];
        }
    }
    if ([[op objectForKeyedSubscript:@"confirm"] boolValue]) {
        [self rushQueuedLines];
    }
    [[self queue] addObject:op];
    [self advanceQueue];
}


#pragma mark - 队列 / 生命周期

// 0x1fa4c, 120 指令。队列泵：当前无在播项且输入气泡已收起时取下一项。
- (void)advanceQueue {
    if ([self closed]) return;
    if ([self current]) return;
    if (![[self inputBubble] isHidden]) return;
    [[self dismissTimer] invalidate];
    [self setDismissTimer:nil];

    if ([[self queue] count] == 0) {
        // 队列空了：气泡/思考态跟随 turnBusy 回落
        [self setBusy:[self turnBusy]];
        [[self replyBubble] setHidden:![self busy]];
        [self setThinking:[self busy]];
        [[self view] setNeedsLayout];
        if ([self busy]) return;

        // 静默 1.0s 后仍无活可干且输入气泡收着 → 自动关面板
        __weak typeof(self) weakSelf = self;
        NSTimer *timer = [NSTimer timerWithTimeInterval:1.0
                                                repeats:NO
                                                  block:^(NSTimer *t) {
            typeof(self) s = weakSelf;
            if (!s) return;
            if ([s current]) return;
            if ([[s queue] count] != 0) return;
            if ([s turnBusy]) return;
            if (![[s inputBubble] isHidden]) return;
            [s close];
        }];
        [self setDismissTimer:timer];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        return;
    }

    BOOL (^busy)(void) = [self bodyBusyProvider];
    if (busy && busy()) {
        // 身体动作未播完，0.1s 后重试
        __weak typeof(self) weakSelf = self;
        [self delay:0.1 block:^{ [weakSelf advanceQueue]; }];
        return;
    }

    [self setCurrent:[[self queue] firstObject]];
    [[self queue] removeObjectAtIndex:0];
    // beatIndex 从 -1 起算，beginBeat 里先 ++ 再取，首个 beat 才是 beats[0]
    [self setBeatIndex:-1];
    [self setBusy:NO];
    [self setThinking:NO];
    [self resetOptions];
    [self beginBeat];
}

// 0x21d20, 172 指令
- (void)finishCurrent {
    BOOL resume = [[[self current] objectForKeyedSubscript:@"resumeComposer"] boolValue];
    [self stopSpeech];
    [self stopReveal];
    [[self dismissTimer] invalidate];
    [self setDismissTimer:nil];
    [self resetOptions];
    [self setCurrent:nil];
    [self setBeat:nil];
    [[self replyBubble] setHidden:YES];
    if (resume) {
        [self showComposer];
    } else {
        [self advanceQueue];
    }
}

// 0x20598, 76 指令
- (void)stopSpeech {
    [[self speech] cancel];
    [self setUsingDoubao:NO];
}

// 0x23263, 156 指令
- (BOOL)speechAllowed {
    if (![self talkSound]) return NO;
    BOOL (^provider)(void) = [self soundEnabledProvider];
    if (provider) return provider();
    return [PDAIPreference(@"Sound", @YES) boolValue];
}

// 0x22310, 364 指令
- (void)resetOptions {
    [self setOptionsVisible:NO];
    [[self composer] resignFirstResponder];
    [[self optionButtons] removeAllObjects];
    [[self inputFrame] setHidden:NO];
    [[self closeButton] setHidden:YES];
    [[self view] setNeedsLayout];
}

// 0x21417, 172 指令
- (void)removeUserLine:(UIView *)line {
    [line removeFromSuperview];
    [[self userBubbles] removeObject:line];
    [[self view] setNeedsLayout];
}

// 0x22265, 168 指令
- (void)removeImage:(UIButton *)button {
    NSUInteger idx = [button tag];
    if (idx < [[self images] count]) {
        [[self images] removeObjectAtIndex:idx];
        [self refreshImages];
    }
}

// 0x19279 附近, 100 指令
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self updateColors];
}

// 0x19279, 100 指令
- (BOOL)textViewShouldBeginEditing:(UITextView *)textView {
    [self cancelVoiceInput];
    void (^handler)(BOOL) = [self keyboardFocusHandler];
    if (handler) handler(YES);
    return YES;
}

// 0x24580, 144 指令
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    if (scrollView != [self replyScroll]) return;
    [[self dismissTimer] invalidate];
    [self setDismissTimer:nil];
}

// 0x24227, 76 指令
- (void)pickOption:(UIButton *)button {
    NSDictionary *cur = [self current];
    if (![[cur objectForKeyedSubscript:@"kind"] isEqual:@"ask"]) return;
    [self stopSpeech];
    if ([[cur objectForKeyedSubscript:@"confirm"] boolValue]) return;
    id option = [[cur objectForKeyedSubscript:@"options"] objectAtIndexedSubscript:(NSUInteger)[button tag]];
    [self submitAnswer:(long long)[button tag] text:option dismissed:NO];
}
// ─────────────────────────────────────────────────────────────
// 第二批：呈现队列的调度、气泡布局、图片托盘、选项、定时收起、语音引擎分派
// 对应反汇编 0x20cc4 / 0x1d6ac / 0x1eaa0 / 0x1e1d8 / 0x1d9f4 / 0x1dc38 /
//            0x1f6a0 / 0x214a4 / 0x217b0 / 0x21978 / 0x21eb0 / 0x21f64 /
//            0x205e4 / 0x21d20
// ─────────────────────────────────────────────────────────────

/// 打字机步进：停掉当前节拍 → 建一个一次性定时器挂到主 RunLoop。
/// Observed：stopReveal / max(interval, 常量) / timerWithTimeInterval:repeats:NO /
///           setRevealTimer: / [[NSRunLoop mainRunLoop] addTimer:forMode:NSDefaultRunLoopMode]
/// Inferred：定时器回调里先摘掉 revealTimer 再执行传入的 block（块体在 0x20df0，
///           对捕获的 self 发消息，具体选择器未逐条还原）
- (void)delay:(double)seconds block:(void (^)(void))block {
    [self stopReveal];
    double interval = MAX(seconds, 0.01);
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:interval
                                            repeats:NO
                                              block:^(NSTimer *fired) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf setRevealTimer:nil];
        if (block) {
            block();
        }
    }];
    [self setRevealTimer:timer];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
}

/// 气泡重排：输入气泡贴底、回复气泡贴输入气泡上方、用户气泡自下而上堆叠。
/// Observed：confirmationPinned/confirmationAnchor/anchorPoint、composer 第一响应者时读
///           keyboardFrame、inputBubble/replyBubble 的 isHidden 决定是否让位、
///           userBubbles 用 reverseObjectEnumerator 逆序遍历并逐个 placeBubble、
///           末尾按 safeAreaInsets 调 setHidden:。
/// Inferred：气泡间距常量与 bottom 递减量（浮点常量未逐位还原）。
- (void)repositionBubbles {
    CGRect bounds = [self view].bounds;
    double unit = 8.0;
    double bottom = bounds.size.height;

    UIEdgeInsets safe = [self view].safeAreaInsets;
    bottom -= safe.bottom;

    BOOL pinned = [self confirmationPinned];
    CGPoint anchor = [self confirmationAnchor];
    (void)anchor;

    if ([[self composer] isFirstResponder]) {
        CGRect keyboard = [self keyboardFrame];
        if (keyboard.size.height > 0.0) {
            bottom = MIN(bottom, keyboard.origin.y);
        }
    }

    if (![[self inputBubble] isHidden]) {
        CGRect frame = ((UIView *)[self inputBubble]).frame;
        double y = [self placeBubble:[self inputBubble]
                                size:frame.size
                              bottom:bottom
                              center:CGRectGetMidX(bounds)];
        bottom = y - unit;
    }

    if (![[self replyBubble] isHidden]) {
        CGRect frame = ((UIView *)[self replyBubble]).frame;
        double y = [self placeBubble:[self replyBubble]
                                size:frame.size
                              bottom:bottom
                              center:CGRectGetMidX(bounds)];
        bottom = y - unit;
    }

    NSArray *reversed = [[[self userBubbles] reverseObjectEnumerator] allObjects];
    for (UIView *bubble in reversed) {
        CGRect frame = [bubble frame];
        double y = [self placeBubble:bubble
                                size:frame.size
                              bottom:bottom
                              center:CGRectGetMidX(bounds)];
        bottom = y - unit;
    }

    if (pinned) {
        [[self view] setNeedsLayout];
    }
    (void)anchor;
}

/// 图片托盘重建：清掉旧按钮，按 images 逐张建圆角按钮塞进 imageTray。
/// Observed：imageButtons 全量 removeFromSuperview + removeAllObjects、
///           buttonWithType:、setTag: 递增、images[i] 取 objectForKeyedSubscript: 后
///           imageWithData: → initWithImage:、setContentMode:、insertSubview:atIndex:、
///           setTitle:forState: 显示序号、titleLabel.layer 加阴影、
///           addTarget:action:forControlEvents:、addSubview: 到 imageTray。
/// Inferred：按钮尺寸 44x44、圆角 8、角标字号 12（常量按常见值取，未逐位还原）。
- (void)refreshImages {
    for (UIButton *button in [self imageButtons]) {
        [button removeFromSuperview];
    }
    [[self imageButtons] removeAllObjects];

    NSArray *images = [self images];
    NSUInteger count = [images count];
    for (NSUInteger index = 0; index < count; index++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        [button setTag:(NSInteger)index];
        [button setClipsToBounds:YES];

        id entry = [images objectAtIndexedSubscript:index];
        NSData *data = [entry objectForKeyedSubscript:@"data"];
        UIImage *image = data ? [UIImage imageWithData:data] : nil;
        UIImageView *thumb = [[UIImageView alloc] initWithImage:image];
        [thumb setContentMode:UIViewContentModeScaleAspectFill];
        [thumb setClipsToBounds:YES];
        [thumb setUserInteractionEnabled:NO];
        thumb.frame = CGRectMake(0.0, 0.0, 44.0, 44.0);
        [thumb setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
        [button insertSubview:thumb atIndex:0];

        [button setTitle:[NSString stringWithFormat:@"%lu", (unsigned long)(index + 1)]
                forState:UIControlStateNormal];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        CALayer *titleLayer = button.titleLabel.layer;
        titleLayer.shadowOpacity = 0.6f;
        titleLayer.shadowRadius = 2.0f;
        [button setContentHorizontalAlignment:UIControlContentHorizontalAlignmentRight];
        [button setContentVerticalAlignment:UIControlContentVerticalAlignmentBottom];
        [button setAccessibilityLabel:[NSString stringWithFormat:@"第 %lu 张图片", (unsigned long)(index + 1)]];
        [button addTarget:self
                   action:@selector(imageTapped:)
         forControlEvents:UIControlEventTouchUpInside];

        [[self imageTray] addSubview:button];
        [[self imageButtons] addObject:button];
    }
}

/// 粘贴板图片入队：把 images 里的图打包成一次 presentation 的 kind=images。
/// Observed：preparingImages 门、images.count、inputBubble.isHidden、
///           字典四键（kind / images / resumeComposer / …）→ enqueuePresentation:、
///           随后逐图取 size/scale/CGImage/imageOrientation 做尺寸归一到上限。
/// Inferred：单图上限 2048px、JPEG 质量 0.85（常量未逐位还原）。
- (void)pasteImages:(id)sender {
    (void)sender;
    if ([self preparingImages]) {
        return;
    }
    if ([[self images] count] == 0) {
        return;
    }

    BOOL bubbleWasHidden = [[self inputBubble] isHidden];
    [self setPreparingImages:YES];
    [[self sendButton] setEnabled:NO];

    [self resignFirstResponder];
    if (!bubbleWasHidden) {
        [[self inputBubble] setHidden:YES];
    }

    NSDictionary *payload = @{
        @"kind": @"images",
        @"images": [[self images] copy] ?: @[],
        @"resumeComposer": @(bubbleWasHidden),
        @"silent": @[],
    };
    [self enqueuePresentation:payload];

    // 归一化：超限的图按最长边缩到 2048，统一转 JPEG 数据回写
    NSUInteger index = 0;
    for (id entry in [self images]) {
        UIImage *image = [entry objectForKeyedSubscript:@"image"];
        if (!image) {
            index++;
            continue;
        }
        CGSize size = image.size;
        double scale = image.scale;
        double pixelWidth = size.width * scale;
        double pixelHeight = size.height * scale;
        double longest = MAX(pixelWidth, pixelHeight);
        if (longest > 2048.0) {
            double ratio = 2048.0 / longest;
            UIGraphicsBeginImageContextWithOptions(CGSizeMake(pixelWidth * ratio,
                                                              pixelHeight * ratio), NO, 1.0);
            [image drawInRect:CGRectMake(0.0, 0.0, pixelWidth * ratio, pixelHeight * ratio)];
            UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            if (scaled) {
                image = scaled;
            }
        }
        NSData *jpeg = UIImageJPEGRepresentation(image, 0.85);
        if (jpeg) {
            NSMutableDictionary *mutable = [entry mutableCopy];
            [mutable setObject:jpeg forKeyedSubscript:@"data"];
            [[self images] setObject:mutable atIndexedSubscript:index];
        }
        index++;
    }

    [self setPreparingImages:NO];
    [[self sendButton] setEnabled:YES];
}

/// 用户行入列：建气泡、上屏、进 userBubbles、挂点按手势，超出上限从头丢。
/// Observed：label setNumberOfLines:/setText:、addSubview: 两次（气泡→view）、
///           userBubbles addObject:、initWithTarget:action: + addGestureRecognizer:、
///           userBubbles.count > 上限时 firstObject removeFromSuperview + removeObjectAtIndex:0。
/// Inferred：气泡上限 6（常量未逐位还原）。
- (void)addUserLine:(NSString *)text {
    if (!text) {
        return;
    }

    UIView *bubble = [[UIView alloc] initWithFrame:CGRectZero];
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    [label setNumberOfLines:0];
    [label setText:text];
    [bubble addSubview:label];
    [[self view] addSubview:bubble];
    [[self userBubbles] addObject:bubble];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(userBubbleTapped:)];
    [bubble addGestureRecognizer:tap];

    while ([[self userBubbles] count] > 6) {
        UIView *oldest = [[self userBubbles] firstObject];
        [oldest removeFromSuperview];
        [[self userBubbles] removeObjectAtIndex:0];
    }

    [self updateColors];
    [self repositionBubbles];
}

/// 思考态：显示三点，跑一条透明度关键帧动画。
/// Observed：replyScroll setHidden:、dots 逐个 setHidden:、removeAllAnimations、
///           animationWithKeyPath:、setValues:/setKeyTimes:/setDuration:。
/// Inferred：关键路径 @"opacity"、值 @[@0.25,@1,@0.25]、时长 0.9、无限循环。
- (void)setThinking:(BOOL)thinking {
    [[self replyScroll] setHidden:!thinking];

    NSArray *dots = [self dots];
    for (NSUInteger index = 0; index < [dots count]; index++) {
        UIView *dot = [dots objectAtIndexedSubscript:index];
        [dot setHidden:!thinking];
        [dot.layer removeAllAnimations];
        if (!thinking) {
            continue;
        }
        CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        [animation setValues:@[ @0.25, @1.0, @0.25 ]];
        [animation setKeyTimes:@[ @0.0, @0.5, @1.0 ]];
        [animation setDuration:0.9];
        animation.beginTime = CACurrentMediaTime() + 0.15 * index;
        animation.repeatCount = HUGE_VALF;
        [dot.layer addAnimation:animation forKey:@"thinking"];
    }
}

/// 加速：把队列里所有 say 行压成一串，当前行补全，然后立刻走下一拍。
/// Observed：queue 逆序/正序遍历取 kind，命中 say 就把后续内容并入，
///           current 的 kind 同样判定 + resumeComposer 读回、mutableCopy 回写、
///           setCurrent:、stopSpeech、stopReveal、shownLength 直接拉到 answer.length。
// 0x1f6a0  848 B。切 rush：队列里的 say 全部打上 rush+silent，
// 当前这条也换掉，然后 1ms 一格把字喷完。
- (void)rushQueuedLines {
    NSUInteger count = [[self queue] count];
    for (NSUInteger index = 0; index < count; index++) {
        id item = [[self queue] objectAtIndexedSubscript:index];
        if (![[item objectForKeyedSubscript:@"kind"] isEqual:@"say"]) {
            continue;
        }
        id mutable = [item mutableCopy];
        [mutable setObject:@YES forKeyedSubscript:@"rush"];
        [mutable setObject:@YES forKeyedSubscript:@"silent"];
        [[self queue] setObject:mutable atIndexedSubscript:index];
    }

    NSDictionary *current = [self current];
    if (![[current objectForKeyedSubscript:@"kind"] isEqual:@"say"]) {
        return;
    }
    if ([[current objectForKeyedSubscript:@"rush"] boolValue]) {
        return;
    }

    id mutable = [current mutableCopy];
    [mutable setObject:@YES forKeyedSubscript:@"rush"];
    [mutable setObject:@YES forKeyedSubscript:@"silent"];
    [self setCurrent:mutable];

    [self stopSpeech];
    [self stopReveal];

    if ([self shownLength] >= [[self answer] length]) {
        [self scheduleDismiss];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self delay:0.001 block:^{
        [weakSelf revealNext];
    }];
}

/// 选项上屏：清空旧按钮，按 current.options 建按钮，需要输入框时一起摆。
/// Observed：setOptionsVisible:、current.options.count、逐项 stringWithFormat: +
///           button:action: + setTag: + titleLabel setNumberOfLines: +
///           setContentHorizontalAlignment:、replyScroll addSubview:、optionButtons addObject:、
///           current 的 wantsInput → inputFrame 上屏并 setHidden:、composer setText:/placeholder。
/// Inferred：按钮高度 44、行距 8（常量未逐位还原）。
- (void)showOptions {
    [self setOptionsVisible:YES];

    NSArray *options = [[self current] objectForKeyedSubscript:@"options"];
    NSUInteger count = [options count];
    for (NSUInteger index = 0; index < count; index++) {
        id option = [options objectAtIndexedSubscript:index];
        NSString *title = [option isKindOfClass:[NSString class]]
            ? option
            : [NSString stringWithFormat:@"%@", [option objectForKeyedSubscript:@"title"]];
        UIButton *button = [self button:title action:@selector(optionTapped:)];
        [button setTag:(NSInteger)index];
        [button titleLabel].numberOfLines = 0;
        [button setContentHorizontalAlignment:UIControlContentHorizontalAlignmentLeft];
        [[self replyScroll] addSubview:button];
        [[self optionButtons] addObject:button];
    }

    BOOL wantsInput = [[[self current] objectForKeyedSubscript:@"wantsInput"] boolValue];
    if (wantsInput) {
        [[self replyScroll] addSubview:[self inputFrame]];
        [[self inputFrame] setHidden:NO];
        NSString *text = [[self current] objectForKeyedSubscript:@"inputText"];
        [[self composer] setText:text ?: @""];
        NSString *placeholder = [[self current] objectForKeyedSubscript:@"placeholder"];
        if (placeholder) {
            [[self composer] setText:placeholder];
        }
    }
}

/// 提交答案：写一行用户气泡，记到 answerHandler，收起选项，推进队列。
/// Observed：current.optionId 比对 → stopSpeech、current 的 dismissed 布尔、
///           addUserLine:、stopReveal、resetOptions、setCurrent:、replyBubble setHidden:、
///           answerHandler 调用（带 optionId / text / dismissed）、advanceQueue。
- (void)submitAnswer:(long long)optionId text:(NSString *)text dismissed:(BOOL)dismissed {
    NSDictionary *current = [self current];
    id expected = [current objectForKeyedSubscript:@"optionId"];
    if (expected && ![expected isEqual:@(optionId)]) {
        return;
    }

    if ([current objectForKeyedSubscript:@"speaking"]) {
        [self stopSpeech];
    }

    BOOL alreadyDismissed = [[current objectForKeyedSubscript:@"dismissed"] boolValue];
    NSString *line = text;
    if (!line || [line length] == 0) {
        NSArray *options = [current objectForKeyedSubscript:@"options"];
        for (id option in options) {
            if ([[option objectForKeyedSubscript:@"id"] longLongValue] == optionId) {
                line = [option objectForKeyedSubscript:@"title"];
                break;
            }
        }
    }
    if ([line length] > 0) {
        [self addUserLine:line];
    }

    [self stopReveal];
    [self resetOptions];
    [self setCurrent:nil];
    [[self replyBubble] setHidden:YES];

    void (^handler)(NSString *) = [self answerHandler];
    if (handler && !alreadyDismissed) {
        handler(line);
    }

    [self advanceQueue];
}

/// 收起计时：没有朗读、没有选项、滚动静止且正文念完后，按速度起一个收起定时器。
/// Observed：dismissTimer invalidate + setDismissTimer:nil、current 的 speech.busy、
///           current.optionId 比对、replyScroll isTracking / isDecelerating、
///           beatIndex 与 answer.length 比较、bubbleSpeed、
///           timerWithTimeInterval:repeats:block: → setDismissTimer: → mainRunLoop addTimer。
/// Inferred：定时器回调走 setClosed:YES + cancelVoiceInput + stopSpeech（见 0x2202c 段）。
- (void)scheduleDismiss {
    [[self dismissTimer] invalidate];
    [self setDismissTimer:nil];

    NSDictionary *current = [self current];
    if ([[[self speech] valueForKey:@"busy"] boolValue]) {
        return;
    }
    if ([current objectForKeyedSubscript:@"optionId"]) {
        return;
    }
    if ([[self replyScroll] isTracking] || [[self replyScroll] isDecelerating]) {
        return;
    }

    NSNumber *beatIndex = [current objectForKeyedSubscript:@"beatIndex"];
    NSUInteger beats = [[current objectForKeyedSubscript:@"beats"] count];
    NSUInteger shown = [self shownLength];
    NSUInteger total = [[self answer] length];
    double remaining;
    if (beatIndex) {
        remaining = (double)(beats > [beatIndex unsignedIntegerValue]
                             ? beats - [beatIndex unsignedIntegerValue]
                             : 0);
    } else {
        remaining = shown < total ? (double)(total - shown) : 0.0;
    }

    double speed = [self bubbleSpeed];
    double delay = MAX(2.5, remaining / MAX(speed, 1.0));
    BOOL resume = [[current objectForKeyedSubscript:@"resumeComposer"] boolValue];
    (void)resume;

    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:delay
                                            repeats:NO
                                              block:^(NSTimer *fired) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf setDismissTimer:nil];
        [strongSelf setClosed:YES];
        [strongSelf cancelVoiceInput];
        [strongSelf stopSpeech];
        [strongSelf stopReveal];
    }];
    [self setDismissTimer:timer];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
}

/// 滚动停手：如果还在减速就交给 didEndDecelerating，否则正文念完就排收起。
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    (void)scrollView;
    if (decelerate) {
        return;
    }
    if ([self shownLength] >= [[self answer] length]) {
        [self scheduleDismiss];
    }
}

/// 减速结束：同样只看正文是否念完。
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    (void)scrollView;
    if ([self shownLength] >= [[self answer] length]) {
        [self scheduleDismiss];
    }
}

/// 朗读入口：按 AISpeechMode 在原生 / 豆包两条链里选一条，然后把正文喂进去。
/// Observed：answer.length、speechAllowed、current 的 speechEnabled / AISpeechMode、
///           与 @"doubao" isEqual:、speech 为空时 initWithPlay:stop: + setSpeech: +
///           setUsingDoubao:、然后 speech startText:key:speaker:instruction:options:completion:。
/// Inferred：原生链的 options 字典键（voice/rate/pitch）未逐键还原。
- (void)startSpeech {
    if ([[self answer] length] == 0) {
        return;
    }
    if (![self speechAllowed]) {
        return;
    }

    NSDictionary *current = [self current];
    BOOL speechEnabled = [[current objectForKeyedSubscript:@"speechEnabled"] boolValue];
    if (!speechEnabled) {
        return;
    }
    NSString *mode = [current objectForKeyedSubscript:@"AISpeechMode"];
    BOOL doubao = [mode isEqual:@"doubao"];

    if (![self speech]) {
        __weak typeof(self) weakSelf = self;
        PDReplySpeech *speech = [[PDReplySpeech alloc]
            initWithPlay:^(NSString *audio, void (^done)(NSError *)) {
                typeof(self) strongSelf = weakSelf;
                if (strongSelf) {
                    [strongSelf advanceQueue];
                }
                if (done) done(nil);
            }
            stop:^{
                typeof(self) strongSelf = weakSelf;
                if (strongSelf) {
                    [strongSelf scheduleDismiss];
                }
            }];
        [self setSpeech:speech];
        [self setUsingDoubao:doubao];
    }

    NSString *key = [current objectForKeyedSubscript:@"speechKey"];
    NSString *speaker = [current objectForKeyedSubscript:@"speaker"];
    NSString *instruction = [current objectForKeyedSubscript:@"instruction"];
    [[self speech] startText:[self answer]
                         key:key
                     speaker:speaker
                 instruction:instruction
                     options:(PDReplySpeechOptions){0}   // 二进制传 24 字节结构体，全零
                  completion:^(NSError *error) {
        (void)error;
        [self setThinking:NO];
    }];
}

/// 摆放单个气泡并计算尾巴位置，返回该气泡顶部 y（下一个气泡从这里往上排）。
/// Observed（0x1bc5c–0x1bdc8）：
///   x = MAX(unit*10, MIN(center - w/2, boundsW - w))
///   y = MAX(safeArea.top, bottom - h)
///   setFrame / setUnit / setTailX / updateOutline，返回 y
///   tailX = halfW + (clamp(anchorX - x, unit*22, w - unit*22) - halfW) * clamp((anchorY + 20)/40, 0, 1)
- (double)placeBubble:(id)bubble size:(CGSize)size bottom:(double)bottom center:(double)center {
    double unit = [self unit];
    CGRect bounds = [[self view] bounds];
    double halfWidth = size.width * 0.5;

    double x = center - halfWidth;
    x = MIN(x, bounds.size.width - size.width);
    x = MAX(unit * 10.0, x);

    UIEdgeInsets safe = [[self view] safeAreaInsets];
    double y = MAX(safe.top, bottom - size.height);

    UIView *view = (UIView *)bubble;
    [view setFrame:CGRectMake(x, y, size.width, size.height)];

    CGPoint anchor = [(id)bubble anchorPoint];
    double tailX = anchor.x - x;
    tailX = MIN(tailX, size.width - unit * 22.0);
    tailX = MAX(unit * 22.0, tailX);
    double ratio = (anchor.y + 20.0) / 40.0;
    ratio = MIN(MAX(ratio, 0.0), 1.0);
    tailX = halfWidth + (tailX - halfWidth) * ratio;
    [(id)bubble setTailX:tailX];
    [(id)bubble updateOutline];

    return y;
}

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setKeyboardFocusHandler:(id)v { _keyboardFocusHandler = v; }
- (void)setTalkHandler:(id)v { _talkHandler = v; }
- (void)setSendHandler:(id)v { _sendHandler = v; }
- (void)setAnswerHandler:(id)v { _answerHandler = v; }
- (void)setConfirmationShownHandler:(id)v { _confirmationShownHandler = v; }
- (void)setActionsHandler:(id)v { _actionsHandler = v; }
- (void)setBodyBusyProvider:(id)v { _bodyBusyProvider = v; }
- (void)setSoundEnabledProvider:(id)v { _soundEnabledProvider = v; }
- (void)setBeatIndex:(long long)v { _beatIndex = v; }
- (void)setAnchorIndex:(unsigned long long)v { _anchorIndex = v; }
- (void)setTurnBusy:(BOOL)v { _turnBusy = v; }
- (void)setOptionsVisible:(BOOL)v { _optionsVisible = v; }
- (void)setBubbleSize:(double)v { _bubbleSize = v; }
- (void)setFontSize:(double)v { _fontSize = v; }
- (void)setBubbleSpeed:(double)v { _bubbleSpeed = v; }
- (void)setPreparingImages:(BOOL)v { _preparingImages = v; }
- (void)setReturnSends:(BOOL)v { _returnSends = v; }
- (void)setDismissHandler:(id)v { _dismissHandler = v; }
- (void)setAnswer:(id)v { _answer = v; }
- (void)setShownLength:(unsigned long long)v { _shownLength = v; }
- (void)setShownConfirmationID:(id)v { _shownConfirmationID = v; }
- (void)setBusy:(BOOL)v { _busy = v; }
- (void)setClosed:(BOOL)v { _closed = v; }
- (void)setTalkSound:(BOOL)v { _talkSound = v; }
- (void)setUsingDoubao:(BOOL)v { _usingDoubao = v; }
- (void)setUnit:(double)v { _unit = v; }
- (void)setPendingDictation:(BOOL)v { _pendingDictation = v; }
- (void)setDictationRequest:(unsigned long long)v { _dictationRequest = v; }
- (void)setDictationAudioLease:(unsigned long long)v { _dictationAudioLease = v; }
- (void)setDictationPrefix:(id)v { _dictationPrefix = v; }
- (void)setDictationSuffix:(id)v { _dictationSuffix = v; }
- (void)setDictationPlaceholder:(id)v { _dictationPlaceholder = v; }
- (void)setDictationManualSend:(BOOL)v { _dictationManualSend = v; }
- (void)setDictationScrollPending:(BOOL)v { _dictationScrollPending = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (void)setQueue:(id)v { _queue = v; }
- (void)setCurrent:(id)v { _current = v; }
- (void)setBeat:(id)v { _beat = v; }
- (void)setOptionButtons:(id)v { _optionButtons = v; }
- (void)setImages:(id)v { _images = v; }
- (void)setImageButtons:(id)v { _imageButtons = v; }
- (void)setImageTray:(id)v { _imageTray = v; }
- (void)setInputBubble:(id)v { _inputBubble = v; }
- (void)setReplyBubble:(id)v { _replyBubble = v; }
- (void)setUserBubbles:(id)v { _userBubbles = v; }
- (void)setInputFrame:(id)v { _inputFrame = v; }
- (void)setInputOutline:(id)v { _inputOutline = v; }
- (void)setSendButton:(id)v { _sendButton = v; }
- (void)setCloseButton:(id)v { _closeButton = v; }
- (void)setReplyScroll:(id)v { _replyScroll = v; }
- (void)setReplyLabel:(id)v { _replyLabel = v; }
- (void)setDots:(id)v { _dots = v; }
- (void)setRevealTimer:(id)v { _revealTimer = v; }
- (void)setDismissTimer:(id)v { _dismissTimer = v; }
- (void)setSpeech:(id)v { _speech = v; }
- (void)setSpeechSettings:(id)v { _speechSettings = v; }
- (void)setDictation:(id)v { _dictation = v; }
- (void)setDictationReveal:(id)v { _dictationReveal = v; }
- (void)setDictationRevealTimer:(id)v { _dictationRevealTimer = v; }

#pragma mark - 二进制存取器（逐条 8-16 指令，纯 ivar 读写）
- (id)queue { return _queue; }
- (id)current { return _current; }
- (id)beat { return _beat; }
- (id)optionButtons { return _optionButtons; }
- (long long)beatIndex { return _beatIndex; }
- (unsigned long long)anchorIndex { return _anchorIndex; }
- (BOOL)turnBusy { return _turnBusy; }
- (BOOL)optionsVisible { return _optionsVisible; }
- (double)bubbleSize { return _bubbleSize; }
- (double)fontSize { return _fontSize; }
- (double)bubbleSpeed { return _bubbleSpeed; }
- (id)images { return _images; }
- (id)imageButtons { return _imageButtons; }
- (id)imageTray { return _imageTray; }
- (BOOL)preparingImages { return _preparingImages; }
- (BOOL)returnSends { return _returnSends; }
- (id)inputBubble { return _inputBubble; }
- (id)replyBubble { return _replyBubble; }
- (id)userBubbles { return _userBubbles; }
- (id)inputFrame { return _inputFrame; }
- (id)inputOutline { return _inputOutline; }
- (id)sendButton { return _sendButton; }
- (id)closeButton { return _closeButton; }
- (id)replyScroll { return _replyScroll; }
- (id)replyLabel { return _replyLabel; }
- (id)dots { return _dots; }
- (id)revealTimer { return _revealTimer; }
- (id)dismissTimer { return _dismissTimer; }
- (id)answer { return _answer; }
- (unsigned long long)shownLength { return _shownLength; }
- (id)shownConfirmationID { return _shownConfirmationID; }
- (BOOL)busy { return _busy; }
- (BOOL)closed { return _closed; }
- (BOOL)talkSound { return _talkSound; }
- (id)speech { return _speech; }
- (id)speechSettings { return _speechSettings; }
- (BOOL)usingDoubao { return _usingDoubao; }
- (double)unit { return _unit; }
- (BOOL)pendingDictation { return _pendingDictation; }
- (unsigned long long)dictationRequest { return _dictationRequest; }
- (unsigned long long)dictationAudioLease { return _dictationAudioLease; }
- (id)dictation { return _dictation; }
- (id)dictationPrefix { return _dictationPrefix; }
- (id)dictationSuffix { return _dictationSuffix; }
- (id)dictationPlaceholder { return _dictationPlaceholder; }
- (BOOL)dictationManualSend { return _dictationManualSend; }
- (id)dictationReveal { return _dictationReveal; }
- (id)dictationRevealTimer { return _dictationRevealTimer; }
- (BOOL)dictationScrollPending { return _dictationScrollPending; }

/// Observed @0x22714（4 条）：adrp/ldrsw 取 ivar 偏移表 + ldr x0,[x0,x8] —— 即直接读 _composer。
- (id)composer { return _composer; }

/// Observed @0x22724：mov x1,x2 后尾调用 objc_storeStrong —— 即 objc_storeStrong(&_composer, value)。
- (void)setComposer:(id)composer { _composer = composer; }

@end
