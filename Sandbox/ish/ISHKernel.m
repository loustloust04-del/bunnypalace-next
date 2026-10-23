//
//  ISHKernel.m
//  MemoryPalace — 搬自 OpenMinis src/ios/iSH
//  SPDX-License-Identifier: GPL-3.0-only
//  Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis), src/ios/iSH/ISHKernel.m,
//  licensed under the GNU General Public License v3.0.
//  Modifications Copyright (C) 2026 Mneme Atrium contributors, also under GPL-3.0.
//  This file is GPL-3.0; it is combined with the AGPL-3.0 app under GPL-3.0 §13.
//
//  Objective-C wrapper for iSH kernel initialization and control
//

#import "ISHKernel.h"
#import "CurrentRoot.h"
// [GH#175] For sizeof(sockaddr_un.sun_path) — the Darwin HOST limit that
// iSH's unchecked sprintf in fs/sock.c writes into. Safe to include here:
// this file does not pull in ish/fs/sock.h, so there is no clash with iSH's
// guest-ABI socket structs.
#include <sys/un.h>
#include "ish/kernel/init.h"
#include "ish/kernel/task.h"
#include "ish/kernel/calls.h"
#include "ish/kernel/fs.h"
#include "ish/fs/fake.h"
#include "ish/fs/tty.h"
#include "ish/fs/dev.h"
#include "ish/fs/devices.h"
#include "ish/fs/path.h"
#include "ish/fs/fd.h"
#include "ish/emu/cpu.h"
#include "ish/kernel/signal.h"
#include "ish/kernel/errno.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>     // realpath
#include <errno.h>
#include <sys/syslimits.h> // PATH_MAX
#include <signal.h>
#include <setjmp.h>
#include <unistd.h>     // usleep
#import <mach/mach.h>   // task_info / TASK_VM_INFO (phys_footprint)
#include <execinfo.h>
#include <fcntl.h>
#include <mach-o/dyld.h>   // 看门狗记镜像加载地址
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <resolv.h>
#import <SystemConfiguration/SystemConfiguration.h>
// [MP T0] 27 个 *Offload.h import 已删（Minis 的 native offload 机制，MP 不要）

NSNotificationName const ISHProcessExitedNotification = @"ISHProcessExited";
NSNotificationName const ISHTerminalOutputNotification = @"ISHTerminalOutput";

// Global reference to shared instance for C callbacks
static ISHKernel *g_sharedKernel = nil;

// External hooks
extern void (*exit_hook)(struct task *task, int code);

// [T-ios-ish-af-unix-sandbox GH#175] iSH translates every guest AF_UNIX address
// into a real HOST path `<sock_tmp_prefix><pid>.<socket_id>` and binds that
// (fs/sock.c). The compiled-in default is "/tmp/ishsock" — the iOS host /tmp,
// which is outside the App sandbox. See setUpUnixSocketPrefix for the full story.
extern const char *sock_tmp_prefix;

#pragma mark - Fork memory guard

// [fork-guard] Stall guest fork() while the app's memory footprint is too high.
//
// Every guest process lives inside Minis.app's own address space, so a burst
// like `xargs -P 15` running 32MB Go binaries adds ~480MB to the app's iOS
// footprint and gets the whole app SIGKILLed by Jetsam.
//
// We measure phys_footprint (TASK_VM_INFO) — the metric Jetsam actually uses to
// decide what to kill. An earlier version of this guard used
// os_proc_available_memory() (remaining headroom) with a 400MB reserve, but on
// an 8GB device the per-process limit is ~1.5-2GB, so headroom never fell
// anywhere near 400MB and the guard never fired once. Measuring what we have
// spent, not what is nominally left, is the check that trips in practice.
//
// We *block* rather than returning _EAGAIN: busybox xargs (what the Alpine
// rootfs ships) does not retry a failed fork — it calls bb_simple_perror_msg
// and exits 126, silently dropping that work item. Blocking the forking thread
// applies the same backpressure without losing work: the guest simply sees a
// slow fork() and the burst self-throttles to what the device can sustain.
//
// Safe to block here: sys_clone calls the guard before task_create_ and holds
// no kernel locks at that point (pids_lock is taken later), and it runs on the
// guest thread that asked to fork, so only that thread waits.
//
// [T-ish-forkguard-stall] THRESHOLD AND GATING, after a field report of every
// trivial guest command (`true`, `echo hi`) taking a flat ~10s.
//
// The 500MB ceiling this replaces was derived in 59714a04 from a single
// `xargs -P 10` stress run that peaked at ~317MB, with a crash at ~358MB. That
// commit's own closing note — "Still unverified on device: whether the guard
// now actually engages ... That test is what would confirm the threshold is
// right" — is exactly what went wrong: the number was never checked against
// ordinary steady-state use on a large device.
//
// Two independent defects, both visible in field logs:
//
// 1. A DEVICE-INDEPENDENT CEILING against a device-dependent limit. Jetsam's
//    per-process budget scales with installed RAM, but 500MB did not. On a 4GB
//    iPhone 11 the app idles at 84-145MB and the guard never fires; on a 12GB
//    device it idles at 885MB-1.0GB and the guard fires on EVERY fork. Same
//    binary, same workload, opposite behaviour — the ceiling was calibrated on
//    one device class and silently mis-set for the other. Scaling off physical
//    RAM restores the intent (engage before the kill zone, stay out of the way
//    below it) on both.
//
// 2. A WAIT THAT NEVER DENIES ANYTHING. On timeout the guard logs and forks
//    anyway, by design — busybox xargs would drop the work item on a failed
//    fork. But that makes the 10s a pure delay, not backpressure: with a
//    footprint that is high because the app legitimately holds that much (not
//    because a burst is in flight), nothing is going to fall in 10s, so every
//    fork pays the full penalty and then proceeds regardless. Field log: 272
//    stalls, every one of them a timeout ending in "allowing fork anyway".
//
// The fix keeps the guard's real purpose — throttling a *burst* that is
// actively inflating the footprint — and drops the cost when there is no burst:
//
//   - Gate on system memory PRESSURE first. Waiting is only meaningful when the
//     OS is actually short of memory; the field logs show pressure=normal with
//     3-4.5GB free the entire time the guard was stalling. Under normal
//     pressure we allow immediately.
//   - Scale the footprint ceiling to the device, so "high for this hardware"
//     means the same thing everywhere.
//   - Cap the wait at 2s. The guard exists to let *exiting* guest processes
//     return memory; that happens in hundreds of milliseconds or not at all,
//     and since a timeout forks anyway, a longer wait buys nothing.
//
// Threads are exempt (handled in sys_clone) since they add no separate address
// space.
//
// Ceiling = 25% of physical RAM, clamped to [500MB, 2GB]:
//   4GB device  -> 1.0GB   (idle 84-145MB, so still far below — no change in
//                           behaviour for the class where the guard was quiet)
//   8GB device  -> 2.0GB   (clamp)
//   12GB device -> 2.0GB   (clamp; idle 885MB-1.0GB now sits below it)
// The lower clamp keeps a small device from setting a ceiling so low that
// ordinary operation trips it; the upper clamp keeps a large device from
// setting one so high the guard can never engage before Jetsam does.
#define MINIS_FORK_GUARD_FOOTPRINT_FRACTION 4          // 1/4 of physical RAM
#define MINIS_FORK_GUARD_FLOOR_BYTES   (500ULL * 1024 * 1024)
#define MINIS_FORK_GUARD_CEIL_BYTES    (2048ULL * 1024 * 1024)
#define MINIS_FORK_GUARD_POLL_US       (50 * 1000)     // 50ms between checks
#define MINIS_FORK_GUARD_MAX_WAIT_US   (2 * 1000000)   // give up after 2s

static atomic_ullong g_fork_guard_stalls = 0;

// System-wide memory pressure, kept current by a dispatch source (0 = normal,
// non-zero = warn/critical). Mirrors the mechanism HangDetector.m uses for its
// [MemMonitor] readout; a private source is used rather than reaching into that
// file's statics so the two stay independent.
static atomic_uint_fast32_t g_fork_guard_pressure = ATOMIC_VAR_INIT(0);
static dispatch_source_t g_fork_guard_pressure_source = nil;

// Footprint ceiling for this device, computed once at install.
static uint64_t g_fork_guard_max_footprint = MINIS_FORK_GUARD_FLOOR_BYTES;

static uint64_t minis_fork_guard_compute_ceiling(void) {
    uint64_t ram = [NSProcessInfo processInfo].physicalMemory;
    if (ram == 0)
        return MINIS_FORK_GUARD_FLOOR_BYTES;
    uint64_t ceiling = ram / MINIS_FORK_GUARD_FOOTPRINT_FRACTION;
    if (ceiling < MINIS_FORK_GUARD_FLOOR_BYTES)
        ceiling = MINIS_FORK_GUARD_FLOOR_BYTES;
    if (ceiling > MINIS_FORK_GUARD_CEIL_BYTES)
        ceiling = MINIS_FORK_GUARD_CEIL_BYTES;
    return ceiling;
}

static void minis_fork_guard_start_pressure_source(void) {
    if (g_fork_guard_pressure_source != nil)
        return;
    g_fork_guard_pressure_source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN |
        DISPATCH_MEMORYPRESSURE_CRITICAL,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (g_fork_guard_pressure_source == nil)
        return;
    dispatch_source_set_event_handler(g_fork_guard_pressure_source, ^{
        unsigned long flags = dispatch_source_get_data(g_fork_guard_pressure_source);
        uint32_t level = 0;
        if (flags & DISPATCH_MEMORYPRESSURE_CRITICAL) level = 2;
        else if (flags & DISPATCH_MEMORYPRESSURE_WARN) level = 1;
        atomic_store_explicit(&g_fork_guard_pressure, level, memory_order_relaxed);
    });
    dispatch_resume(g_fork_guard_pressure_source);
}

// Current phys_footprint in bytes, or 0 if unavailable. Matches the TASK_VM_INFO
// pattern already used by HangDetector.m and BrowserResourceMonitor.swift.
static uint64_t minis_current_phys_footprint(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                 (task_info_t) &info, &count);
    if (kr != KERN_SUCCESS)
        return 0;
    return (uint64_t) info.phys_footprint;
}

static int minis_fork_memory_guard(void) {
    // A 0 reading means task_info failed; treat that as "no information" and
    // allow the fork rather than stalling every process spawn.
    uint64_t footprint = minis_current_phys_footprint();
    if (footprint == 0 || footprint < g_fork_guard_max_footprint)
        return 0;

    // [T-ish-forkguard-stall] Above the ceiling, but is the SYSTEM actually
    // short of memory? Waiting only helps when memory is genuinely contended;
    // a high footprint under normal pressure just means the app legitimately
    // holds that much, and nothing is going to hand it back inside the wait.
    // The field logs are unambiguous on this: every one of the 272 stalls ran
    // with pressure=normal and 3-4.5GB free, waited the full timeout, and then
    // forked anyway. Allowing immediately here is what removes the per-fork
    // penalty; the wait below is preserved for the case it was written for —
    // real pressure, where backing off can let exiting processes return memory.
    // A dispatch memory-pressure source only fires on TRANSITIONS, so if the
    // system was already under pressure when the source was created we may not
    // have been told yet and would read a stale 0. Treat a footprint far past
    // the ceiling as its own evidence of trouble and fall back to the wait,
    // independent of what the source has reported. Without this the guard
    // would be fully disabled in exactly the situation it exists for: a burst
    // that inflates the footprint faster than pressure notifications arrive.
    uint32_t pressure = atomic_load_explicit(&g_fork_guard_pressure, memory_order_relaxed);
    BOOL farOverCeiling = footprint > g_fork_guard_max_footprint +
                                      (g_fork_guard_max_footprint / 2);   // 1.5x
    if (pressure == 0 && !farOverCeiling)
        return 0;

    uint64_t n = atomic_fetch_add_explicit(&g_fork_guard_stalls, 1, memory_order_relaxed) + 1;
    uint64_t first_footprint = footprint;
    useconds_t waited_us = 0;

    // Wait for the footprint to fall as earlier guest processes exit. Bounded so
    // a workload whose memory never comes back stalls briefly instead of hanging.
    while (waited_us < MINIS_FORK_GUARD_MAX_WAIT_US) {
        usleep(MINIS_FORK_GUARD_POLL_US);
        waited_us += MINIS_FORK_GUARD_POLL_US;

        footprint = minis_current_phys_footprint();

        // Pressure clearing is the signal we were waiting for, so stop waiting
        // even if our own footprint is unchanged. Guarded by the same 1.5x
        // check as the entry test: when we got here on the far-over-ceiling
        // path (pressure never reported), a still-0 pressure reading is not
        // news and must not short-circuit the wait on the first poll.
        if (atomic_load_explicit(&g_fork_guard_pressure, memory_order_relaxed) == 0 &&
            footprint <= g_fork_guard_max_footprint + (g_fork_guard_max_footprint / 2))
            return 0;
        if (footprint == 0 || footprint < g_fork_guard_max_footprint) {
            // Log the first stall of a burst and then every 64th, so a throttled
            // workload doesn't flood the log through LoggingManager.
            if (n == 1 || (n % 64) == 0) {
                NSLog(@"ISHKernel: [ForkGuard] fork resumed after %ums — footprint %.1fMB -> %.1fMB (stalls=%llu)",
                      waited_us / 1000, (double) first_footprint / (1024.0 * 1024.0),
                      (double) footprint / (1024.0 * 1024.0), n);
            }
            return 0;
        }
    }

    // Timed out. Allowing the fork risks Jetsam, but denying it would make
    // busybox xargs drop the work item outright — a silent wrong answer is
    // worse than a risky one, so allow it and leave a loud trace.
    NSLog(@"ISHKernel: [ForkGuard] WARNING timed out after %ums with footprint still %.1fMB "
          @"(max %.0fMB, pressure=%u) — allowing fork anyway (stalls=%llu)",
          waited_us / 1000, (double) footprint / (1024.0 * 1024.0),
          (double) g_fork_guard_max_footprint / (1024.0 * 1024.0), pressure, n);
    return 0;
}

#pragma mark - JIT Crash Recovery Handler

// Thread-local JIT recovery state (defined in asbestos.c)
extern __thread volatile sig_atomic_t in_jit;
extern __thread volatile uint64_t jit_saved_pc;

// Assembly trampoline: returns INT_JIT_CRASH via fiber_exit (defined in entry.S)
extern void jit_crash_trampoline(void);

// cpu_state field offsets (must match cpu-offsets.h)
#define CRASH_CPU_pc 272
#define CRASH_CPU_segfault_addr 832
#define CRASH_CPU_segfault_was_write 840
#define CRASH_LOCAL_jit_exit_sp 920

/// Handles SIGSEGV/SIGBUS from JIT code (stale TLB pointers from concurrent CoW).
/// Uses ucontext PC manipulation to redirect to jit_crash_trampoline.
static void jit_crash_handler(int sig, siginfo_t *info, void *ctx) {
#ifdef __aarch64__
    if ((sig == SIGSEGV || sig == SIGBUS) && in_jit) {
        ucontext_t *uc = (ucontext_t *)ctx;

        // _cpu is in x1 — pointer to cpu_state within fiber_frame
        uint64_t cpu_ptr = uc->uc_mcontext->__ss.__x[1];

        // Reconstruct guest segfault_addr from registers
        uint64_t x7 = uc->uc_mcontext->__ss.__x[7];
        uint64_t x10 = uc->uc_mcontext->__ss.__x[10];
        uint64_t guest_addr = (x7 - x10) & 0xffffffffffffULL;

        // Determine read/write from host ESR
        uint64_t esr = uc->uc_mcontext->__es.__esr;
        int was_write = (esr & 0x40) != 0;

        // Write crash info directly to cpu_state
        *(uint64_t *)(cpu_ptr + CRASH_CPU_segfault_addr) = guest_addr;
        *(int *)(cpu_ptr + CRASH_CPU_segfault_was_write) = was_write;
        *(uint64_t *)(cpu_ptr + CRASH_CPU_pc) = (uint64_t)jit_saved_pc;

        // Restore SP to the value saved by fiber_enter
        uint64_t exit_sp = *(uint64_t *)(cpu_ptr + CRASH_LOCAL_jit_exit_sp);
        uc->uc_mcontext->__ss.__sp = exit_sp;

        // Redirect execution to crash trampoline
        uc->uc_mcontext->__ss.__pc = (uint64_t)jit_crash_trampoline;

        // Unblock signal so it can fire again
        sigset_t unblock;
        sigemptyset(&unblock);
        sigaddset(&unblock, sig);
        sigprocmask(SIG_UNBLOCK, &unblock, NULL);

        return;
    }
#endif
    // Check if this is an iSH guest thread by testing the thread-local `in_jit` variable.
    // `in_jit` is only ever set on iSH execution threads. For non-iSH threads (e.g. Swift
    // async tasks, networking, UI), we must NOT intercept the signal — doing so kills the
    // thread via pthread_exit, which crashes the app (FOUNDATION 1 termination).
    // Instead, reset the signal to default and re-raise so the system crash reporter
    // handles it normally.
    //
    // Note: `in_jit` is 0 here (the in_jit==1 case was handled above). We use a separate
    // thread-local marker set when iSH threads start, to distinguish iSH threads with
    // in_jit==0 (between JIT runs) from non-iSH threads (never set).
    extern __thread int ish_thread_marker;
    if (!ish_thread_marker) {
        // Not an iSH thread — restore default handler and re-raise
        struct sigaction sa_default = {0};
        sa_default.sa_handler = SIG_DFL;
        sigaction(sig, &sa_default, NULL);
        raise(sig);
        return;
    }

    // Non-JIT crash in an iSH guest thread.
    // Unlike upstream (standalone process where _exit is fine), we're embedded
    // in the app — _exit would kill the entire app. Instead, log diagnostics
    // and terminate only this guest thread.
    char buf[512];
    int len;
    ucontext_t *uc = (ucontext_t *)ctx;
    len = snprintf(buf, sizeof(buf), "\n=== iSH GUEST CRASH: signal %d ===\nfault addr: %p\n", sig, info->si_addr);
    write(STDERR_FILENO, buf, len);
#ifdef __aarch64__
    len = snprintf(buf, sizeof(buf),
        "pc:  0x%llx\nlr:  0x%llx\nsp:  0x%llx\n"
        "x0:  0x%llx\nx1:  0x%llx\nx2:  0x%llx\n"
        "x7:  0x%llx\nx28: 0x%llx\n",
        uc->uc_mcontext->__ss.__pc, uc->uc_mcontext->__ss.__lr,
        uc->uc_mcontext->__ss.__sp,
        uc->uc_mcontext->__ss.__x[0], uc->uc_mcontext->__ss.__x[1],
        uc->uc_mcontext->__ss.__x[2],
        uc->uc_mcontext->__ss.__x[7], uc->uc_mcontext->__ss.__x[28]);
    write(STDERR_FILENO, buf, len);
#endif
    void *bt[20];
    int n = backtrace(bt, 20);
    backtrace_symbols_fd(bt, n, STDERR_FILENO);

    // Block all signals and suspend this thread forever.
    // pthread_exit() triggers SIGTRAP on iOS in certain thread states.
    sigset_t all;
    sigfillset(&all);
    pthread_sigmask(SIG_BLOCK, &all, NULL);
    select(0, NULL, NULL, NULL, NULL);
    __builtin_unreachable();
}

/// Custom die handler for embedded iSH: logs the fatal message and terminates
/// only the current thread instead of calling abort() which kills the entire app.
static void embedded_die_handler(const char *msg) {
    // Log to stderr (captured by LoggingManager)
    char buf[4096];
    int len = snprintf(buf, sizeof(buf), "\n=== iSH FATAL: %s ===\n", msg);
    write(STDERR_FILENO, buf, len);
    NSLog(@"ISHKernel: die() called: %s", msg);

    // Block all signals and suspend this thread forever.
    // pthread_exit() triggers SIGTRAP on iOS in certain thread states,
    // crashing the entire app. The iSH task thread is expendable — parking
    // it is safe and avoids taking down the process.
    sigset_t all;
    sigfillset(&all);
    pthread_sigmask(SIG_BLOCK, &all, NULL);
    select(0, NULL, NULL, NULL, NULL);  // sleep forever
    __builtin_unreachable();
}

static void install_jit_crash_handler(void) {
    static char altstack[SIGSTKSZ];
    stack_t ss = {.ss_sp = altstack, .ss_size = SIGSTKSZ};
    sigaltstack(&ss, NULL);

    struct sigaction sa = {0};
    sa.sa_sigaction = jit_crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    // Note: SIGABRT intentionally NOT handled — it's used by the system
    // (assert(), Swift runtime, malloc failure) and intercepting it prevents
    // normal crash reporting and can mask OOM conditions.
    NSLog(@"ISHKernel: JIT crash recovery handler installed");
}

// Forward declaration of private methods for C callbacks
@interface ISHKernel()
- (void)handleCommandOutputInternal:(NSString *)output;
@end

#pragma mark - PTY session table（#045 T2）

const NSInteger ISHPTYWriteAgain = _EAGAIN;

/// 一个交互 PTY 会话。表项存在期间宿主一直握着 tty 的一份引用，所以 `tty` 指针有效、不会被别的 tty 复用。
@interface ISHPTYRecord : NSObject
@property (nonatomic) int ptyId;
@property (nonatomic) struct tty *tty;
@property (nonatomic) pid_t_ rootPid;
@property (nonatomic) uint64_t token;
@property (nonatomic, copy) ISHPTYOutputHandler output;
@property (nonatomic, copy) ISHPTYExitHandler exitHandler;
@property (atomic) BOOL exited;
@property (atomic) BOOL closing;
@end

@implementation ISHPTYRecord
@end

// 叶子锁：持有时不碰 tty / pids_lock / 任何回调。
static pthread_mutex_t g_pty_lock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary<NSNumber *, ISHPTYRecord *> *g_pty_by_id;
static NSMapTable *g_pty_by_tty;   // struct tty * → ISHPTYRecord
static atomic_int g_pty_count = 0;
static int g_pty_next_id = 1;
/// 老的单会话 `executeCommand:` 开的那个 PTY（输出走原路）
static struct tty *g_legacy_pty = NULL;

static void pty_table_init_once(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_pty_by_id = [NSMutableDictionary dictionary];
        g_pty_by_tty = [[NSMapTable alloc]
            initWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                  valueOptions:NSPointerFunctionsStrongMemory
                      capacity:8];
    });
}

static ISHPTYRecord *pty_record_for_tty(struct tty *tty) {
    if (atomic_load_explicit(&g_pty_count, memory_order_acquire) == 0) return nil;
    pthread_mutex_lock(&g_pty_lock);
    ISHPTYRecord *rec = (__bridge ISHPTYRecord *)NSMapGet(g_pty_by_tty, tty);
    pthread_mutex_unlock(&g_pty_lock);
    return rec;
}

static ISHPTYRecord *pty_record_for_id(int ptyId) {
    pthread_mutex_lock(&g_pty_lock);
    ISHPTYRecord *rec = g_pty_by_id[@(ptyId)];
    pthread_mutex_unlock(&g_pty_lock);
    return rec;
}

/// 按令牌给整棵树发信号。fs_context 在 fork 时继承，不靠 pid / 祖先链 / 根还在不在。
static void pty_signal_token(uint64_t token, int sig) {
    struct siginfo_ info = SIGINFO_NIL;
    lock(&pids_lock);
    for (int i = 2; i < MAX_PID; i++) {
        struct task *t = pid_get_task(i);
        if (t == NULL || t->group == NULL) continue;
        if (t->group->fs_context == token)
            send_signal(t, sig, info);
    }
    unlock(&pids_lock);
}

/// 还活着（非僵尸）的、带这个令牌的 task 数
static int pty_live_token_tasks(uint64_t token) {
    int live = 0;
    lock(&pids_lock);
    for (int i = 2; i < MAX_PID; i++) {
        struct task *t = pid_get_task(i);
        if (t != NULL && t->group != NULL && t->group->fs_context == token) live++;
    }
    unlock(&pids_lock);
    return live;
}

#pragma mark - PTY 挂死取证（#076）

// 现场 dump 专给「已经死锁」的时候用，所以全程不 malloc、不符号化、不调 pthread_mach_thread_np(别的线程)、
// 不碰 stdio / NSLog / dyld（这些都有锁，卡住的线程可能正握着）：snprintf 到栈上，write(2) 直接写 fd。
// 栈只给原始返回地址；镜像加载地址在 ptyWatchdogStart 时（还正常的时候）先写进文件头，离线用 atos 符号化。

#define PTY_DUMP_FRAMES 24

static void pty_raw_write(int fd, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void pty_raw_write(int fd, const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    size_t len = MIN((size_t)n, sizeof(buf) - 1);
    for (size_t off = 0; off < len; ) {
        ssize_t w = write(fd, buf + off, len - off);
        if (w <= 0) return;
        off += (size_t)w;
    }
}

/// 把一个宿主线程停一下、沿帧指针链抄出返回地址，再放开。停着的时候不 malloc（它可能正握着 malloc 锁）
static int pty_capture_stack(thread_act_t port, uintptr_t *frames, int max) {
#if defined(__arm64__)
    if (port == MACH_PORT_NULL || port == pthread_mach_thread_np(pthread_self()) || thread_suspend(port) != KERN_SUCCESS)
        return 0;
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    int n = 0;
    if (thread_get_state(port, ARM_THREAD_STATE64, (thread_state_t)&state, &count) == KERN_SUCCESS) {
        frames[n++] = (uintptr_t)arm_thread_state64_get_pc(state);
        if (n < max) frames[n++] = (uintptr_t)arm_thread_state64_get_lr(state);
        uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(state);
        while (n < max && fp != 0 && (fp & 0xf) == 0) {
            uintptr_t pair[2];
            vm_size_t got = 0;
            if (vm_read_overwrite(mach_task_self(), fp, sizeof(pair), (vm_address_t)pair, &got) != KERN_SUCCESS) break;
            if (pair[1] == 0 || pair[0] <= fp) break;
            frames[n++] = pair[1];
            fp = pair[0];
        }
    }
    thread_resume(port);
    return n;
#else
    return 0;
#endif
}

/// guest task 一行一个（pid / 父 / 令牌 / 僵尸 / 退出中 / 停止 / 挂起与屏蔽的信号 / 是否在等条件变量 / 宿主 pthread_t），
/// 再列进程里每条宿主线程：pthread_t（和 guest 行、锁持有者对得上）、线程名（guest 线程叫 "<comm>-<pid>"）、原始栈。
/// pids_lock 只试 1 秒，拿不到就不列 task（无锁读会撞上并发回收、反倒把 App 弄崩）；拿到了也只在锁里抄快照，
/// 解锁后再写（写 stderr 可能阻塞，不能占着 pids_lock 冻住所有 guest）。不加 sighand 锁，字段不是同一瞬间的。
/// 同一时间只许一个采样者：两个采样线程互相 thread_suspend 会谁也放不开谁，后来的直接跳过。
#define PTY_DUMP_TASKS 128
struct pty_task_snap {
    pid_t_ pid, tgid, ppid, pgid, sid;
    char comm[16];
    uint64_t ctx, pending, blocked;
    bool zombie, exiting, stopped, groupexit, sighand, waitcond, blocking;
    void *thread;
};
static struct pty_task_snap g_pty_snaps[PTY_DUMP_TASKS];
static atomic_flag g_pty_dumping = ATOMIC_FLAG_INIT;

static void pty_raw_dump(const int *fds, int nfds) {
#define OUT(...) for (int o = 0; o < nfds; o++) pty_raw_write(fds[o], __VA_ARGS__)
    if (atomic_flag_test_and_set(&g_pty_dumping)) {
        OUT("(另一份现场正在采，这份跳过)\n");
        return;
    }
    OUT("pids_lock owner pthread %p, ttys_lock owner pthread %p\n", (void *)pids_lock.owner, (void *)ttys_lock.owner);
    bool locked = false;
    for (int i = 0; i < 100 && !(locked = pthread_mutex_trylock(&pids_lock.m) == 0); i++)
        usleep(10 * 1000);
    int ntasks = 0;
    if (locked) {
        for (int i = 1; i < MAX_PID && ntasks < PTY_DUMP_TASKS; i++) {
            struct task *t = pid_get_task_zombie(i);
            if (t == NULL || t->group == NULL) continue;
            struct pty_task_snap *s = &g_pty_snaps[ntasks++];
            *s = (struct pty_task_snap) {
                .pid = t->pid, .tgid = t->tgid, .ppid = t->parent ? t->parent->pid : 0,
                .pgid = t->group->pgid, .sid = t->group->sid, .ctx = t->group->fs_context,
                .pending = t->pending, .blocked = t->blocked, .zombie = t->zombie, .exiting = t->exiting,
                .stopped = t->group->stopped, .groupexit = t->group->doing_group_exit, .sighand = t->sighand != NULL,
                .waitcond = t->waiting_cond != NULL, .blocking = t->blocking, .thread = (void *)t->thread,
            };
            memcpy(s->comm, t->comm, sizeof(s->comm));
        }
        unlock(&pids_lock);
    } else {
        OUT("(pids_lock 1 秒没拿到，task 明细跳过)\n");
    }
    for (int i = 0; i < ntasks; i++) {
        struct pty_task_snap *s = &g_pty_snaps[i];
        OUT("pid %d tgid %d ppid %d pgid %d sid %d comm=%.16s ctx=%llx zombie=%d exiting=%d stopped=%d "
            "groupexit=%d sighand=%d pending=%llx blocked=%llx waitcond=%d blocking=%d pthread %p\n",
            s->pid, s->tgid, s->ppid, s->pgid, s->sid, s->comm, (unsigned long long)s->ctx, s->zombie, s->exiting,
            s->stopped, s->groupexit, s->sighand, (unsigned long long)s->pending, (unsigned long long)s->blocked,
            s->waitcond, s->blocking, s->thread);
    }

    thread_act_array_t threads;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) == KERN_SUCCESS) {
        OUT("--- %u host threads ---\n", count);
        uintptr_t frames[PTY_DUMP_FRAMES];
        for (mach_msg_type_number_t i = 0; i < count; i++) {
            thread_identifier_info_data_t ident = {0};
            mach_msg_type_number_t ic = THREAD_IDENTIFIER_INFO_COUNT;
            thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ident, &ic);
            thread_extended_info_data_t ext = {0};
            mach_msg_type_number_t ec = THREAD_EXTENDED_INFO_COUNT;
            thread_info(threads[i], THREAD_EXTENDED_INFO, (thread_info_t)&ext, &ec);
            int n = pty_capture_stack(threads[i], frames, PTY_DUMP_FRAMES);
            OUT("thread pthread 0x%llx name=%.64s state=%d\n",
                (unsigned long long)ident.thread_handle, ext.pth_name, ext.pth_run_state);
            for (int f = 0; f < n; f++)
                OUT("  %2d 0x%lx\n", f, (unsigned long)frames[f]);
            mach_port_deallocate(mach_task_self(), threads[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_act_t));
    }
    atomic_flag_clear(&g_pty_dumping);
#undef OUT
}

// 看门狗：专用 pthread，0.25 秒醒一次看截止时间；到点先写结果行、再把现场写进文件和 stderr。
// 不依赖主线程 / GCD / 内核锁；截止时间、标签、「触发过」由一把只有它和布防方用的锁护着，锁里只抄几个字段
// 现场文件第一次真要写时才建（没出事就没有这个文件）；镜像加载地址在布防前就抄好，建文件时写进文件头
static char g_pty_wd_path[PATH_MAX];
static _Atomic int g_pty_wd_fd = -1;
#define PTY_MAX_IMAGES 8
static const void *g_pty_image_hdr[PTY_MAX_IMAGES];
static const char *g_pty_image_name[PTY_MAX_IMAGES];
static int g_pty_nimages = 0;
static pthread_mutex_t g_pty_wd_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_pty_wd_deadline_ns = 0;   // 0 = 没布防
static bool g_pty_wd_fired = false;
static char g_pty_wd_tag[128];

static uint64_t pty_now_ns(void) {
    return clock_gettime_nsec_np(CLOCK_MONOTONIC);
}

static int pty_hang_log_fd(void) {
    int fd = atomic_load(&g_pty_wd_fd);
    if (fd >= 0 || g_pty_wd_path[0] == '\0') return fd;
    int opened = open(g_pty_wd_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (opened < 0) return -1;
    int expected = -1;
    if (!atomic_compare_exchange_strong(&g_pty_wd_fd, &expected, opened)) {
        close(opened);   // 别的采样者抢先建好了
        return expected;
    }
    for (int i = 0; i < g_pty_nimages; i++)
        pty_raw_write(opened, "image %p %s\n", g_pty_image_hdr[i], g_pty_image_name[i]);
    return opened;
}

static void pty_dump_to_all(const char *why) {
    int fds[2], n = 0;
    int file = pty_hang_log_fd();
    if (file >= 0) fds[n++] = file;
    fds[n++] = STDERR_FILENO;
    for (int i = 0; i < n; i++) pty_raw_write(fds[i], "\n=== [SBX-PTY] 现场：%s ===\n", why);
    pty_raw_dump(fds, n);
    for (int i = 0; i < n; i++) pty_raw_write(fds[i], "=== [SBX-PTY] 现场结束 ===\n");
}

static void *pty_watchdog_main(void *arg) {
    (void)arg;
    pthread_setname_np("pty-watchdog");
    for (;;) {
        usleep(250 * 1000);
        char tag[sizeof(g_pty_wd_tag)];
        pthread_mutex_lock(&g_pty_wd_lock);
        bool due = g_pty_wd_deadline_ns != 0 && pty_now_ns() >= g_pty_wd_deadline_ns;
        if (due) {
            g_pty_wd_deadline_ns = 0;
            g_pty_wd_fired = true;
            memcpy(tag, g_pty_wd_tag, sizeof(tag));
        }
        pthread_mutex_unlock(&g_pty_wd_lock);
        if (!due) continue;
        pty_raw_write(STDERR_FILENO, "[SBX-PTY] === 结果：场景「%s」超时，现场见下面 / Documents/sandbox-pty-hang.log ===\n", tag);
        char why[192];
        snprintf(why, sizeof(why), "场景「%s」超时（看门狗）", tag);
        pty_dump_to_all(why);
    }
    return NULL;
}


/// 结束一棵树：HUP + TERM，给 200ms 体面退出，然后每 50ms 一轮 SIGKILL 直到一个活的都不剩（最多 2 秒）。
/// 一轮扫描不是屏障——扫的同时可能正有进程在 fork（sol 实现审 #6），所以要扫到清零为止。
static void pty_kill_until_gone(uint64_t token) {
    pty_signal_token(token, SIGHUP_);
    pty_signal_token(token, SIGTERM_);
    usleep(200 * 1000);
    for (int round = 0; round < 40 && pty_live_token_tasks(token) > 0; round++) {
        pty_signal_token(token, SIGKILL_);
        usleep(50 * 1000);
    }
    if (pty_live_token_tasks(token) > 0)
        pty_dump_to_all("SIGKILL 扫满 40 轮还有活的");
}

// exit.c 里的 do_wait 没进头文件；常量同 exit.c:469-477
extern int do_wait(int idtype, pid_t_ id, struct siginfo_ *info, struct rusage_ *rusage, int options);
#define PTY_WNOHANG_ (1 << 0)
#define PTY_WEXITED_ (1 << 2)
#define PTY_P_PID_ 1

/// 以 init 的身份回收带这个令牌、父进程是 init 的僵尸。
/// 我们的 init 不跑 guest 程序、没人 wait，不回收的话僵尸一直握着控制终端引用（tty 和 pts 号永远放不掉）和 pid。
///
/// 会话首进程**最后**收。iSH 的 task_leave_session（deps/ish/kernel/group.c:81-95）先把自己摘出会话链表、
/// 再 `pid_get(sid)->session`：首进程已经被收掉、自己又是会话里最后一个时，那个 pid 槽空了，pid_get 回 NULL，
/// 空指针崩（#076：master 上探针的「挂死」就是这个崩溃，见 docs/research-terminal-t2-rework.md §2）。
/// 首进程早就不在了（被 guest 里自己的父进程收掉，比如会话里有人 setsid）的成员不收：漏一个僵尸 / pts 号，好过 App 崩。
/// 一批最多 64 个，分批收到收干净：有成员就只收成员，成员一个不剩了才收首进程。
static void pty_reap_token_zombies(uint64_t token) {
    int skipped = 0;
    for (int batch = 0; batch < MAX_PID / 64 + 2; batch++) {
        pid_t_ members[64], leaders[64];
        int nmembers = 0, nleaders = 0;
        skipped = 0;
        lock(&pids_lock);
        struct task *init = pid_get_task(1);
        for (int i = 2; i < MAX_PID; i++) {
            struct task *t = pid_get_task_zombie(i);
            if (t == NULL || !t->zombie || t->group == NULL || t->group->fs_context != token) continue;
            if (!task_is_leader(t) || t->parent != init) continue;
            if (t->pid == t->group->sid) {
                if (nleaders < 64) leaders[nleaders++] = t->pid;
            } else if (t->group->tty == NULL || pid_get_task_zombie(t->group->sid) != NULL) {
                if (nmembers < 64) members[nmembers++] = t->pid;
            } else {
                skipped++;
            }
        }
        unlock(&pids_lock);
        pid_t_ *batchPids = nmembers > 0 ? members : leaders;
        int n = nmembers > 0 ? nmembers : nleaders;
        if (init == NULL || n == 0) break;

        struct task *saved = current;
        current = init;
        for (int i = 0; i < n; i++) {
            struct siginfo_ info = {};
            do_wait(PTY_P_PID_, batchPids[i], &info, NULL, PTY_WEXITED_ | PTY_WNOHANG_);
        }
        current = saved;
    }
    if (skipped > 0)
        NSLog(@"ISHKernel[pty]: token %llx: %d zombie(s) left unreaped (session leader already gone)", (unsigned long long)token, skipped);
}

/// 改 tty 尺寸并通知前台进程组。**不能持 tty->lock 发信号**：send_group_signal 要拿 pids_lock，
/// 而 tty_read 是先 pids_lock 后 tty->lock（tty.c:445），反着拿会死锁（sol 实现审 #1）
static void pty_set_winsize(struct tty *tty, int columns, int rows) {
    struct winsize_ winsize = {.row = (word_t)MAX(rows, 1), .col = (word_t)MAX(columns, 1), .xpixel = 0, .ypixel = 0};
    lock(&tty->lock);
    tty->winsize = winsize;
    pid_t_ fg = tty->fg_group;
    unlock(&tty->lock);
    if (fg != 0)
        send_group_signal(fg, SIGWINCH_, SIGINFO_NIL);
}

#pragma mark - TTY Driver

// TTY write callback - sends output to UI
static int ish_tty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    if (len == 0) return 0;

    // #045：多会话 PTY 的输出直接交给它自己的回调，不走下面的主队列 + 全局通知
    ISHPTYRecord *rec = pty_record_for_tty(tty);
    if (rec != nil) {
        // 切成 ≤64KB 一块交：宿主那边的待显示上限才真有界（sol 实现审 #8）
        const size_t chunk = 64 * 1024;
        for (size_t off = 0; off < len && !rec.closing; off += chunk) {
            @autoreleasepool {
                rec.output([NSData dataWithBytes:(const char *)buf + off length:MIN(chunk, len - off)]);
            }
        }
        return (int)len;
    }
    // 会话关掉后还没死透的进程往那个 tty 写：吞掉。init console（tty1…）和老的单会话 PTY 照走原路
    if (tty->type == TTY_PSEUDO_SLAVE_MAJOR && tty != g_legacy_pty)
        return (int)len;

    NSData *data = [NSData dataWithBytes:buf length:len];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    dispatch_async(dispatch_get_main_queue(), ^{
        // If we're waiting for command completion, buffer the output
        if (g_sharedKernel) {
            [g_sharedKernel handleCommandOutputInternal:text];
        }

        // Call output callback if set
        if (g_sharedKernel.outputCallback) {
            g_sharedKernel.outputCallback(data);
        } else {
            NSLog(@"ISHKernel: Warning - no output callback set");
        }

        // Also post notification
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ISHTerminalOutputNotification
            object:nil
            userInfo:@{@"data": data}];
    });

    return (int)len;
}

static int ish_tty_init(struct tty *tty) {
    return 0;
}

static void ish_tty_cleanup(struct tty *tty) {
}

// Define TTY driver operations
static struct tty_driver_ops ish_console_ops = {
    .init = ish_tty_init,
    .write = ish_tty_write,
    .cleanup = ish_tty_cleanup,
};

// Define console TTY driver (used for init process stdio)
DEFINE_TTY_DRIVER(ish_console_driver, &ish_console_ops, TTY_CONSOLE_MAJOR, 8);

// PTY driver for interactive shell sessions (uses pty_open_fake)
static struct tty_driver ish_pty_driver = {.ops = &ish_console_ops};

#pragma mark - Process Exit Handler

static void handle_process_exit(struct task *task, int code) {
    // #045：交互 PTY 会话的根进程退出。exit_hook 在 do_exit 里持 pids_lock、进程还没被回收时同步调，
    // 这时按令牌标记，pid 不可能已经被别人复用。
    if (task->group != NULL && atomic_load_explicit(&g_pty_count, memory_order_acquire) > 0) {
        uint64_t token = task->group->fs_context;
        ISHPTYExitHandler deliver = nil;
        pthread_mutex_lock(&g_pty_lock);
        for (ISHPTYRecord *rec in g_pty_by_id.objectEnumerator) {
            if (rec.token == token && rec.rootPid == task->tgid && !rec.exited) {
                rec.exited = YES;
                deliver = rec.exitHandler;
                break;
            }
        }
        pthread_mutex_unlock(&g_pty_lock);
        if (deliver != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{ deliver(code); });
        }
    }

    // Only notify for init (parent == NULL) and direct children of init
    // (parent->parent == NULL). Grandchildren and deeper descendants are
    // ignored to avoid pids_lock contention with sys_wait4/wait_for.
    if (task->parent != NULL && task->parent->parent != NULL)
        return;

    pid_t pid = task->pid;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:ISHProcessExitedNotification
            object:nil
            userInfo:@{@"pid": @(pid), @"code": @(code)}];
    });
}

#pragma mark - ISHKernel Implementation

@implementation ISHKernel {
    BOOL _isBooted;
    struct tty *_consoleTTY;
    NSString *_rootPath;    // Host filesystem path to fakefs root (contains data/ + meta.db)
    NSString *_dataPath;    // Host filesystem path to fakefs data/ directory
    NSString *_dnsHostPath; // Host path to resolv.conf (Library/Application Support/MemoryPalace/sandbox/dns/resolv.conf)

    // Command execution state
    NSMutableString *_commandOutputBuffer;
    ISHCommandCompletionCallback _commandCompletionCallback;
    NSTimer *_commandTimeoutTimer;
    dispatch_queue_t _commandQueue;
}

+ (ISHKernel *)shared {
    static ISHKernel *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ISHKernel alloc] init];
        g_sharedKernel = instance;
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _isBooted = NO;
        _consoleTTY = NULL;
        _commandOutputBuffer = [NSMutableString new];
        _commandQueue = dispatch_queue_create("com.minisapp.ish.command", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isBooted {
    return _isBooted;
}

- (int)bootWithRootPath:(NSString *)rootPath {
    if (_isBooted) {
        NSLog(@"ISHKernel: Already booted");
        return 0;
    }

    int err;

    // 0. Install JIT crash recovery handler (must be before any JIT code runs)
    install_jit_crash_handler();

    // Override die() to terminate only the iSH thread instead of abort()ing the app.
    extern void (*die_handler)(const char *msg);
    die_handler = embedded_die_handler;

    // 1. Mount root filesystem
    _rootPath = rootPath;
    _dataPath = [rootPath stringByAppendingPathComponent:@"data"];
    err = mount_root(&fakefs, _dataPath.fileSystemRepresentation);
    if (err < 0) {
        NSLog(@"ISHKernel: mount_root failed: %d", err);
        return err;
    }
    NSLog(@"ISHKernel: Root filesystem mounted at %@", _dataPath);

    // Register the rootfs's canonical (symlink-resolved) host path with
    // fakefs so fakefs_bind_mount_resolve_path can suppress
    // self-containing bind mounts. F_GETPATH on Apple platforms returns
    // the canonical path (e.g. /Users/<user>/Library/Containers/<bundle>
    // /Data/Documents/alpine-rootfs/data), so we must canonicalize via
    // realpath() — otherwise the ancestor check below misses on macOS
    // where the user's home tree happens to contain the sandbox.
    char canonical_data_path[PATH_MAX];
    if (realpath(_dataPath.fileSystemRepresentation, canonical_data_path) != NULL) {
        NSLog(@"ISHKernel: rootfs canonical data path = %s", canonical_data_path);
        fakefs_set_rootfs_data_path(canonical_data_path);
    } else {
        NSLog(@"ISHKernel: realpath(_dataPath) failed (errno=%d), bind-mount cycle guard disabled", errno);
    }

    // 2. Become init process (PID 1)
    err = become_first_process();
    if (err < 0) {
        NSLog(@"ISHKernel: become_first_process failed: %d", err);
        return err;
    }
    current->thread = pthread_self();
    NSLog(@"ISHKernel: Init process created (PID 1)");

    // 3. Create device nodes
    [self createDeviceNodes];

    // 3.5. Apply rootfs overlay patches (e.g. fetch-polyfill.js)
    FsApplyOverlay();

    // 4. Mount proc and devpts filesystems
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    NSLog(@"ISHKernel: /proc and /dev/pts mounted");

    // 5. Bind-mount and configure DNS
    [self mountDnsConfig];

    // 6. Set exit hook
    exit_hook = handle_process_exit;

    // 6.2. Point guest AF_UNIX sockets at the app's sandboxed temp directory.
    // MUST run before any guest process starts (see setUpUnixSocketPrefix).
    [self setUpUnixSocketPrefix];

    // 6.5. Install the fork memory guard so guest process bursts can't drive
    // the app's footprint into the Jetsam limit (see minis_fork_memory_guard).
    // [T-ish-forkguard-stall] Compute the device-scaled ceiling and start the
    // pressure source BEFORE installing the guard, so the very first fork sees
    // real values rather than the conservative defaults.
    g_fork_guard_max_footprint = minis_fork_guard_compute_ceiling();
    minis_fork_guard_start_pressure_source();
    ish_set_fork_guard(minis_fork_memory_guard);
    NSLog(@"ISHKernel: [ForkGuard] installed — max footprint %.0fMB "
          @"(device RAM %.0fMB), waits only under system memory pressure, cap %ums",
          (double) g_fork_guard_max_footprint / (1024.0 * 1024.0),
          (double) [NSProcessInfo processInfo].physicalMemory / (1024.0 * 1024.0),
          MINIS_FORK_GUARD_MAX_WAIT_US / 1000);

    // 7. Register TTY driver and set up console device
    tty_drivers[TTY_CONSOLE_MAJOR] = &ish_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    NSLog(@"ISHKernel: TTY driver registered, console device set");

    // 8. Create stdio for init process (stdin/stdout/stderr connected to console)
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (err < 0) {
        NSLog(@"ISHKernel: create_stdio failed: %d (non-fatal)", err);
    } else {
        NSLog(@"ISHKernel: stdio created for init process");
    }

    // 9. [MP T0] 27 个 *_offload_register() 已删（Minis 的 native offload 机制，MP 不要）

    _isBooted = YES;
    NSLog(@"ISHKernel: Kernel initialized successfully");

    return 0;
}

- (void)createDeviceNodes {
    // Create /dev directory structure
    generic_mkdirat(AT_PWD, "/dev", 0755);
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);

    // TTY devices
    generic_mknodat(AT_PWD, "/dev/tty1", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 1));
    generic_mknodat(AT_PWD, "/dev/tty2", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 2));
    generic_mknodat(AT_PWD, "/dev/tty3", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 3));
    generic_mknodat(AT_PWD, "/dev/tty4", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 4));
    generic_mknodat(AT_PWD, "/dev/tty5", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 5));
    generic_mknodat(AT_PWD, "/dev/tty6", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 6));
    generic_mknodat(AT_PWD, "/dev/tty7", S_IFCHR|0666, dev_make(TTY_CONSOLE_MAJOR, 7));
    generic_mknodat(AT_PWD, "/dev/tty", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR));
    generic_mknodat(AT_PWD, "/dev/console", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR));
    generic_mknodat(AT_PWD, "/dev/ptmx", S_IFCHR|0666, dev_make(TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR));

    // Memory devices
    generic_mknodat(AT_PWD, "/dev/null", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_NULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/zero", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_ZERO_MINOR));
    generic_mknodat(AT_PWD, "/dev/full", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_FULL_MINOR));
    generic_mknodat(AT_PWD, "/dev/random", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_RANDOM_MINOR));
    generic_mknodat(AT_PWD, "/dev/urandom", S_IFCHR|0666, dev_make(MEM_MAJOR, DEV_URANDOM_MINOR));

    NSLog(@"ISHKernel: Device nodes created");
}

- (void)refreshDns {
    if (!_dnsHostPath) {
        NSLog(@"ISHKernel: [DNS] Cannot refresh DNS — dnsHostPath not set yet");
        return;
    }
    NSLog(@"ISHKernel: [DNS] Refreshing DNS configuration");
    [self configureDns];
}

/// Build resolv.conf content from iOS system resolver state.
- (void)configureDns {
    // [T-ios-log-noise-reduction] This routine ran on every network change and
    // emitted ~10 NSLog lines each pass (~1.5k lines/day). Collapsed into a
    // single summary line at the end; the failure paths (res_ninit fail,
    // inet_ntop fail) still log individually since those are diagnostic.
    NSMutableString *resolvConf = [NSMutableString new];

    struct __res_state res;
    memset(&res, 0, sizeof(res));

    NSMutableArray<NSString *> *searchDomains = [NSMutableArray new];
    int serverCount = 0;
    int written = 0;
    BOOL initOk = (res_ninit(&res) == 0);

    if (initOk) {
        // Search domains
        for (int i = 0; i < MAXDNSRCH && res.dnsrch[i] != NULL; i++) {
            NSString *domain = [NSString stringWithUTF8String:res.dnsrch[i]];
            if (domain.length > 0) {
                [searchDomains addObject:domain];
            }
        }
        if (searchDomains.count > 0) {
            [resolvConf appendFormat:@"search %@\n", [searchDomains componentsJoinedByString:@" "]];
        }

        // Nameservers
        union res_sockaddr_union servers[NI_MAXSERV];
        serverCount = res_getservers(&res, servers, NI_MAXSERV);

        for (int i = 0; i < serverCount; i++) {
            if (servers[i].sin.sin_len == 0) {
                continue;
            }

            char addrStr[INET6_ADDRSTRLEN];
            const char *result = NULL;
            int family = servers[i].sin.sin_family;

            if (family == AF_INET) {
                result = inet_ntop(AF_INET, &servers[i].sin.sin_addr, addrStr, sizeof(addrStr));
            } else if (family == AF_INET6) {
                result = inet_ntop(AF_INET6, &servers[i].sin6.sin6_addr, addrStr, sizeof(addrStr));
            }

            if (result != NULL) {
                [resolvConf appendFormat:@"nameserver %s\n", addrStr];
                written++;
            } else {
                NSLog(@"ISHKernel: [DNS] server[%d] inet_ntop failed (family=%d, sin_len=%d)",
                      i, family, servers[i].sin.sin_len);
            }
        }

        res_nclose(&res);
    } else {
        NSLog(@"ISHKernel: [DNS] res_ninit failed — skipping system DNS");
    }

    // Fall back to public DNS if no system servers were found.
    BOOL usedFallback = NO;
    if ([resolvConf rangeOfString:@"nameserver"].location == NSNotFound) {
        usedFallback = YES;
        [resolvConf appendString:@"nameserver 8.8.8.8\n"];
        [resolvConf appendString:@"nameserver 8.8.4.4\n"];
    }

    NSLog(@"ISHKernel: [DNS] configured: search=%lu servers=%d/%d fallback=%@",
          (unsigned long)searchDomains.count, written, serverCount, usedFallback ? @"yes" : @"no");
    [self writeResolvConf:resolvConf];
}

/// Write resolv.conf to the host-side file that is bind-mounted into iSH.
/// Because /etc/resolv.conf is a file-level bind mount (symlink to the host
/// file), any write here is instantly visible to iSH processes — no VFS
/// or meta.db interaction needed.
- (void)writeResolvConf:(NSString *)content {
    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;

    BOOL ok = [data writeToFile:_dnsHostPath options:NSDataWritingAtomic error:&error];
    if (!ok) {
        NSLog(@"ISHKernel: [DNS] atomic write failed (%@) — retrying", error);
        error = nil;
        ok = [data writeToFile:_dnsHostPath options:0 error:&error];
    }

    if (ok) {
        NSLog(@"ISHKernel: [DNS] write OK — %lu bytes at %@", (unsigned long)data.length, _dnsHostPath);
    } else {
        NSLog(@"ISHKernel: [DNS] write FAILED — %@", error);
    }
}

/// [T-ios-ish-af-unix-sandbox GH#175] Point guest AF_UNIX sockets at the app's
/// own temp directory instead of the host's `/tmp`.
///
/// iSH does not implement Unix sockets in the guest — it translates each guest
/// address into a REAL host path `<sock_tmp_prefix><pid>.<socket_id>` and binds
/// that (`deps/ish/fs/sock.c:280`). The compiled-in default is `/tmp/ishsock`
/// (`fs/sock.c:229`), i.e. the iOS host `/tmp`, which no sandboxed app may
/// write. Every guest `bind()` therefore failed with EPERM: Terraform/OpenTofu
/// provider handshakes could never start (GH#175), and the minis-mcp-cli daemon
/// had to fall back to loopback TCP.
///
/// Upstream iSH fixed this in 2019 (`7704024a`) inside `app/AppDelegate.m`.
/// Minis does not compile that file — this class is its equivalent, and it
/// mirrors every other init from it (do_mount, DNS, exit_hook, tty_drivers,
/// create_stdio) EXCEPT this one line. So this is a re-alignment with upstream,
/// not a new mechanism, which is also why the fix belongs here rather than in
/// the cross-platform C core: `fs/sock.c` must not depend on Foundation, and
/// patching the fork there would conflict on the next upstream sync.
///
/// Notes for anyone touching this:
///   * `strdup` is load-bearing. `NSTemporaryDirectory()` returns an autoreleased
///     NSString; storing its `.UTF8String` in a global raw pointer would dangle
///     as soon as the pool drains.
///   * `NSTemporaryDirectory()` already ends in `/`, and `ishsock` is a FILENAME
///     PREFIX, not a directory — `sock.c` appends `<pid>.<id>` straight onto it.
///     Hence `stringByAppendingString:`, not `stringByAppendingPathComponent:`.
///   * Simulator is excluded, matching upstream: it is not sandboxed the same
///     way, and its container paths are longer (see the length check below).
///   * Must run BEFORE any guest process starts, since the prefix is read on
///     every bind. It is process-global and written once, so there is no
///     thread-safety or rootfs-reset concern: a reset re-runs boot, which
///     re-runs this, and the value does not depend on rootfs state.
- (void)setUpUnixSocketPrefix {
#if TARGET_OS_SIMULATOR
    // Upstream skips the simulator too — /tmp is writable there, and the
    // simulator's container path is long enough to risk the sun_path limit.
    NSLog(@"ISHKernel: [UnixSock] simulator — keeping default prefix '%s'", sock_tmp_prefix);
#else
    NSString *tempDir = NSTemporaryDirectory();

    // [GH#175] Drop the `/private` prefix if present. This is NOT cosmetic — it
    // is what makes the path fit at all. `NSTemporaryDirectory()` returns the
    // resolved form:
    //   /private/var/mobile/Containers/Data/Application/<uuid>/tmp/ishsock  = 96 bytes
    // and 96 + 12 (worst-case "<pid>.<id>") = 108 > 104, so the very first
    // device run of this fix hit the guard below and refused to install the
    // prefix. `/var` is a symlink to `/private/var`, so the short form names the
    // SAME directory:
    //   /var/mobile/Containers/Data/Application/<uuid>/tmp/ishsock           = 88 bytes
    // 88 + 12 = 100, which fits with 4 bytes to spare.
    if ([tempDir hasPrefix:@"/private/"]) {
        tempDir = [tempDir substringFromIndex:strlen("/private")];
    }

    NSString *prefix = [tempDir stringByAppendingString:@"ishsock"];

    // `struct sockaddr_un.sun_path` is only 104 bytes on Darwin, and
    // `sock.c`'s sprintf into it is UNCHECKED. The margin above is only 4
    // bytes, so if a future OS lengthens the container layout this must fail
    // loudly rather than smash the stack past the end of sun_path.
    const size_t kSunPathMax = sizeof(((struct sockaddr_un *)0)->sun_path);
    const size_t kSuffixWorstCase = 12; // "<pid>.<id>" + NUL
    if (prefix.UTF8String == NULL) {
        NSLog(@"ISHKernel: [UnixSock] ⚠️ temp dir unrepresentable — keeping default prefix");
        return;
    }
    size_t prefixLen = strlen(prefix.UTF8String);
    if (prefixLen + kSuffixWorstCase >= kSunPathMax) {
        NSLog(@"ISHKernel: [UnixSock] ⚠️ prefix too long for sun_path "
              @"(%zu + %zu >= %zu) — keeping default; guest AF_UNIX will fail",
              prefixLen, kSuffixWorstCase, kSunPathMax);
        return;
    }

    sock_tmp_prefix = strdup(prefix.UTF8String);
    NSLog(@"ISHKernel: [UnixSock] prefix → %s (%zu/%zu bytes of sun_path)",
          sock_tmp_prefix, prefixLen, kSunPathMax);
#endif
}

/// Set up /etc/resolv.conf as a file-level bind mount pointing to a host file.
/// Called once during boot, after the root filesystem and init process are ready.
/// The host file lives in Library/Application Support/MemoryPalace/sandbox/dns/resolv.conf and can be freely
/// updated by the app at any time — changes are instantly visible inside iSH.
- (void)mountDnsConfig {
    NSFileManager *fm = [NSFileManager defaultManager];

    // Determine host path: Library/Application Support/MemoryPalace/sandbox/dns/resolv.conf
    NSString *library = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dnsDir = [library stringByAppendingPathComponent:@"Application Support/MemoryPalace/sandbox/dns"];
    _dnsHostPath = [dnsDir stringByAppendingPathComponent:@"resolv.conf"];

    // Ensure directory and seed file exist before bind mount
    if (![fm fileExistsAtPath:dnsDir]) {
        [fm createDirectoryAtPath:dnsDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if (![fm fileExistsAtPath:_dnsHostPath]) {
        // Seed with fallback DNS so the file is never empty
        [@"nameserver 8.8.8.8\nnameserver 8.8.4.4\n"
         writeToFile:_dnsHostPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"ISHKernel: [DNS] seeded host resolv.conf at %@", _dnsHostPath);
    }

    // Bind mount: /etc/resolv.conf -> Library/Application Support/MemoryPalace/sandbox/dns/resolv.conf
    int err = fakefs_bind_mount("/etc/resolv.conf", _dnsHostPath.fileSystemRepresentation, false);
    if (err < 0) {
        NSLog(@"ISHKernel: [DNS] bind mount FAILED (%d) — writing via VFS fallback", err);
        // Fallback: write directly through VFS like original iSH
        struct task *prev = current;
        current = pid_get_task(1);
        if (current) {
            NSString *seed = [NSString stringWithContentsOfFile:_dnsHostPath encoding:NSUTF8StringEncoding error:nil];
            if (seed) {
                struct fd *fd = generic_open("/etc/resolv.conf", O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0666);
                if (!IS_ERR(fd)) {
                    fd->ops->write(fd, seed.UTF8String, [seed lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
                    fd_close(fd);
                    NSLog(@"ISHKernel: [DNS] VFS fallback write OK");
                }
            }
            current = prev;
        } else {
            current = prev;
        }
        // Keep _dnsHostPath set so refreshDns can still update the host file
        // (even though it won't auto-appear in iSH without the bind mount)
        return;
    }
    NSLog(@"ISHKernel: [DNS] bind mount OK: /etc/resolv.conf -> %@", _dnsHostPath);

    // Now populate with actual system DNS
    [self configureDns];
}

- (int)executeCommand:(NSArray<NSString *> *)command {
    if (command.count == 0) {
        NSLog(@"ISHKernel: Empty command");
        return -1;
    }

    if (!_isBooted) {
        NSLog(@"ISHKernel: Kernel not booted");
        return -1;
    }

    // Spawn shell as a child of init process
    // This must be done in a background thread
    NSArray<NSString *> *commandCopy = [command copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Create a new child process of init
        int err = become_new_init_child();
        if (err < 0) {
            NSLog(@"ISHKernel: become_new_init_child failed: %d", err);
            return;
        }

        // Create a pseudo-terminal (PTY) for the shell session.
        // This gives the shell a proper controlling terminal with job control,
        // unlike a console TTY which is shared with init and can't be acquired
        // as a controlling terminal by the child process.
        struct tty *tty = pty_open_fake(&ish_pty_driver);
        if (IS_ERR(tty)) {
            NSLog(@"ISHKernel: pty_open_fake failed: %ld", PTR_ERR(tty));
            return;
        }

        // Store TTY reference for input/resize (thread-safe: only read after this point)
        self->_consoleTTY = tty;
        g_legacy_pty = tty;

        // Set terminal window size
        struct winsize_ winsize = {.row = 24, .col = 200, .xpixel = 0, .ypixel = 0};
        tty_set_winsize(tty, winsize);
        NSLog(@"ISHKernel: PTY created (pts/%d), terminal size %dx%d", tty->num, winsize.col, winsize.row);

        // Connect stdio to the PTY slave device
        NSString *stdioFile = [NSString stringWithFormat:@"/dev/pts/%d", tty->num];
        err = create_stdio(stdioFile.fileSystemRepresentation, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
        if (err < 0) {
            NSLog(@"ISHKernel: create_stdio failed: %d", err);
            return;
        }

        // Build argv (with V8 flags injection for node)
        char argv[16384];
        size_t pos = 0;
        int exec_argc = 0;

        const char *exec_path = commandCopy[0].UTF8String;
        const char *base = strrchr(exec_path, '/');
        base = base ? base + 1 : exec_path;
        bool is_node = (strcmp(base, "node") == 0);

        if (is_node) {
            // Copy argv[0] first
            size_t len = strlen(exec_path) + 1;
            memcpy(argv + pos, exec_path, len);
            pos += len;
            exec_argc++;
            // Inject V8 flags to work around scope corruption in emulation
            static const char *v8_flags[] = {
                "--jitless",
                "--no-lazy",
                "--no-expose-wasm",
                "--max-old-space-size=512",
            };
            for (int fi = 0; fi < (int)(sizeof(v8_flags)/sizeof(v8_flags[0])); fi++) {
                len = strlen(v8_flags[fi]) + 1;
                if (pos + len >= sizeof(argv)) break;
                memcpy(argv + pos, v8_flags[fi], len);
                pos += len;
                exec_argc++;
            }
            // Copy remaining args (skip argv[0])
            for (NSUInteger ai = 1; ai < commandCopy.count; ai++) {
                const char *carg = commandCopy[ai].UTF8String;
                len = strlen(carg) + 1;
                if (pos + len >= sizeof(argv)) break;
                memcpy(argv + pos, carg, len);
                pos += len;
                exec_argc++;
            }
        } else {
            for (NSString *arg in commandCopy) {
                const char *carg = arg.UTF8String;
                size_t len = strlen(carg) + 1;
                if (pos + len >= sizeof(argv)) break;
                memcpy(argv + pos, carg, len);
                pos += len;
                exec_argc++;
            }
        }
        argv[pos] = '\0';

        // Build environment variables
        char envp_buf[8192];
        size_t envp_pos = 0;

#define KERNEL_ENVP_APPEND(s) do { \
    const char *_s = (s); \
    size_t _len = strlen(_s) + 1; \
    if (envp_pos + _len < sizeof(envp_buf) - 256) { \
        memcpy(envp_buf + envp_pos, _s, _len); \
        envp_pos += _len; \
    } \
} while(0)

        KERNEL_ENVP_APPEND("TERM=xterm-256color");
        KERNEL_ENVP_APPEND("HOME=/root");
        KERNEL_ENVP_APPEND("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin");
        KERNEL_ENVP_APPEND("LANG=C.UTF-8");
        KERNEL_ENVP_APPEND("CHARSET=UTF-8");
        KERNEL_ENVP_APPEND("ENV=/etc/profile");
        // Mirrors ISHShellExecutor: route browser-open calls to the in-app
        // preview shim. Needed for interactive terminal sessions too, where
        // Python's webbrowser module picks $BROWSER before $DISPLAY probing.
        KERNEL_ENVP_APPEND("BROWSER=/usr/local/bin/minis-open");

        // Inject device timezone so iSH userspace sees local time.
        // Use POSIX TZ format with a fixed name to avoid abbreviations like "GMT+8"
        // which contain +/- and confuse musl's TZ parser.
        {
            NSTimeZone *tz = [NSTimeZone systemTimeZone];
            NSInteger secs = tz.secondsFromGMT;
            NSInteger hrs  = secs / 3600;
            NSInteger mins = labs(secs % 3600) / 60;
            NSString *posixTZ;
            if (mins != 0) {
                posixTZ = [NSString stringWithFormat:@"LCL%+ld:%02ld",
                           (long)-hrs, (long)mins];
            } else {
                posixTZ = [NSString stringWithFormat:@"LCL%+ld",
                           (long)-hrs];
            }
            NSString *tzEnv = [NSString stringWithFormat:@"TZ=%@", posixTZ];
            KERNEL_ENVP_APPEND(tzEnv.UTF8String);
        }

        // Inject runtime compatibility env vars (matches xX_main_Xx.h / kernel/exec.c)
        KERNEL_ENVP_APPEND("GODEBUG=asyncpreemptoff=1");
        KERNEL_ENVP_APPEND("GOMAXPROCS=2");
        KERNEL_ENVP_APPEND("NO_COLOR=1");
        KERNEL_ENVP_APPEND("PYTHONMALLOC=malloc");
        KERNEL_ENVP_APPEND("PYTHONDONTWRITEBYTECODE=1");

        // Node-specific: LD_PRELOAD for zero_free.so
        if (is_node) {
            KERNEL_ENVP_APPEND("LD_PRELOAD=/lib/zero_free.so");
        }

        // Append custom environment variables
        NSDictionary<NSString *, NSString *> *customEnv = self->_customEnvironment;
        if (customEnv) {
            for (NSString *key in customEnv) {
                NSString *entry = [NSString stringWithFormat:@"%@=%@", key, customEnv[key]];
                KERNEL_ENVP_APPEND(entry.UTF8String);
            }
        }
        envp_buf[envp_pos] = '\0'; // double-NUL terminate

#undef KERNEL_ENVP_APPEND

        const char *envp = envp_buf;

        // Execute command
        err = do_execve(exec_path, exec_argc, argv, envp);
        if (err < 0) {
            NSLog(@"ISHKernel: do_execve failed: %d", err);
            return;
        }

        NSLog(@"ISHKernel: Starting shell process (PID %d)", current->pid);

        // Start task - this runs the emulator loop and doesn't return
        task_start(current);
    });

    NSLog(@"ISHKernel: Shell launch initiated: %@", command[0]);
    return 0;
}

- (void)sendInput:(NSData *)data {
    if (_consoleTTY && data.length > 0) {
        tty_input(_consoleTTY, data.bytes, data.length, false);
    }
}


- (void)sendInputString:(NSString *)input {
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    [self sendInput:data];
}

- (void)setTerminalSize:(int)columns rows:(int)rows {
    if (_consoleTTY) {
        struct winsize_ winsize;
        winsize.row = rows;
        winsize.col = columns;
        winsize.xpixel = 0;
        winsize.ypixel = 0;
        tty_set_winsize(_consoleTTY, winsize);
        NSLog(@"ISHKernel: Terminal size updated to %dx%d", columns, rows);
    } else {
        NSLog(@"ISHKernel: Warning - cannot set terminal size, TTY not initialized");
    }
}

- (int)bindMountPath:(NSString *)linuxPath toHostPath:(NSString *)hostPath {
    return [self bindMountPath:linuxPath toHostPath:hostPath readOnly:NO];
}

- (int)bindMountPath:(NSString *)linuxPath toHostPath:(NSString *)hostPath readOnly:(BOOL)readOnly {
    if (!_isBooted) {
        NSLog(@"ISHKernel: bindMount failed — kernel not booted");
        return -1;
    }
    int err = fakefs_bind_mount(linuxPath.fileSystemRepresentation,
                                hostPath.fileSystemRepresentation,
                                readOnly ? true : false);
    if (err < 0) {
        NSLog(@"ISHKernel: bindMount %@ -> %@ (ro=%d) failed: %d",
              linuxPath, hostPath, readOnly, err);
    }
    return err;
}

- (int)bindUnmountPath:(NSString *)linuxPath {
    if (!_isBooted) {
        return -1;
    }
    return fakefs_bind_unmount(linuxPath.fileSystemRepresentation);
}

#pragma mark - Command Execution with Completion

- (void)executeCommandAndWait:(NSString *)commandString
                      timeout:(NSTimeInterval)timeout
                   completion:(ISHCommandCompletionCallback)completion {
    if (!_isBooted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *error = [NSError errorWithDomain:@"ISHKernel"
                                                 code:-1
                                             userInfo:@{NSLocalizedDescriptionKey: @"Kernel not booted"}];
            completion(nil, error);
        });
        return;
    }

    if (_commandCompletionCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *error = [NSError errorWithDomain:@"ISHKernel"
                                                 code:-2
                                             userInfo:@{NSLocalizedDescriptionKey: @"Another command is already executing"}];
            completion(nil, error);
        });
        return;
    }

    dispatch_async(_commandQueue, ^{
        // Clear buffer and set callback
        [self->_commandOutputBuffer setString:@""];
        self->_commandCompletionCallback = completion;

        // Set timeout if specified
        if (timeout > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_commandTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:timeout
                                                                              repeats:NO
                                                                                block:^(NSTimer *timer) {
                    [self completeCommandWithOutput:nil
                                              error:[NSError errorWithDomain:@"ISHKernel"
                                                                        code:-3
                                                                    userInfo:@{NSLocalizedDescriptionKey: @"Command timed out"}]];
                }];
            });
        }

        // Send command with newline
        NSString *commandWithNewline = [commandString stringByAppendingString:@"\n"];
        [self sendInputString:commandWithNewline];

        NSLog(@"ISHKernel: Executing command and waiting: %@", commandString);
    });
}

- (void)handleCommandOutputInternal:(NSString *)output {
    if (!_commandCompletionCallback) {
        return;
    }

    // Append to buffer
    [_commandOutputBuffer appendString:output];

    // Check if we've received a shell prompt (indicating command completion)
    // Common prompt patterns: "$ ", "# ", "root@minis:", etc.
    NSString *buffer = _commandOutputBuffer;

    // Look for prompt patterns at the end of the buffer
    // We look for patterns like:
    // - "$ " or "# " at the end
    // - "username@hostname:path$ " or similar
    // - Any line ending with "$ " or "# "
    NSArray<NSString *> *promptPatterns = @[
        @"\\$\\s*$",           // $ at end with optional whitespace
        @"#\\s*$",             // # at end with optional whitespace
        @"[a-zA-Z0-9_-]+@[a-zA-Z0-9_-]+:[^$#]*[$#]\\s*$",  // user@host:path$ or #
        @"\\[.*\\][$#]\\s*$"   // [some context]$ or #
    ];

    for (NSString *pattern in promptPatterns) {
        NSError *error = nil;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                               options:NSRegularExpressionAnchorsMatchLines
                                                                                 error:&error];
        if (regex) {
            NSRange range = NSMakeRange(0, buffer.length);
            NSTextCheckingResult *match = [regex firstMatchInString:buffer options:0 range:range];

            if (match) {
                // Found a prompt - command is complete
                NSLog(@"ISHKernel: Detected command completion (prompt pattern: %@)", pattern);

                // Extract the output (everything before the prompt)
                NSString *commandOutput = buffer;
                if (match.range.location > 0) {
                    commandOutput = [buffer substringToIndex:match.range.location];
                }

                // Clean up the output:
                // 1. Remove the echoed command line (first line)
                // 2. Remove trailing whitespace
                NSArray<NSString *> *lines = [commandOutput componentsSeparatedByString:@"\n"];
                if (lines.count > 1) {
                    // Skip first line (echoed command) and last empty lines
                    NSMutableArray<NSString *> *outputLines = [NSMutableArray array];
                    for (NSInteger i = 1; i < lines.count; i++) {
                        NSString *line = lines[i];
                        if (line.length > 0 || i < lines.count - 1) {
                            [outputLines addObject:line];
                        }
                    }
                    commandOutput = [outputLines componentsJoinedByString:@"\n"];
                }
                commandOutput = [commandOutput stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

                [self completeCommandWithOutput:commandOutput error:nil];
                return;
            }
        }
    }

    // If buffer is getting too large without a prompt, something might be wrong
    if (buffer.length > 100000) {
        NSLog(@"ISHKernel: Warning - command output buffer exceeded 100KB without prompt detection");
        [self completeCommandWithOutput:buffer
                                  error:[NSError errorWithDomain:@"ISHKernel"
                                                            code:-4
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Output too large without prompt"}]];
    }
}

- (void)completeCommandWithOutput:(NSString *)output error:(NSError *)error {
    if (!_commandCompletionCallback) {
        return;
    }

    ISHCommandCompletionCallback callback = _commandCompletionCallback;
    _commandCompletionCallback = nil;

    // Cancel timeout timer
    if (_commandTimeoutTimer) {
        [_commandTimeoutTimer invalidate];
        _commandTimeoutTimer = nil;
    }

    // Call completion on main queue
    dispatch_async(dispatch_get_main_queue(), ^{
        callback(output, error);
    });

    NSLog(@"ISHKernel: Command completed with %@ (output: %ld chars)",
          error ? @"error" : @"success",
          (long)output.length);
}

@end

#pragma mark - Fakefs change tracker bridge

@implementation ISHFakefsChangeEvent {
    NSString *_linuxPath;
    int _op;
    int64_t _timestampNs;
    uint64_t _fsContext;
}
- (instancetype)initWithLinuxPath:(NSString *)linuxPath
                               op:(int)op
                      timestampNs:(int64_t)ts
                        fsContext:(uint64_t)ctx {
    if ((self = [super init])) {
        _linuxPath = [linuxPath copy];
        _op = op;
        _timestampNs = ts;
        _fsContext = ctx;
    }
    return self;
}
- (NSString *)linuxPath { return _linuxPath; }
- (int)op { return _op; }
- (int64_t)timestampNs { return _timestampNs; }
- (uint64_t)fsContext { return _fsContext; }
@end

@implementation ISHKernel (FakefsChange)

- (void)installFakefsChangeHandler:(void (^)(NSArray<ISHFakefsChangeEvent *> *))handler {
    if (handler == nil) {
        // Detach by installing a no-op handler — fakefs C layer treats nil
        // as "ignore call", so we install an empty block to clear behavior.
        fakefs_install_change_consumer(^(const struct fakefs_change_event *batch, int count) {
            (void)batch; (void)count;
        });
        return;
    }
    void (^handlerCopy)(NSArray<ISHFakefsChangeEvent *> *) = [handler copy];
    fakefs_install_change_consumer(^(const struct fakefs_change_event *batch, int count) {
        if (count <= 0) return;
        NSMutableArray<ISHFakefsChangeEvent *> *events = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
        for (int i = 0; i < count; i++) {
            NSString *path = [NSString stringWithUTF8String:batch[i].linux_path];
            if (path == nil) continue;
            ISHFakefsChangeEvent *evt = [[ISHFakefsChangeEvent alloc]
                initWithLinuxPath:path
                               op:batch[i].op
                      timestampNs:batch[i].timestamp_ns
                        fsContext:batch[i].fs_context];
            [events addObject:evt];
        }
        handlerCopy(events);
    });
}

- (uint64_t)fakefsChangeDroppedCount {
    return fakefs_change_dropped_count();
}

@end

#pragma mark - Path translate hook bridge

/* Block storage for the registered ISHPathTranslateHandler. Atomically swapped
 * on install; the C trampoline below reads it on every hot-path translation. */
static _Atomic(void *) g_path_translate_block = NULL;

static bool ish_path_translate_trampoline(const char *guest_path,
                                          uint64_t fs_context,
                                          char *out_host_path,
                                          size_t out_size) {
    void *raw = atomic_load_explicit(&g_path_translate_block, memory_order_acquire);
    if (raw == NULL || guest_path == NULL || out_host_path == NULL || out_size == 0)
        return false;
    /* No retain/release dance: installPathTranslateHandler: never releases
     * a previously-installed block (see comment there), so this pointer
     * is guaranteed to outlive the trampoline call. */
    ISHPathTranslateHandler handler = (__bridge ISHPathTranslateHandler)raw;
    bool ok = false;
    @autoreleasepool {
        NSString *guest = [NSString stringWithUTF8String:guest_path];
        if (guest != nil) {
            NSString *host = handler(guest, fs_context);
            if (host != nil) {
                const char *cstr = host.fileSystemRepresentation;
                if (cstr != NULL) {
                    size_t len = strlen(cstr);
                    if (len + 1 <= out_size) {
                        memcpy(out_host_path, cstr, len + 1);
                        ok = true;
                    }
                }
            }
        }
    }
    return ok;
}

#pragma mark - Reverse path translate bridge

static _Atomic(void *) g_path_reverse_block = NULL;

static bool ish_path_reverse_trampoline(const char *host_path,
                                        char *out_guest_path,
                                        size_t out_size) {
    void *raw = atomic_load_explicit(&g_path_reverse_block, memory_order_acquire);
    if (raw == NULL || host_path == NULL || out_guest_path == NULL || out_size == 0)
        return false;
    ISHPathReverseHandler handler = (__bridge ISHPathReverseHandler)raw;
    bool ok = false;
    @autoreleasepool {
        NSString *host = [NSString stringWithUTF8String:host_path];
        if (host != nil) {
            NSString *guest = handler(host);
            if (guest != nil) {
                const char *cstr = [guest cStringUsingEncoding:NSUTF8StringEncoding];
                if (cstr != NULL) {
                    size_t len = strlen(cstr);
                    if (len + 1 <= out_size) {
                        memcpy(out_guest_path, cstr, len + 1);
                        ok = true;
                    }
                }
            }
        }
    }
    return ok;
}

#pragma mark - CPU Throttle (C-only hot path, no ObjC messaging)

// sleep_ratio = (1 - dutyCycle) / dutyCycle.  0 = disabled (foreground).
// Stored as fixed-point Q16: ratio_q16 = (int)(sleep_ratio * 65536).
static _Atomic int g_throttle_ratio_q16 = 0;
static _Atomic uint64_t g_throttle_tick_total = 0;
static _Atomic uint64_t g_throttle_sleep_total = 0;
static _Atomic uint64_t g_throttle_sleep_ns_total = 0;
static _Atomic uint64_t g_throttle_elapsed_ns_total = 0;
static _Atomic uint64_t g_throttle_last_log_ts = 0;

#define THROTTLE_LOG_INTERVAL_NS (60ULL * 1000000000ULL)
#define THROTTLE_DEBT_CLAMP_NS   (2000ULL * 1000000ULL) // was 100ms: debts above the old clamp were silently forgiven; 2s allows real braking at poke cadence
// [T-ish-throttle-deepred] Deep-brake clamp: with duty ≤5% the 2s clamp is
// not enough when the poke timer itself degrades. RED braking assumes a
// 100ms work quantum between pokes; if the governor's utility-QoS timer is
// delayed (thermal pressure, scheduler starvation) the quantum grows and
// per-thread duty rises with it — 500ms quanta against 2s sleeps is 20%
// duty, and N hot threads multiply that into kill territory. A 10s clamp
// keeps even a degraded 500ms quantum at ~4.8% duty. Foreground-return and
// signal latency stay bounded by the 100ms slice checks below.
#define THROTTLE_DEEP_CLAMP_NS   (10000ULL * 1000000ULL)
#define THROTTLE_DEEP_RATIO_Q16  ((int)((0.95 / 0.05) * 65536))  // duty ≤ 5%
#define THROTTLE_EAGER_DEBT_NS   (20ULL * 1000000ULL)   // pay every tick once debt passes this (bursts must not run 10 ticks ahead)

static int ish_throttle_trampoline(void) {
    int ratio = atomic_load_explicit(&g_throttle_ratio_q16, memory_order_relaxed);
    if (ratio <= 0) return 0;

    atomic_fetch_add_explicit(&g_throttle_tick_total, 1, memory_order_relaxed);

    static __thread uint64_t last_ts = 0;
    static __thread uint64_t owed_ns = 0;
    static __thread unsigned tick_count = 0;
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

    if (last_ts == 0) {
        // [T-ish-throttle-coldstart] First tick of a NEW thread while
        // throttling is active. Previously this tick only set the baseline,
        // so a thread forked in the RED zone got a full-speed head start
        // until its second tick — and a fan-out of fresh workers could
        // overshoot the window faster than the governor's next sample could
        // react. Seed a starting debt instead: the recent global average
        // sleep quantum (what peer threads currently pay per cycle), or —
        // with no history yet — one 10ms timer quantum's worth of debt at
        // the current ratio. Deliberately coarse: this closes the loophole,
        // it does not model the thread's actual usage.
        last_ts = now;
        uint64_t sleeps = atomic_load_explicit(&g_throttle_sleep_total, memory_order_relaxed);
        uint64_t slept  = atomic_load_explicit(&g_throttle_sleep_ns_total, memory_order_relaxed);
        uint64_t seed = sleeps > 0 ? slept / sleeps
                                   : ((10000000ULL * (uint64_t)ratio) >> 16);
        if (seed > THROTTLE_DEBT_CLAMP_NS) seed = THROTTLE_DEBT_CLAMP_NS;
        owed_ns = seed;
        tick_count = 0;
    } else {
        uint64_t elapsed = now - last_ts;
        last_ts = now;

        // A long gap means the thread was blocked/descheduled, not burning
        // CPU — it owes nothing for time it did not run.
        if (elapsed > 500000000ULL) { tick_count = 0; owed_ns = 0; return 0; }

        atomic_fetch_add_explicit(&g_throttle_elapsed_ns_total, elapsed, memory_order_relaxed);

        // Accumulate sleep debt: owed += elapsed * ratio / 65536
        owed_ns += (elapsed * (uint64_t)ratio) >> 16;
    }

    // Pay every 10 ticks normally, or immediately once the debt passes the
    // eager threshold.
    if (owed_ns < THROTTLE_EAGER_DEBT_NS && ++tick_count < 10) return 0;
    tick_count = 0;
    if (owed_ns == 0) return 0;

    uint64_t clamp = ratio >= THROTTLE_DEEP_RATIO_Q16 ? THROTTLE_DEEP_CLAMP_NS
                                                      : THROTTLE_DEBT_CLAMP_NS;
    if (owed_ns > clamp) owed_ns = clamp;

    atomic_fetch_add_explicit(&g_throttle_sleep_total, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&g_throttle_sleep_ns_total, owed_ns, memory_order_relaxed);

    // Periodic log every 10s (only one thread wins the CAS)
    uint64_t last_log = atomic_load_explicit(&g_throttle_last_log_ts, memory_order_relaxed);
    if (now - last_log >= THROTTLE_LOG_INTERVAL_NS) {
        if (atomic_compare_exchange_weak_explicit(&g_throttle_last_log_ts, &last_log, now,
                                                   memory_order_relaxed, memory_order_relaxed)) {
            uint64_t ticks = atomic_load_explicit(&g_throttle_tick_total, memory_order_relaxed);
            uint64_t sleeps = atomic_load_explicit(&g_throttle_sleep_total, memory_order_relaxed);
            uint64_t slept_ns = atomic_load_explicit(&g_throttle_sleep_ns_total, memory_order_relaxed);
            uint64_t worked_ns = atomic_load_explicit(&g_throttle_elapsed_ns_total, memory_order_relaxed);
            uint64_t avg_tick_us = ticks > 0 ? (worked_ns / ticks / 1000) : 0;
            uint64_t avg_sleep_us = sleeps > 0 ? (slept_ns / sleeps / 1000) : 0;
            double actual_duty = (worked_ns + slept_ns) > 0
                ? (double)worked_ns / (double)(worked_ns + slept_ns) * 100.0
                : 0.0;
            NSLog(@"ISHKernel: [Throttle] ticks=%llu sleeps=%llu avgTick=%lluµs avgSleep=%lluµs duty=%.0f%%",
                  ticks, sleeps, avg_tick_us, avg_sleep_us, actual_duty);
        }
    }

    // Pay in 100ms slices, re-checking BETWEEN slices so neither of these is
    // ever blocked longer than one slice:
    //  - foreground return (ratio → 0),
    //  - signal delivery: receive_signals() runs only after this hook
    //    returns, so a pending SIGKILL/SIGTERM would otherwise wait out the
    //    full clamped sleep (up to 10s in deep RED) — that would visibly
    //    slow guest process kills and killProcessGroup's TERM→wait→KILL
    //    escalation. current->pending is read unlocked as a hint; a racy
    //    read only means one extra slice of latency.
    uint64_t remaining = owed_ns;
    while (remaining > 0) {
        if (atomic_load_explicit(&g_throttle_ratio_q16, memory_order_relaxed) <= 0)
            break;
        if (current != NULL && current->pending != 0)
            break;
        uint64_t slice = remaining > 100000000ULL ? 100000000ULL : remaining;
        struct timespec ts = { .tv_sec = 0, .tv_nsec = (long)slice };
        nanosleep(&ts, NULL);
        remaining -= slice;
    }
    owed_ns = 0;
    // [T-ish-throttle-sleepbias] Re-stamp AFTER sleeping so the sleep is not
    // billed as "work" on the next tick. The old code stamped before the
    // sleep, inflating elapsed by the sleep itself and compounding debt on
    // wall-clock instead of CPU-time — one reason measured duty drifted from
    // the target.
    last_ts = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    return 0;
}

@implementation ISHKernel (Scheduler)

- (void)enableCPUThrottleWithDutyCycle:(float)dutyCycle {
    if (dutyCycle <= 0.0f) dutyCycle = 0.01f;
    if (dutyCycle >= 1.0f) { [self disableCPUThrottle]; return; }
    float ratio = (1.0f - dutyCycle) / dutyCycle;
    int ratio_q16 = (int)(ratio * 65536.0f);
    if (ratio_q16 <= 0) ratio_q16 = 1;
    atomic_store_explicit(&g_throttle_tick_total, 0, memory_order_relaxed);
    atomic_store_explicit(&g_throttle_sleep_total, 0, memory_order_relaxed);
    atomic_store_explicit(&g_throttle_sleep_ns_total, 0, memory_order_relaxed);
    atomic_store_explicit(&g_throttle_elapsed_ns_total, 0, memory_order_relaxed);
    atomic_store_explicit(&g_throttle_last_log_ts, 0, memory_order_relaxed);
    atomic_store_explicit(&g_throttle_ratio_q16, ratio_q16, memory_order_release);
    ish_set_timer_tick_hook(ish_throttle_trampoline);
    NSLog(@"ISHKernel: [Throttle] ENABLED dutyCycle=%.0f%% ratio_q16=%d", dutyCycle * 100, ratio_q16);
}

- (void)disableCPUThrottle {
    uint64_t ticks = atomic_load_explicit(&g_throttle_tick_total, memory_order_relaxed);
    uint64_t sleeps = atomic_load_explicit(&g_throttle_sleep_total, memory_order_relaxed);
    uint64_t sleep_ns = atomic_load_explicit(&g_throttle_sleep_ns_total, memory_order_relaxed);
    atomic_store_explicit(&g_throttle_ratio_q16, 0, memory_order_release);
    uint64_t avg_us = sleeps > 0 ? (sleep_ns / sleeps / 1000) : 0;
    NSLog(@"ISHKernel: [Throttle] DISABLED — ticks=%llu sleeps=%llu avgSleep=%lluµs totalSleep=%.1fs",
          ticks, sleeps, avg_us, (double)sleep_ns / 1e9);
}

#pragma mark - Background CPU Governor (closed-loop sliding window)

// [T-ish-bg-cpu-governor] Closed-loop governor per
// docs/ish-bg-cpu-governor-design.md. iOS 26 background budget (empirical,
// IPS 2026-08-02): 48 CPU-s per 60s sliding window, enforced by kill.
// Sense what iOS bills (process-wide CPU via proc_pid_rusage), drive the
// Q16 throttle ratio as feedback so actuator inaccuracy cannot break safety.

// 10 Hz cadence: the sensor is cheap, and the same tick doubles as the
// BRAKE DRIVER — chained guest blocks never return to the dispatch loop's
// cycle-based INT_TIMER raiser (verified on device: a busy shell loop ran
// at 99% straight through RED with the hook never firing), so the governor
// must cpu_poke() running guests to force the tick hook to run. Poke
// cadence bounds the work quantum between sleeps: 100ms work + up to 2s
// clamped debt ≈ 5% duty floor in RED.
#define GOV_CADENCE_NS      (100ULL * 1000000ULL)   // 10 Hz sample + poke
#define GOV_SLOTS           601                     // 60s of samples + newest
#define GOV_RATE_LOOKBACK   10                      // R over last 10 samples (1s)
#define GOV_SOFT_CPU_S      30.0                    // GREEN below (predicted W)
#define GOV_HARD_CPU_S      38.0                    // RED at/above (predicted W)
#define GOV_RED_EXIT_CPU_S  32.0                    // leave RED below (actual W)
#define GOV_YELLOW_MIN_DUTY 0.15                    // YELLOW floor
#define GOV_RED_DUTY        0.03                    // RED hard brake
#define GOV_PREDICT_S       1.0                     // rate-prediction horizon
#define GOV_STARTUP_CAP_NS  (2ULL * 1000000000ULL)  // first 2s: duty capped at 0.5
#define GOV_LOG_INTERVAL_NS (5ULL * 1000000000ULL)  // periodic [Governor] status line

static dispatch_queue_t  g_gov_queue;
static dispatch_source_t g_gov_timer;
static uint64_t g_gov_cpu_ns[GOV_SLOTS];   // cumulative process CPU (ns), ring
static uint64_t g_gov_wall_ns[GOV_SLOTS];  // wall stamp per sample (see gov_tick)
static int      g_gov_head;                // next write slot
static int      g_gov_count;               // valid samples
static int      g_gov_zone;                // 0 GREEN / 1 YELLOW / 2 RED
static uint64_t g_gov_begin_ts;
static uint64_t g_gov_last_log_ts;

// Total process CPU time in ns via public mach APIs (libproc.h is not in
// the iOS SDK): MACH_TASK_BASIC_INFO carries user/system time of TERMINATED
// threads, TASK_THREAD_TIMES_INFO of LIVE threads — the sum is what iOS
// bills the process for. µs resolution is plenty at a 250ms cadence.
static uint64_t gov_process_cpu_ns(void) {
    mach_task_basic_info_data_t basic;
    mach_msg_type_number_t bcount = MACH_TASK_BASIC_INFO_COUNT;
    task_thread_times_info_data_t times;
    mach_msg_type_number_t tcount = TASK_THREAD_TIMES_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&basic, &bcount) != KERN_SUCCESS)
        return 0;
    if (task_info(mach_task_self(), TASK_THREAD_TIMES_INFO,
                  (task_info_t)&times, &tcount) != KERN_SUCCESS)
        return 0;
    uint64_t us = (uint64_t)basic.user_time.seconds   * 1000000ULL + basic.user_time.microseconds
                + (uint64_t)basic.system_time.seconds * 1000000ULL + basic.system_time.microseconds
                + (uint64_t)times.user_time.seconds   * 1000000ULL + times.user_time.microseconds
                + (uint64_t)times.system_time.seconds * 1000000ULL + times.system_time.microseconds;
    return us * 1000ULL;
}

static const char *gov_zone_name(int zone) {
    return zone == 2 ? "RED" : (zone == 1 ? "YELLOW" : "GREEN");
}

// [T-ish-throttle-poke] Force every running guest CPU out of chained block
// execution so the INT_TIMER tick hook actually runs. cpu_poke only sets an
// atomic flag (the same channel signal delivery uses), so this is safe under
// pids_lock and O(MAX_PID) over a flat array — ~µs per sweep.
static void gov_poke_all_tasks(void) {
    lock(&pids_lock);
    for (int i = 1; i < MAX_PID; i++) {
        struct pid *pid = pid_get(i);
        if (pid == NULL || pid->task == NULL) continue;
        cpu_poke(&pid->task->cpu);
    }
    unlock(&pids_lock);
}

// One controller step. Runs on g_gov_queue only.
static void gov_tick(void) {
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    uint64_t cpu = gov_process_cpu_ns();
    // Sensor failure (rusage returned 0): skip the sample entirely — pushing
    // a 0 would make the unsigned W subtraction underflow into permanent RED.
    if (cpu == 0) return;

    g_gov_cpu_ns[g_gov_head] = cpu;
    g_gov_wall_ns[g_gov_head] = now;
    int newest = g_gov_head;
    g_gov_head = (g_gov_head + 1) % GOV_SLOTS;
    if (g_gov_count < GOV_SLOTS) g_gov_count++;

    // W: CPU-s consumed across the window (up to 60s; shorter right after
    // begin, which matches the OS opening a fresh budget at backgrounding).
    //
    // [T-gov-wall-window] Walk back by WALL TIME, not sample count: dispatch
    // timers stall under suspension/pressure, so "600 samples ago" can be
    // wall-hours old. Counting samples would compress pre-suspension burn
    // into a fake 60s window and hold the throttle in RED for up to a
    // minute after resume, even though RunningBoard's real window drained
    // to ~zero during the suspension. Stop at the newest sample that is
    // ≥60s old (or the oldest available).
    int span = g_gov_count - 1;
    if (span < 1) return;  // need two samples
    int oldest = newest;
    for (int back = 1; back <= span; back++) {
        int idx = (newest - back + GOV_SLOTS) % GOV_SLOTS;
        oldest = idx;
        if (now - g_gov_wall_ns[idx] >= 60ULL * 1000000000ULL)
            break;
    }
    // Underflow-safe deltas: thread exit migrates time between the two
    // task_info counters with µs rounding, so the sum can dip momentarily.
    uint64_t base = g_gov_cpu_ns[oldest];
    double W = cpu > base ? (double)(cpu - base) / 1e9 : 0.0;

    // R: burn rate over the last ~1s (CPU-s per wall-s; >1 means multi-core),
    // over the ACTUAL wall span of the lookback samples (same stall logic).
    int rb = span < GOV_RATE_LOOKBACK ? span : GOV_RATE_LOOKBACK;
    int ridx = (newest - rb + GOV_SLOTS) % GOV_SLOTS;
    uint64_t rbase = g_gov_cpu_ns[ridx];
    uint64_t rwall = now - g_gov_wall_ns[ridx];
    double R = (cpu > rbase && rwall > 0)
        ? (double)(cpu - rbase) / (double)rwall : 0.0;
    double Wpred = W + R * GOV_PREDICT_S;

    // Zone selection with hysteresis: RED is entered on prediction, exited
    // only when ACTUAL W has drained below GOV_RED_EXIT_CPU_S. YELLOW→GREEN
    // needs 1 CPU-s of slack below the soft line — without it, Wpred
    // hovering at the boundary flaps zones at 10 Hz and every flap emits a
    // transition log line.
    int zone = g_gov_zone;
    if (zone == 2) {
        if (W < GOV_RED_EXIT_CPU_S)
            zone = (Wpred >= GOV_SOFT_CPU_S) ? 1 : 0;
    } else {
        if (Wpred >= GOV_HARD_CPU_S)      zone = 2;
        else if (Wpred >= GOV_SOFT_CPU_S) zone = 1;
        else if (zone == 1 && Wpred >= GOV_SOFT_CPU_S - 1.0) zone = 1;
        else                              zone = 0;
    }

    double duty;
    switch (zone) {
        case 2:  duty = GOV_RED_DUTY; break;
        case 1:  duty = 1.0 - ((Wpred - GOV_SOFT_CPU_S) / (GOV_HARD_CPU_S - GOV_SOFT_CPU_S))
                             * (1.0 - GOV_YELLOW_MIN_DUTY);
                 if (duty < GOV_YELLOW_MIN_DUTY) duty = GOV_YELLOW_MIN_DUTY;
                 break;
        default: duty = 1.0; break;
    }

    // Transition guard: for the first 2s after backgrounding cap duty at 0.5
    // in case some iOS version opens the budget window earlier than the
    // transition we observe.
    if (now - g_gov_begin_ts < GOV_STARTUP_CAP_NS && duty > 0.5) duty = 0.5;

    int ratio_q16 = 0;
    if (duty < 1.0) {
        float ratio = (float)((1.0 - duty) / duty);
        ratio_q16 = (int)(ratio * 65536.0f);
        if (ratio_q16 <= 0) ratio_q16 = 1;
    }
    atomic_store_explicit(&g_throttle_ratio_q16, ratio_q16, memory_order_release);

    // While braking, poke all running guests every tick — without this the
    // ratio is write-only for CPU-bound (chained) guest code.
    if (ratio_q16 > 0)
        gov_poke_all_tasks();

    double t = (double)(now - g_gov_begin_ts) / 1e9;
    if (zone != g_gov_zone) {
        NSLog(@"ISHKernel: [Governor] zone %s→%s t=+%.1fs W=%.1fs R=%.2f pred=%.1fs duty=%.0f%%",
              gov_zone_name(g_gov_zone), gov_zone_name(zone), t, W, R, Wpred, duty * 100);
        g_gov_zone = zone;
        g_gov_last_log_ts = now;
    } else if (now - g_gov_last_log_ts >= GOV_LOG_INTERVAL_NS) {
        NSLog(@"ISHKernel: [Governor] t=+%.1fs W=%.1fs R=%.2f pred=%.1fs zone=%s duty=%.0f%%",
              t, W, R, Wpred, gov_zone_name(zone), duty * 100);
        g_gov_last_log_ts = now;
    }
}

- (void)beginBackgroundCPUGovernor {
    if (g_gov_timer) return;  // idempotent
    if (!g_gov_queue)
        g_gov_queue = dispatch_queue_create("com.openminis.ish.cpugovernor",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));

    g_gov_head = 0;
    g_gov_count = 0;
    g_gov_zone = 0;
    g_gov_begin_ts = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    g_gov_last_log_ts = g_gov_begin_ts;

    // Fresh throttle stats so the cold-start seed reflects THIS background
    // stint, and install the hook (ratio stays 0 until the first gov_tick
    // decides — GREEN start means full speed, per design).
    atomic_store_explicit(&g_throttle_tick_total, 0, memory_order_relaxed);
    atomic_store_explicit(&g_throttle_sleep_total, 0, memory_order_relaxed);
    atomic_store_explicit(&g_throttle_sleep_ns_total, 0, memory_order_relaxed);
    atomic_store_explicit(&g_throttle_elapsed_ns_total, 0, memory_order_relaxed);
    atomic_store_explicit(&g_throttle_last_log_ts, 0, memory_order_relaxed);
    ish_set_timer_tick_hook(ish_throttle_trampoline);

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_gov_queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              GOV_CADENCE_NS, 50ULL * 1000000ULL /* 50ms leeway */);
    dispatch_source_set_event_handler(timer, ^{ gov_tick(); });
    // Serialize the final ratio reset onto the governor queue so a
    // concurrent in-flight gov_tick cannot re-arm the throttle after end.
    dispatch_source_set_cancel_handler(timer, ^{
        atomic_store_explicit(&g_throttle_ratio_q16, 0, memory_order_release);
    });
    g_gov_timer = timer;
    dispatch_resume(timer);
    NSLog(@"ISHKernel: [Governor] BEGIN budget=48s/60s ceiling=%.0fs soft=%.0fs redExit=%.0fs cadence=%llums",
          GOV_HARD_CPU_S, GOV_SOFT_CPU_S, GOV_RED_EXIT_CPU_S, GOV_CADENCE_NS / 1000000ULL);
}

- (void)endBackgroundCPUGovernor {
    if (!g_gov_timer) return;
    uint64_t sleeps = atomic_load_explicit(&g_throttle_sleep_total, memory_order_relaxed);
    uint64_t sleep_ns = atomic_load_explicit(&g_throttle_sleep_ns_total, memory_order_relaxed);
    double t = (double)(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - g_gov_begin_ts) / 1e9;
    dispatch_source_cancel(g_gov_timer);
    g_gov_timer = nil;
    NSLog(@"ISHKernel: [Governor] END after %.1fs — lastZone=%s sleeps=%llu totalSleep=%.1fs",
          t, gov_zone_name(g_gov_zone), sleeps, (double)sleep_ns / 1e9);
}

@end

@implementation ISHKernel (PathReverse)

- (void)installPathReverseHandler:(ISHPathReverseHandler)handler {
    if (handler == nil) {
        fakefs_set_path_reverse_hook(NULL);
        atomic_store_explicit(&g_path_reverse_block, NULL, memory_order_release);
        return;
    }
    ISHPathReverseHandler copied = [handler copy];
    void *raw = (void *)CFBridgingRetain(copied);  /* retained forever */
    atomic_store_explicit(&g_path_reverse_block, raw, memory_order_release);
    fakefs_set_path_reverse_hook(ish_path_reverse_trampoline);
}

@end

@implementation ISHKernel (PathTranslate)

- (void)installPathTranslateHandler:(ISHPathTranslateHandler)handler {
    /* Lifetime model: every installed block is retained forever. The
     * trampoline runs on iSH worker threads with no available lock or
     * RCU-like primitive — releasing a replaced block while another
     * thread is mid-call is racy. In practice installPathTranslateHandler:
     * is expected to be called at most a handful of times (typically once
     * at boot), so the leak is bounded and trivial. The C-level hook
     * function pointer can still be cleared (handler == nil) to disable
     * dispatch without touching block memory.
     *
     * Sequence:
     *   - detach (handler == nil): clear hook fn ptr FIRST so no new
     *     trampoline call dispatches, then swap block pointer to NULL.
     *     The previously-installed block stays retained (leaked).
     *   - attach: store new block pointer FIRST, then install the
     *     trampoline. A concurrent trampoline that loaded NULL before
     *     the swap simply returns false and falls through. */
    if (handler == nil) {
        fakefs_set_path_translate_hook(NULL);
        atomic_store_explicit(&g_path_translate_block, NULL, memory_order_release);
        return;
    }
    ISHPathTranslateHandler copied = [handler copy];
    void *raw = (void *)CFBridgingRetain(copied);  /* retained forever */
    atomic_store_explicit(&g_path_translate_block, raw, memory_order_release);
    fakefs_set_path_translate_hook(ish_path_translate_trampoline);
}

@end

#pragma mark - PTY sessions（#045 T2）

/// guest 线程的宿主信号掩码继承自调 pthread_create 的线程，而 open 跑在 GCD 工作线程上，那里 SIGUSR1 是屏蔽的。
/// iSH 靠 pthread_kill(SIGUSR1) 把卡在宿主系统调用（nanosleep、宿主 read…）里的 guest 线程叫回来处理信号，
/// 屏蔽着的话整棵会话树里睡着的进程连 SIGKILL 都收不到（#076）。只在起跑这一下放开，调用线程的掩码原样还回去。
static void pty_task_start(struct task *task) {
    sigset_t usr1, saved;
    sigemptyset(&usr1);
    sigaddset(&usr1, SIGUSR1);
    pthread_sigmask(SIG_UNBLOCK, &usr1, &saved);
    task_start(task);
    pthread_sigmask(SIG_SETMASK, &saved, NULL);
}

/// exec 之后的失败：task 已经有程序了，干脆起跑再按令牌杀掉、回收，资源走正常退出路径释放（sol 实现审 #3）
static int pty_abort_started(int err, struct task *saved, struct task *task, uint64_t token) {
    pty_task_start(task);
    current = saved;
    pty_kill_until_gone(token);
    pty_reap_token_zombies(token);
    NSLog(@"ISHKernel[pty]: open failed after exec: %d", err);
    return err < 0 ? err : -1;
}

@implementation ISHKernel (PTYSessions)

- (int)openPTYWithArguments:(NSArray<NSString *> *)arguments
                environment:(NSDictionary<NSString *, NSString *> *)environment
                      token:(uint64_t)token
                    columns:(int)columns
                       rows:(int)rows
                     output:(ISHPTYOutputHandler)output
                       exit:(ISHPTYExitHandler)exitHandler {
    if (!self.isBooted || arguments.count == 0 || token == 0) return -1;
    pty_table_init_once();

    // argv / envp 先在宿主侧拼好，拼不下就不造 guest task
    char argv[16384];
    size_t pos = 0;
    int argc = 0;
    for (NSString *arg in arguments) {
        const char *carg = arg.UTF8String;
        size_t len = strlen(carg) + 1;
        if (pos + len >= sizeof(argv)) return _E2BIG;
        memcpy(argv + pos, carg, len);
        pos += len;
        argc++;
    }
    argv[pos] = '\0';

    // 环境完全由调用方给（白名单，见 LocalShellLaunch.environment），这里不偷偷补任何东西
    char envp[8192];
    size_t epos = 0;
    for (NSString *key in environment) {
        NSString *entry = [NSString stringWithFormat:@"%@=%@", key, environment[key]];
        const char *centry = entry.UTF8String;
        size_t len = strlen(centry) + 1;
        if (epos + len >= sizeof(envp)) return _E2BIG;
        memcpy(envp + epos, centry, len);
        epos += len;
    }
    envp[epos] = '\0';

    struct task *saved = current;
    int err = become_new_init_child();
    if (err < 0) {
        current = saved;
        return err;
    }
    struct task *task = current;
    // 令牌先打上：之后它 fork 出来的一切都带着
    task->group->fs_context = token;

    // 先 exec 再接 tty：exec 失败（rootfs 坏了）是唯一回不了滚的点，这时 task 还没碰 tty。
    // 留下的空 task 同 ISHShellExecutor 失败路径，令牌清零免得以后被按令牌扫到
    err = do_execve(arguments[0].UTF8String, argc, argv, envp);
    if (err < 0) {
        task->group->fs_context = 0;
        current = saved;
        NSLog(@"ISHKernel[pty]: do_execve failed: %d", err);
        return err;
    }

    struct tty *tty = pty_open_fake(&ish_pty_driver);
    if (IS_ERR(tty)) return pty_abort_started((int)PTR_ERR(tty), saved, task, token);
    pty_set_winsize(tty, columns, rows);

    NSString *stdioFile = [NSString stringWithFormat:@"/dev/pts/%d", tty->num];
    err = create_stdio(stdioFile.fileSystemRepresentation, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
    if (err < 0) {
        lock(&ttys_lock);
        tty_release(tty);
        unlock(&ttys_lock);
        return pty_abort_started(err, saved, task, token);
    }

    // 先登记再起跑：秒退的进程也能被 exit_hook 认出来
    ISHPTYRecord *rec = [ISHPTYRecord new];
    rec.tty = tty;
    rec.rootPid = task->pid;
    rec.token = token;
    rec.output = output;
    rec.exitHandler = exitHandler;
    pthread_mutex_lock(&g_pty_lock);
    rec.ptyId = g_pty_next_id++;
    g_pty_by_id[@(rec.ptyId)] = rec;
    NSMapInsert(g_pty_by_tty, tty, (__bridge void *)rec);
    atomic_fetch_add_explicit(&g_pty_count, 1, memory_order_release);
    pthread_mutex_unlock(&g_pty_lock);

    pty_task_start(task);
    current = saved;
    NSLog(@"ISHKernel[pty]: #%d pts/%d pid %d %dx%d", rec.ptyId, tty->num, rec.rootPid, columns, rows);
    return rec.ptyId;
}

- (NSInteger)ptyWrite:(int)ptyId bytes:(const void *)bytes length:(NSUInteger)length {
    ISHPTYRecord *rec = pty_record_for_id(ptyId);
    if (rec == nil || rec.closing) return _EIO;
    if (length == 0) return 0;
    return tty_input(rec.tty, bytes, length, false);
}

- (void)ptyResize:(int)ptyId columns:(int)columns rows:(int)rows {
    ISHPTYRecord *rec = pty_record_for_id(ptyId);
    if (rec == nil || rec.closing) return;
    pty_set_winsize(rec.tty, columns, rows);
}

- (void)ptyClose:(int)ptyId {
    pty_table_init_once();
    pthread_mutex_lock(&g_pty_lock);
    ISHPTYRecord *rec = g_pty_by_id[@(ptyId)];
    if (rec == nil || rec.closing) {
        pthread_mutex_unlock(&g_pty_lock);
        return;
    }
    rec.closing = YES;
    pthread_mutex_unlock(&g_pty_lock);

    NSLog(@"ISHKernel[pty]: #%d closing", ptyId);
    pty_kill_until_gone(rec.token);
    pty_raw_write(STDERR_FILENO, "ISHKernel[pty]: #%d killed\n", ptyId);
    // 僵尸握着控制终端引用：先回收，tty 引用才能归零、pts 号才放得掉
    pty_reap_token_zombies(rec.token);
    pty_raw_write(STDERR_FILENO, "ISHKernel[pty]: #%d reaped\n", ptyId);

    // 先摘表再放引用：放完 tty 可能被 free，同一地址马上分给别的会话的话，后摘会误删人家的映射
    pthread_mutex_lock(&g_pty_lock);
    [g_pty_by_id removeObjectForKey:@(ptyId)];
    NSMapRemove(g_pty_by_tty, rec.tty);
    atomic_fetch_sub_explicit(&g_pty_count, 1, memory_order_release);
    pthread_mutex_unlock(&g_pty_lock);

    lock(&ttys_lock);
    tty_release(rec.tty);
    unlock(&ttys_lock);
    NSLog(@"ISHKernel[pty]: #%d closed", ptyId);
}

- (NSDictionary<NSString *, NSNumber *> *)ptyDiagnostics {
    pty_table_init_once();
    pthread_mutex_lock(&g_pty_lock);
    NSUInteger records = g_pty_by_id.count;
    pthread_mutex_unlock(&g_pty_lock);
    int live = 0, zombies = 0;
    lock(&pids_lock);
    for (int i = 2; i < MAX_PID; i++) {
        struct task *t = pid_get_task_zombie(i);
        if (t == NULL || t->group == NULL) continue;
        if ((t->group->fs_context & 0xFFFFFFFF00000000ULL) != ISHPTYTokenNamespace) continue;
        if (t->zombie) zombies++; else live++;
    }
    unlock(&pids_lock);
    return @{@"records": @(records), @"live": @(live), @"zombies": @(zombies)};
}

- (void)ptyWatchdogStartWithLogPath:(NSString *)path {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        strlcpy(g_pty_wd_path, path.fileSystemRepresentation, sizeof(g_pty_wd_path));
        unlink(g_pty_wd_path);   // 上一轮的现场不留：这一轮有这个文件 = 这一轮出过事
        // 现在还正常：把要符号化的镜像加载地址先记下（之后死锁了 dyld 可能也拿不动）
        for (uint32_t i = 0; i < _dyld_image_count() && g_pty_nimages < PTY_MAX_IMAGES; i++) {
            const char *name = _dyld_get_image_name(i);
            if (name == NULL || strstr(name, ".app/") == NULL) continue;
            g_pty_image_hdr[g_pty_nimages] = _dyld_get_image_header(i);
            g_pty_image_name[g_pty_nimages++] = name;
            pty_raw_write(STDERR_FILENO, "[SBX-PTY] image %p %s\n", (const void *)_dyld_get_image_header(i), name);
        }
        pthread_t thread;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        pthread_create(&thread, &attr, pty_watchdog_main, NULL);
        pthread_attr_destroy(&attr);
    });
}

- (void)ptyWatchdogArm:(double)seconds tag:(NSString *)tag {
    const char *ctag = tag.UTF8String ?: "?";
    pthread_mutex_lock(&g_pty_wd_lock);
    strlcpy(g_pty_wd_tag, ctag, sizeof(g_pty_wd_tag));
    g_pty_wd_fired = false;
    g_pty_wd_deadline_ns = pty_now_ns() + (uint64_t)(seconds * 1e9);
    pthread_mutex_unlock(&g_pty_wd_lock);
}

- (BOOL)ptyWatchdogDisarm {
    pthread_mutex_lock(&g_pty_wd_lock);
    BOOL fired = g_pty_wd_fired;
    g_pty_wd_deadline_ns = 0;
    g_pty_wd_fired = false;
    pthread_mutex_unlock(&g_pty_wd_lock);
    return fired;
}

- (void)ptyDumpNow:(NSString *)why {
    pty_dump_to_all(why.UTF8String ?: "?");
}

@end
