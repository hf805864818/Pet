//
//  Entry.m — MobileSubstrate 注入入口
//  原 dylib 由 Logos %ctor 启动；逆向源码未包含入口，这里补等价构造器。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PDOverlayController.h"

__attribute__((constructor))
static void PetDFYEntry(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                [[PDOverlayController sharedController] start];
            }
        });
    }
}
