//
//  WNPainter+Body.m — 1.2 源码补齐：角色身体绘制
//
//  逆向骨架里 WNPainter.paintOverlayForRig: 只还原了情绪叠加层（orbit/listen/
//  think/sweat/anger/bang/question/heart/sleep），身体/面部贴图从未绘制，
//  因此 1.2 编出来的插件无论导入什么素材都不会显示角色。
//
//  本类别按 live/model.json 的 parts 定义，按 z 顺序把每个部件的贴图画进它的
//  box。贴图路径走 WNLiveRig.textureForPart:（originals/tex、schemes、
//  outfits 回退、sailor→jk-sailor 别名都在里面）。
//
//  朝向：已用全部 34 个部件合成整图验证——按 box 直接绘制（不做 Y 翻转）
//  才是正立的；翻转后角色倒立。故这里直接 CGContextDrawImage，不用 WNPainter
//  的 draw:context:rect:（那个带 Y 翻转，是给面部/眼睛叠加层用的）。
//

#import "WNPainter.h"
#import "WNLiveRig.h"

@implementation WNPainter (Body)

/// 按 z 升序把部件贴图画进各自 box。
- (void)paintBodyForRig:(WNLiveRig *)rig context:(CGContextRef)ctx {
    if (!rig || !ctx) return;

    NSDictionary *model = rig.model;
    if (![model isKindOfClass:[NSDictionary class]]) return;
    NSArray *parts = model[@"parts"];
    if (![parts isKindOfClass:[NSArray class]] || parts.count == 0) return;

    NSArray *sorted = [parts sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        double za = [[a objectForKey:@"z"] doubleValue];
        double zb = [[b objectForKey:@"z"] doubleValue];
        if (za < zb) return NSOrderedAscending;
        if (za > zb) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    for (NSDictionary *p in sorted) {
        if (![p isKindOfClass:[NSDictionary class]]) continue;

        NSString *tex = p[@"tex"];
        if (![tex isKindOfClass:[NSString class]] || tex.length == 0) continue;

        NSString *path = [rig textureForPart:tex];
        if (![path isKindOfClass:[NSString class]] || path.length == 0) continue;

        CGImageRef img = [self image:path];
        if (!img) continue;

        NSArray *box = p[@"box"];
        if (![box isKindOfClass:[NSArray class]] || box.count < 4) continue;
        CGRect r = CGRectMake([box[0] doubleValue], [box[1] doubleValue],
                              [box[2] doubleValue], [box[3] doubleValue]);
        if (CGRectIsEmpty(r)) continue;

        CGContextSaveGState(ctx);
        if ([p[@"blend"] isEqualToString:@"multiply"]) {
            CGContextSetBlendMode(ctx, kCGBlendModeMultiply);
        }
        CGContextDrawImage(ctx, r, img);
        CGContextRestoreGState(ctx);
    }
}

@end
