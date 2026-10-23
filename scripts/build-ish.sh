#!/bin/bash
set -euo pipefail

# ============================================================================
# build-ish.sh <iphoneos|iphonesimulator>
# ============================================================================
# 从 OpenMinis deps/build_ish.sh 改：参数化 SDK，每个平台一份静态库。
#
# 输出：
#   deps/libs/<platform>/{libish,libish_emu,libfakefs}.a
#   deps/include/ish/**            （头文件，平台无关，两平台共用）
#
# 源码目录 = git submodule `deps/ish`（OpenMinis/ish-arm64，钉在 19c690c）。
# 它自己的 deps/{libapps,libarchive,linux} 三个子模块**不需要 init**：
#   - deps/meson.build 整个 body 被 `if get_option('kernel') == 'linux'` 包着，我们用 kernel=ish
#   - libarchive 由 tools/meson.build 从 brew 找（/opt/homebrew/opt/libarchive），不走子模块
#   - libapps 是 iOS app 的 hterm 终端，与静态库无关
# meson build 目录建在 build/ish/<platform>（out-of-tree，不污染子模块工作树）。
#
# 硬约束：libvdso.so.elf 必须非零字节。上游在找不到 lld 时会静默 `touch` 一个
# 空文件当 VDSO（vdso/arm64/meson.build:34-41），然后 .incbin 进 libish.a，
# 构建全绿但 guest 运行期拿到零字节 VDSO。这里断言，失败就退出。
# ============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISH_DIR="${ISH_DIR:-$REPO_ROOT/deps/ish}"
OUTPUT_LIBS="$REPO_ROOT/deps/libs"
OUTPUT_INCLUDE="$REPO_ROOT/deps/include"
IOS_DEPLOYMENT_TARGET="14.0"

PLATFORM="${1:-}"
BUILD_TYPE="${2:-release}"

usage() {
    echo "usage: build-ish.sh <iphoneos|iphonesimulator> [release|debug]" >&2
    exit 2
}

die() { echo "❌ $1" >&2; exit 1; }
info() { echo "ℹ️  $1"; }
ok() { echo "✅ $1"; }

case "$PLATFORM" in
    iphoneos|iphonesimulator) ;;
    "") usage ;;
    *) echo "❌ 未知平台：$PLATFORM" >&2; usage ;;
esac

BUILD_DIR="$REPO_ROOT/build/ish/$PLATFORM"
CROSS_FILE="$BUILD_DIR/cross-$PLATFORM.txt"

# ---------------------------------------------------------------------------
# PATH 兜底：Xcode 的 run script 继承的是启动 Xcode.app / xcodebuild 那个进程的
# PATH，GUI 启动时通常不含 /opt/homebrew/bin，meson/ninja/lld 全都找不到。
# 这里只是把标准 brew 前缀补进 PATH，不改变任何「缺了就失败」的语义。
# ---------------------------------------------------------------------------
ensure_toolchain_path() {
    for d in /opt/homebrew/bin /usr/local/bin /opt/homebrew/opt/lld/bin /usr/local/opt/lld/bin; do
        case ":$PATH:" in
            *":$d:"*) ;;
            *) [ -d "$d" ] && PATH="$d:$PATH" ;;
        esac
    done
    export PATH
}

# ---------------------------------------------------------------------------
# 前置工具自检（缺一个直接失败，不降级）
# ---------------------------------------------------------------------------
check_prerequisites() {
    info "检查工具链…"
    command -v python3 >/dev/null || die "缺 python3"
    command -v meson >/dev/null || die "缺 meson（brew install meson）"
    command -v ninja >/dev/null || die "缺 ninja（brew install ninja）"
    xcode-select -p >/dev/null 2>&1 || die "缺 Xcode command line tools"

    LLVM_CLANG=""
    for p in /opt/homebrew/opt/llvm/bin/clang /usr/local/opt/llvm/bin/clang /opt/local/bin/clang; do
        [ -x "$p" ] && LLVM_CLANG="$p" && break
    done
    [ -n "$LLVM_CLANG" ] || die "缺 brew llvm（VDSO 交叉编译器）：brew install llvm"

    # lld：vdso/arm64/meson.build:25 硬编码 -fuse-ld=lld；homebrew 的 llvm formula
    # 不含 lld，是独立 formula 且 keg-only（不自动上 PATH）。
    command -v ld.lld >/dev/null || die "缺 ld.lld：brew install lld 并把 /opt/homebrew/opt/lld/bin 前置到 PATH"

    if [ ! -f "$ISH_DIR/meson.build" ]; then
        die "ish 子模块没拉：$ISH_DIR —— 跑 git submodule update --init deps/ish（**不要** --recursive）"
    fi
    ok "工具链 OK（llvm=$LLVM_CLANG, lld=$(command -v ld.lld)）"
}

# ---------------------------------------------------------------------------
# meson cross file（唯一的平台差异点）
# ---------------------------------------------------------------------------
setup_cross_file() {
    info "生成 cross file（${PLATFORM}）…"
    mkdir -p "$BUILD_DIR"
    SDK_PATH="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"
    [ -d "$SDK_PATH" ] || die "SDK 路径不存在：$SDK_PATH"

    if [ "$PLATFORM" = "iphonesimulator" ]; then
        # 模拟器必须用 -target 三元组带 -simulator 后缀；用 -mios-version-min 会
        # 编出 platform=iOS 的 object，链接时报
        # "building for 'iOS-simulator', but linking in object file built for 'iOS'"
        C_ARGS_LINE="c = ['clang', '-target', 'arm64-apple-ios$IOS_DEPLOYMENT_TARGET-simulator', '-isysroot', '$SDK_PATH']"
    else
        C_ARGS_LINE="c = ['clang', '-arch', 'arm64', '-isysroot', '$SDK_PATH', '-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET']"
    fi

    {
        echo "[binaries]"
        echo "$C_ARGS_LINE"
        echo "ar = 'ar'"
        echo "strip = 'strip'"
        echo "pkg-config = 'false'"
        echo ""
        echo "[host_machine]"
        echo "system = 'darwin'"
        echo "cpu_family = 'aarch64'"
        echo "cpu = 'aarch64'"
        echo "endian = 'little'"
        echo ""
        echo "[built-in options]"
        echo "c_args = []"
        echo "c_link_args = ['-L$SDK_PATH/usr/lib']"
        echo ""
        echo "[properties]"
        echo "needs_exe_wrapper = true"
        echo "sys_root = '$SDK_PATH'"
        echo "library_dirs = ['$SDK_PATH/usr/lib']"
    } > "$CROSS_FILE"

    ok "cross file: $CROSS_FILE (SDK=$SDK_PATH)"
}

# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------
build_ish() {
    info "构建 iSH 静态库（$PLATFORM / ${BUILD_TYPE}）…"
    MESON_BUILDTYPE="release"
    [ "$BUILD_TYPE" = "debug" ] && MESON_BUILDTYPE="debug"

    if [ ! -f "$BUILD_DIR/build.ninja" ]; then
        meson setup "$BUILD_DIR" "$ISH_DIR" \
            --cross-file "$CROSS_FILE" \
            --buildtype="$MESON_BUILDTYPE" \
            -Dlog="" \
            -Dlog_handler=nslog \
            -Dkernel=ish \
            -Dengine=asbestos \
            -Dguest_arch=arm64
    else
        info "meson 已配置，只 reconfigure buildtype"
        meson configure "$BUILD_DIR" --buildtype="$MESON_BUILDTYPE"
    fi

    ninja -C "$BUILD_DIR" libish.a libish_emu.a libfakefs.a
    # VDSO：上游这一步失败只 warning，这里当硬失败
    ninja -C "$BUILD_DIR" vdso/arm64/libvdso.so.elf || die "VDSO 构建失败"
    ok "静态库构建完成"
}

# ---------------------------------------------------------------------------
# VDSO 非零断言（本脚本存在的主要理由之一）
# ---------------------------------------------------------------------------
assert_vdso() {
    VDSO="$BUILD_DIR/vdso/arm64/libvdso.so.elf"
    [ -f "$VDSO" ] || die "VDSO 产物不存在：$VDSO"
    VDSO_SIZE=$(stat -f%z "$VDSO")
    if [ "$VDSO_SIZE" -eq 0 ]; then
        die "VDSO 是零字节 stub（${VDSO}）——lld 没找到，libish.a 里 .incbin 进去的是空文件。修：brew install lld + PATH 前置 /opt/homebrew/opt/lld/bin"
    fi
    ok "VDSO 非零：$VDSO_SIZE 字节"
}

# ---------------------------------------------------------------------------
# 产物落盘
# ---------------------------------------------------------------------------
# 内容没变就不落盘。这里落的头是 bridging header 的依赖，mtime 一变 Xcode 就把
# iOS target 全部 Swift（~480 文件）重编一遍；.a 一变就重链。实测换个模拟器目的地
# 触发脚本 → 79–113s，脚本幂等后 → ~25s（docs/research-ish-spm-modularize.md §5.2 / §7）。
SYNCED=0
sync_files() {   # sync_files <dst-dir> <src...>；src 不存在（含 glob 没命中）静默跳过
    local dst="$1"; shift
    local f
    for f in "$@"; do
        [ -f "$f" ] || continue
        if ! cmp -s "$f" "$dst/$(basename "$f")"; then
            cp "$f" "$dst/"
            SYNCED=$((SYNCED + 1))
        fi
    done
}

copy_outputs() {
    info "复制产物…"
    DEST="$OUTPUT_LIBS/$PLATFORM"
    mkdir -p "$DEST"
    sync_files "$DEST" "$BUILD_DIR/libish.a" "$BUILD_DIR/libish_emu.a" "$BUILD_DIR/libfakefs.a"

    mkdir -p "$OUTPUT_INCLUDE/ish/emu" "$OUTPUT_INCLUDE/ish/kernel" \
             "$OUTPUT_INCLUDE/ish/fs/proc" "$OUTPUT_INCLUDE/ish/util" \
             "$OUTPUT_INCLUDE/ish/platform" "$OUTPUT_INCLUDE/ish/asbestos" \
             "$OUTPUT_INCLUDE/ish/asbestos/guest-arm64/gadgets-aarch64" \
             "$OUTPUT_INCLUDE/ish/emu/arch/arm64" \
             "$OUTPUT_INCLUDE/ish/kernel/arch/arm64" \
             "$OUTPUT_INCLUDE/ish/deps"

    sync_files "$OUTPUT_INCLUDE/ish" "$ISH_DIR/debug.h" "$ISH_DIR/misc.h" "$ISH_DIR/xX_main_Xx.h"
    sync_files "$OUTPUT_INCLUDE/ish/emu" "$ISH_DIR"/emu/*.h
    sync_files "$OUTPUT_INCLUDE/ish/kernel" "$ISH_DIR"/kernel/*.h
    sync_files "$OUTPUT_INCLUDE/ish/fs" "$ISH_DIR"/fs/*.h
    sync_files "$OUTPUT_INCLUDE/ish/fs/proc" "$ISH_DIR"/fs/proc/*.h
    sync_files "$OUTPUT_INCLUDE/ish/util" "$ISH_DIR"/util/*.h
    sync_files "$OUTPUT_INCLUDE/ish/platform" "$ISH_DIR"/platform/*.h
    sync_files "$OUTPUT_INCLUDE/ish/asbestos" "$ISH_DIR"/asbestos/*.h
    sync_files "$OUTPUT_INCLUDE/ish/asbestos/guest-arm64/gadgets-aarch64" "$ISH_DIR"/asbestos/guest-arm64/gadgets-aarch64/*.h
    sync_files "$OUTPUT_INCLUDE/ish/emu/arch/arm64" "$ISH_DIR"/emu/arch/arm64/*.h
    sync_files "$OUTPUT_INCLUDE/ish/kernel/arch/arm64" "$ISH_DIR"/kernel/arch/arm64/*.h
    sync_files "$OUTPUT_INCLUDE/ish" "$BUILD_DIR/cpu-offsets.h"
    sync_files "$OUTPUT_INCLUDE/ish/deps" "$ISH_DIR/deps/config.h"
    ok "产物 → $DEST"
}

create_umbrella_header() {
    UMBRELLA="$OUTPUT_INCLUDE/ish/ish.h"
    local tmp; tmp="$(mktemp)"
    {
        echo "/* iSH-ARM64 umbrella header（build-ish.sh 生成，别手改） */"
        echo "#ifndef ISH_H"
        echo "#define ISH_H"
        echo "#include \"misc.h\""
        echo "#include \"debug.h\""
        echo "#include \"kernel/init.h\""
        echo "#include \"kernel/task.h\""
        echo "#include \"kernel/calls.h\""
        echo "#include \"kernel/fs.h\""
        echo "#include \"kernel/memory.h\""
        echo "#include \"kernel/signal.h\""
        echo "#include \"kernel/errno.h\""
        echo "#include \"fs/fd.h\""
        echo "#include \"fs/stat.h\""
        echo "#include \"fs/tty.h\""
        echo "#include \"fs/fake.h\""
        echo "#include \"fs/real.h\""
        echo "#include \"fs/poll.h\""
        echo "#include \"fs/dev.h\""
        echo "#include \"emu/cpu.h\""
        echo "#include \"emu/tlb.h\""
        echo "#include \"emu/mmu.h\""
        echo "#if defined(GUEST_X86)"
        echo "#include \"emu/float80.h\""
        echo "#endif"
        echo "#include \"platform/platform.h\""
        echo "#endif /* ISH_H */"
    } > "$tmp"
    if ! cmp -s "$tmp" "$UMBRELLA"; then cp "$tmp" "$UMBRELLA"; SYNCED=$((SYNCED + 1)); fi
    rm -f "$tmp"
    ok "umbrella header: $UMBRELLA"
}

verify_slice() {
    DEST="$OUTPUT_LIBS/$PLATFORM"
    echo ""
    echo "=== 产物核实（${PLATFORM}）==="
    ls -l "$DEST"/*.a
    lipo -info "$DEST/libish.a"
    otool -l "$DEST/libish.a" | grep -A3 LC_BUILD_VERSION | head -8
}

ensure_toolchain_path
check_prerequisites
setup_cross_file
build_ish
assert_vdso
copy_outputs
create_umbrella_header
verify_slice
ok "build-ish.sh $PLATFORM 完成（落盘变化 $SYNCED 个文件；0 = 头/.a 全没变，Xcode 不会重编 Swift）"
