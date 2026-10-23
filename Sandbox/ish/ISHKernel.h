//
//  ISHKernel.h
//  MemoryPalace — 搬自 OpenMinis src/ios/iSH
//  SPDX-License-Identifier: GPL-3.0-only
//  Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis), src/ios/iSH/ISHKernel.h,
//  licensed under the GNU General Public License v3.0.
//  Modifications Copyright (C) 2026 Mneme Atrium contributors, also under GPL-3.0.
//  This file is GPL-3.0; it is combined with the AGPL-3.0 app under GPL-3.0 §13.
//
//  Objective-C wrapper for iSH kernel initialization and control
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const ISHProcessExitedNotification;
extern NSNotificationName const ISHTerminalOutputNotification;

typedef void (^ISHOutputCallback)(NSData *data);
typedef void (^ISHCommandCompletionCallback)(NSString *output, NSError * _Nullable error);

@interface ISHKernel : NSObject

/// Shared instance
@property (class, readonly) ISHKernel *shared;

/// Whether the kernel has been booted
@property (nonatomic, readonly) BOOL isBooted;

/// Output callback for terminal output
@property (nonatomic, copy, nullable) ISHOutputCallback outputCallback;

/// Custom environment variables to inject into shell execution.
/// Set before calling executeCommand:. Keys and values are strings.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *customEnvironment;

/// Initialize kernel and mount root filesystem
/// @param rootPath fakefs root directory path (containing data/ and meta.db)
/// @return 0 on success, negative error code on failure
- (int)bootWithRootPath:(NSString *)rootPath;

/// Execute a command (starts interactive shell)
/// @param command Command and arguments array, e.g. @[@"/bin/sh", @"-l"]
/// @return 0 on success, negative error code on failure
- (int)executeCommand:(NSArray<NSString *> *)command;

/// Execute a command and wait for completion (detects prompt to know when done)
/// @param commandString Command string to execute
/// @param timeout Timeout in seconds (0 for no timeout)
/// @param completion Completion callback with output or error
- (void)executeCommandAndWait:(NSString *)commandString
                      timeout:(NSTimeInterval)timeout
                   completion:(ISHCommandCompletionCallback)completion;

/// Send input to the terminal
/// @param data Input data (UTF-8 encoded string)
- (void)sendInput:(NSData *)data;

/// Send input string to the terminal
/// @param input Input string
- (void)sendInputString:(NSString *)input;

/// Set terminal window size
/// @param columns Number of columns (character width)
/// @param rows Number of rows (character height)
- (void)setTerminalSize:(int)columns rows:(int)rows;

/// Bind-mount an external host directory onto a fakefs path.
/// After this call, iSH processes accessing linuxPath will transparently
/// read/write files in hostPath. Parent directories must exist in meta.db.
/// @param linuxPath Absolute path in fakefs (e.g. "/var/minis/offloads")
/// @param hostPath  Absolute path on the iOS host filesystem
/// @return 0 on success, negative error code on failure
- (int)bindMountPath:(NSString *)linuxPath toHostPath:(NSString *)hostPath;

/// Bind-mount an external host directory with an explicit read-only flag.
/// When readOnly=YES, the top-level mount directory in meta.db is written
/// with mode 0555, so iSH's standard access_check rejects any create/unlink/
/// rename/rmdir inside the mount with EACCES. No special fakefs plumbing.
/// @param linuxPath Absolute path in fakefs (e.g. "/var/minis/mounts/Obsidian")
/// @param hostPath  Absolute path on the iOS host filesystem
/// @param readOnly  If YES, the mount is exposed as a read-only directory
/// @return 0 on success, negative error code on failure
- (int)bindMountPath:(NSString *)linuxPath toHostPath:(NSString *)hostPath readOnly:(BOOL)readOnly;

/// Remove a bind mount previously created with bindMountPath:toHostPath:
/// @param linuxPath The path previously passed to bindMountPath:toHostPath:
/// @return 0 on success, negative error code on failure
- (int)bindUnmountPath:(NSString *)linuxPath;

/// Re-read system DNS configuration and update /etc/resolv.conf inside iSH.
/// Call this when the network path changes (e.g. WiFi ↔ cellular switch).
- (void)refreshDns;

@end

/// One change event emitted by the fakefs bind-mount tracker. Mirrors
/// `struct fakefs_change_event` from deps/ish/fs/fake.h.
@interface ISHFakefsChangeEvent : NSObject
@property (nonatomic, readonly) NSString *linuxPath;
@property (nonatomic, readonly) int op;          // 0=write 1=unlink 2=rename 3=truncate
@property (nonatomic, readonly) int64_t timestampNs;
/// Opaque per-thread-group fs_context value captured at record time.
/// 0 if no handler is installed or the caller hasn't tagged its task group.
@property (nonatomic, readonly) uint64_t fsContext;
@end

@interface ISHKernel (FakefsChange)

/// Install a handler for fakefs bind-mount file change events.
///
/// The handler runs on a private serial dispatch queue (not the main
/// thread). It MUST NOT block — copy events off and dispatch to your
/// own queue/actor for processing. Producer side in iSH is non-blocking
/// and bounded; if the handler stalls, ring overflow drops oldest events
/// (visible via fakefsChangeDroppedCount).
///
/// Calling this multiple times replaces the handler. Pass nil to detach.
- (void)installFakefsChangeHandler:(void (^)(NSArray<ISHFakefsChangeEvent *> *batch))handler;

/// Number of events dropped due to ring overflow since boot (diagnostic).
- (uint64_t)fakefsChangeDroppedCount;

@end

#pragma mark - Path translate hook

/// Block-form path translate hook for fakefs. Bridges the C-level
/// fakefs_path_translate_hook_t. Return non-nil host absolute path to
/// override the default g_bind_mounts[] lookup; return nil to fall through.
///
/// `guestPath` is leading-slash normalized. `fsContext` is the opaque u64
/// stamped on the calling thread group — the host assigns its meaning.
///
/// Invoked on the calling iSH worker thread, on the hot fs path. MUST be
/// non-blocking and reentrant. Avoid any work beyond a hash lookup.
typedef NSString * _Nullable (^ISHPathTranslateHandler)(NSString *guestPath,
                                                       uint64_t fsContext);

@interface ISHKernel (PathTranslate)

/// Install a host-side hook consulted for every fakefs path translation
/// (open / stat / readdir / unlink / rename / rmdir / mkdir / native offload).
/// Pass nil to detach. Calling multiple times replaces the handler.
- (void)installPathTranslateHandler:(nullable ISHPathTranslateHandler)handler;

@end

/// Reverse path-translate hook: given a host APFS path, return its guest
/// path. Invoked by realfs_getpath() after F_GETPATH resolves a bind-mount
/// symlink to an out-of-fakefs location; without it, readdir entries under
/// hook-routed paths come back with the wrong path and fail meta.db inode
/// lookup. Return nil to fall through to the default behavior.
typedef NSString * _Nullable (^ISHPathReverseHandler)(NSString *hostPath);

@interface ISHKernel (PathReverse)

/// Install the reverse hook. Pass nil to detach.
- (void)installPathReverseHandler:(nullable ISHPathReverseHandler)handler;

@end

#pragma mark - PTY sessions（#045 T2 口袋终端）

/// 交互 shell 的输出。在 guest 线程（或写入方线程，回显时）上**直接**调：不许碰 tty / 进程表，
/// 不许同步等主线程；可以为背压短暂阻塞（主线程排空就会放行）。
typedef void (^ISHPTYOutputHandler)(NSData *data);
/// shell 根进程退出。主队列上调、恰好一次。waitStatus 是 Linux wait status 字（不是退出码）。
typedef void (^ISHPTYExitHandler)(int waitStatus);

/// `ptyWrite` 返回这个 = tty 输入缓冲满了，过一会儿再写同一块
extern const NSInteger ISHPTYWriteAgain;
/// 会话令牌的命名空间（高 32 位，ASCII "MPPT"），与 `LocalShellLaunch.tokenNamespace` 一致
#define ISHPTYTokenNamespace 0x4D50505400000000ULL

/// 多会话交互 PTY（plan-terminal-t2 §2.2）。和老的单会话 `executeCommand:` 互不相干。
///
/// 归属：每个会话一个不复用的 64 位令牌，开进程时写进 guest 进程组的 `fs_context`，fork 整份继承。
/// 退出认令牌（不认 pid，pid 会复用），结束时按令牌扫整棵树，不依赖根进程还在。
/// 线程：同一个 ptyId 的 write / resize / close 由调用方串行；open 必须在非主线程的串行队列上同步调。
@interface ISHKernel (PTYSessions)

/// 起一个接在新 PTY 上的进程。返回 ptyId（>0）或负错误码。
/// 失败时已清掉表项和 tty 引用；没起跑的 guest task 跟 `ISHShellExecutor` 失败路径一样留着（极少见，见复盘）。
- (int)openPTYWithArguments:(NSArray<NSString *> *)arguments
                environment:(NSDictionary<NSString *, NSString *> *)environment
                      token:(uint64_t)token
                    columns:(int)columns
                       rows:(int)rows
                     output:(ISHPTYOutputHandler)output
                       exit:(ISHPTYExitHandler)exitHandler;

/// 非阻塞写进 tty 输入。返回吃进去的字节数；0 或 `ISHPTYWriteAgain` = 满了；其他负数 = 错误。
- (NSInteger)ptyWrite:(int)ptyId bytes:(const void *)bytes length:(NSUInteger)length;

- (void)ptyResize:(int)ptyId columns:(int)columns rows:(int)rows;

/// 不再转发输出 → 按令牌 HUP+TERM，200ms 后每 50ms 一轮 SIGKILL 直到不剩活的（≤2s）→ 以 init 身份回收僵尸 → 释放 tty。
/// 幂等。会阻塞调用线程 0.2–2 秒，别在主线程调。
- (void)ptyClose:(int)ptyId;

/// 探针用：表项数、带会话令牌的活进程数 / 僵尸数
- (NSDictionary<NSString *, NSNumber *> *)ptyDiagnostics;

/// 挂死取证（#076）：开一条专用看门狗线程，现场写进 path 和 stderr。path 开始时删掉，真留现场时才建。只第一次调用生效
- (void)ptyWatchdogStartWithLogPath:(NSString *)path;
/// 布防：seconds 秒内没撤防就留现场（guest task 状态 + 每条宿主线程的原始栈）
- (void)ptyWatchdogArm:(double)seconds tag:(NSString *)tag;
/// 撤防；返回这次布防期间看门狗有没有触发过（触发过 = 超时，哪怕之后跑完了也算失败）
- (BOOL)ptyWatchdogDisarm;
/// 立刻留一份现场（同看门狗的格式）
- (void)ptyDumpNow:(NSString *)why;

@end

#pragma mark - Scheduler Hook

@interface ISHKernel (Scheduler)

/// Enable adaptive CPU throttle for background execution. Measures
/// actual tick duration and dynamically computes nanosleep to hit the
/// target duty cycle on any device.
/// @param dutyCycle Target CPU fraction (0.0–1.0, e.g. 0.6 = 60% CPU)
- (void)enableCPUThrottleWithDutyCycle:(float)dutyCycle;

/// Disable CPU throttle (foreground mode). The hook stays installed
/// but fast-paths on dutyCycle==0 (single atomic load).
- (void)disableCPUThrottle;

/// [T-ish-bg-cpu-governor] Start the closed-loop background CPU governor
/// (see docs/ish-bg-cpu-governor-design.md): samples process-wide CPU at
/// 4 Hz into a 60s sliding window and dynamically drives the throttle
/// ratio (GREEN full speed / YELLOW proportional / RED hard brake) to keep
/// the window under the iOS background kill budget with margin. Call on
/// didEnterBackground. Idempotent.
- (void)beginBackgroundCPUGovernor;

/// Stop the governor and clear any applied throttle. Call on foreground
/// return. Idempotent.
- (void)endBackgroundCPUGovernor;

@end

NS_ASSUME_NONNULL_END
