//
//  SandboxChangeBridge.h
//  fakefs 变更事件 → Swift（T3b）。
//
//  存在的理由：`fakefs_change_handler_t` 是个 ObjC block，参数是
//  `const struct fakefs_change_event *` + count，而那个 struct 里有
//  `char linux_path[1024]`——Swift 导进来是个 1024 元素的元组，处理起来极其难看。
//  这层薄壳把它翻成 NSArray<NSString *>。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SandboxChangeBridge : NSObject

/// 安装 fakefs change consumer（全局只有一个，重复调用后者覆盖前者）。
/// handler 在 fakefs 自己的串行队列上调用，参数是本批次涉及的 guest 路径（批内已去重）。
/// **必须在 ISHKernel boot 之后、任何 bind mount 之前装**（上游 ensureKernelBooted 的顺序）。
+ (void)installWithHandler:(nullable void (^)(NSArray<NSString *> *paths))handler;

/// ring 溢出丢弃计数（诊断用）
+ (uint64_t)droppedCount;

@end

NS_ASSUME_NONNULL_END
