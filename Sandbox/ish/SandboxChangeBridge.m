//
//  SandboxChangeBridge.m
//

#import "SandboxChangeBridge.h"
#include "ish/fs/fake.h"
#include <string.h>

@implementation SandboxChangeBridge

+ (void)installWithHandler:(void (^)(NSArray<NSString *> *))handler {
    if (handler == nil) {
        fakefs_install_change_consumer(nil);
        return;
    }
    void (^copied)(NSArray<NSString *> *) = [handler copy];
    fakefs_install_change_consumer(^(const struct fakefs_change_event *batch, int count) {
        if (batch == NULL || count <= 0) return;
        // 一批里同一个路径常常出现多次（write 按块记录），先去重再交给 Swift；
        // 上层还会再做一次时间窗节流。
        NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSetWithCapacity:(NSUInteger)count];
        for (int i = 0; i < count; i++) {
            // linux_path 是定长数组，用 strnlen 兜住没有终止符的极端情况
            size_t len = strnlen(batch[i].linux_path, sizeof(batch[i].linux_path));
            if (len == 0) continue;
            NSString *p = [[NSString alloc] initWithBytes:batch[i].linux_path
                                                   length:len
                                                 encoding:NSUTF8StringEncoding];
            if (p != nil) [paths addObject:p];
        }
        if (paths.count > 0) copied([paths array]);
    });
}

+ (uint64_t)droppedCount {
    return fakefs_change_dropped_count();
}

@end
