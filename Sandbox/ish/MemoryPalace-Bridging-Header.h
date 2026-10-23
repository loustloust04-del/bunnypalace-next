//
//  MemoryPalace-Bridging-Header.h
//  离线沙箱 iOS 后端：把 ish 的 C 层与 ObjC 胶水暴露给 Swift。
//  只挂 MemoryPalaceIOS target（macOS target 不链 ish）。
//

#ifndef MemoryPalace_Bridging_Header_h
#define MemoryPalace_Bridging_Header_h

// ish umbrella（deps/include/ish/ish.h，由 scripts/build-ish.sh 生成）
// 注意：它 include 了 fs/fake.h，那个头顶部有 #ifndef ISH_INTERNAL / #error 闸门，
// 所以 iOS target 必须带 GCC_PREPROCESSOR_DEFINITIONS = ISH_INTERNAL=1 GUEST_ARM64=1。
#include "ish/ish.h"

// umbrella 里没有、bind mount / 设备节点要用的
#include "fs/devices.h"

// ObjC 胶水
#import "ISHKernel.h"
#import "ISHShellExecutor.h"
#import "SandboxChangeBridge.h"

#endif /* MemoryPalace_Bridging_Header_h */
