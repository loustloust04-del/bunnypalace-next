#!/bin/bash
set -euo pipefail

# ============================================================================
# prepare-rootfs.sh [alpine-version|clean]
# ============================================================================
# SPDX-License-Identifier: GPL-3.0-only
# Derived from OpenMinis (https://github.com/OpenMinis/OpenMinis), deps/prepare_alpine_rootfs.sh,
# licensed under the GNU General Public License v3.0.
# Modifications Copyright (C) 2026 Mneme Atrium contributors, also under GPL-3.0.
# This build script is GPL-3.0; it is not compiled into the app.
#
# 从 OpenMinis deps/prepare_alpine_rootfs.sh 改。产出 deps/resources/alpine-rootfs.zip
# （fakefs 格式：alpine-rootfs/{meta.db,data/}），进 iOS bundle。
#
# 相对上游的三处实质改动：
#
# 1. **配置写在 fakefsify 之前**。上游在转换完成后往 `data/` 里 cat 文件
#    （prepare_alpine_rootfs.sh:256-266），但 fakefs 只认 meta.db 里登记过的 inode：
#    tar 里本来就有的文件（/etc/profile、/etc/apk/repositories …）原地覆盖内容有效，
#    **tar 里没有的文件（/etc/resolv.conf）guest 里根本看不见** —— 08-25 探针实证
#    `cat /etc/resolv.conf` → No such file or directory。
#    这里改成：解 tar → 在 staging 树上配置 → 重新打 tar → fakefsify，
#    所有文件都走正规通道进 meta.db。
#    （Alpine minirootfs 实测 88 普通文件 / 97 目录 / 335 符号链接，
#      **无设备节点、无 setuid、全部 uid 0**，所以非 root 解包再打包是安全的；
#      重新打包时显式 --uid 0 --gid 0 --uname root --gname root 钉死属主。）
#
# 2. **去 Minis 品牌**：PS1 '\u@minis:\w\$ ' → '\u@garden:\w\$ '，motd 换中性横幅。
#    （浏览器 wrapper / minis-mcp-cli / /var/minis 不在这个脚本里——它们来自
#     Minis 的 default_mount 覆盖层和 RootfsManager，MP 都不搬。）
#
# 3. **打包用 python3 zipfile**。macOS /usr/bin/zip 是 Apple 阉割版 Info-ZIP，
#    不给非 ASCII 路径设 GP bit 11（UTF-8 flag），iOS 侧 ZIPFoundation 会按 CP437
#    解码成乱码。现在 rootfs 全 ASCII 没触发，但这条路以后要塞中文就会炸。
#
# 另外 meson 的 native build 也挪成 out-of-tree（build/ish/native），
# 不在 deps/ish 子模块工作树里留 build-native/。
# ============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ISH_DIR="${ISH_DIR:-$REPO_ROOT/deps/ish}"
OUTPUT_DIR="$REPO_ROOT/deps/resources"
CACHE_DIR="$REPO_ROOT/build/rootfs-cache"
STAGING_DIR="$REPO_ROOT/build/rootfs-staging"
NATIVE_BUILD="$REPO_ROOT/build/ish/native"

ALPINE_VERSION="${1:-3.21}"
ALPINE_MINOR="0"
ALPINE_ARCH="aarch64"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"

ROOTFS_FILE="alpine-minirootfs-${ALPINE_VERSION}.${ALPINE_MINOR}-${ALPINE_ARCH}.tar.gz"
ROOTFS_TARBALL="$CACHE_DIR/$ROOTFS_FILE"
CONFIGURED_TARBALL="$STAGING_DIR/alpine-configured.tar.gz"
FAKEFS_OUT="$OUTPUT_DIR/alpine-rootfs"
ZIP_FILE="$OUTPUT_DIR/alpine-rootfs.zip"

die() { echo "❌ $1" >&2; exit 1; }
info() { echo "ℹ️  $1"; }
ok() { echo "✅ $1"; }

ensure_toolchain_path() {
    for d in /opt/homebrew/bin /usr/local/bin; do
        case ":$PATH:" in
            *":$d:"*) ;;
            *) [ -d "$d" ] && PATH="$d:$PATH" ;;
        esac
    done
    export PATH
}

check_prerequisites() {
    info "检查工具链…"
    command -v curl >/dev/null || die "缺 curl"
    command -v python3 >/dev/null || die "缺 python3"
    command -v meson >/dev/null || die "缺 meson（brew install meson）"
    command -v ninja >/dev/null || die "缺 ninja（brew install ninja）"
    local found=0
    for d in /opt/homebrew/opt/libarchive /usr/local/opt/libarchive /usr; do
        if [ -f "$d/lib/libarchive.dylib" ] || [ -f "$d/lib/libarchive.a" ]; then found=1; break; fi
    done
    [ "$found" -eq 1 ] || die "缺 libarchive（brew install libarchive）—— fakefsify 靠它读 tar"
    [ -f "$ISH_DIR/meson.build" ] || die "ish 子模块没拉：$ISH_DIR —— git submodule update --init deps/ish"
    ok "工具链 OK"
}

# 已知 tarball 的 sha256（和官方 .sha256 核过）。换版本要在这补一行，或者设 ALPINE_SHA256。
# 不去镜像上拿 .sha256：同源校验防不了被篡改的镜像。
known_sha256() {
    case "$1" in
        alpine-minirootfs-3.21.0-aarch64.tar.gz) echo f31202c4070c4ef7de9e157e1bd01cb4da3a2150035d74ea5372c5e86f1efac1 ;;
    esac
}

download_alpine() {
    local want="${ALPINE_SHA256:-$(known_sha256 "$ROOTFS_FILE")}"
    [ -n "$want" ] || die "没有 ${ROOTFS_FILE} 的 sha256：在 known_sha256 里补一行（和官方 .sha256 核过），或者设 ALPINE_SHA256=…"
    mkdir -p "$CACHE_DIR"
    if [ -f "$ROOTFS_TARBALL" ]; then
        info "用缓存的 tarball：$ROOTFS_FILE"
    else
        local url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/${ROOTFS_FILE}"
        info "下载 $url"
        curl -fL -o "$ROOTFS_TARBALL" "$url" --progress-bar || die "下载失败"
    fi
    [ -s "$ROOTFS_TARBALL" ] || die "tarball 是空的：$ROOTFS_TARBALL"
    local got
    got=$(shasum -a 256 "$ROOTFS_TARBALL" | cut -d' ' -f1)
    if [ "$got" != "$want" ]; then
        rm -f "$ROOTFS_TARBALL"
        die "sha256 不符（期望 ${want}，实际 ${got}），已删掉这份 tarball，重跑会重新下载"
    fi
    ok "Alpine tarball：$(stat -f%z "$ROOTFS_TARBALL") 字节，sha256 核过"
}

build_fakefsify() {
    if [ -x "$NATIVE_BUILD/tools/fakefsify" ]; then
        info "fakefsify 已构建"
        return
    fi
    info "构建 fakefsify（native，out-of-tree）…"
    mkdir -p "$NATIVE_BUILD"
    if [ ! -f "$NATIVE_BUILD/build.ninja" ]; then
        meson setup "$NATIVE_BUILD" "$ISH_DIR" \
            --buildtype=release \
            -Dlog="" \
            -Dkernel=ish \
            -Dengine=asbestos \
            -Dguest_arch=arm64
    fi
    ninja -C "$NATIVE_BUILD" tools/fakefsify
    [ -x "$NATIVE_BUILD/tools/fakefsify" ] || die "fakefsify 构建失败"
    ok "fakefsify 就绪"
}

# ---------------------------------------------------------------------------
# 解 tar → 配置 → 重新打 tar（**与上游最大的差异**，见文件头注释 1）
# ---------------------------------------------------------------------------
stage_and_configure() {
    info "解包到 staging 并配置（fakefsify 之前）…"
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR/rootfs"
    tar -xpf "$ROOTFS_TARBALL" -C "$STAGING_DIR/rootfs"

    local R="$STAGING_DIR/rootfs"

    # iSH 自己在 boot 时建 /dev 节点；这里只保证目录存在（放 tar 里才进 meta.db）
    mkdir -p "$R/dev" "$R/proc" "$R/sys" "$R/tmp" "$R/run" "$R/root" "$R/home"

    # 文件库挂载点（T3a / plan §1.5 R2）：**必须走 tar → fakefsify**，
    # 不能安装后在宿主 data/ 里 mkdir——那样 meta.db 没有 inode，guest 里
    # `ls /mnt/library` 看不见，而且 fakefs_bind_mount 要求父目录在 meta.db 里存在
    # （ISHKernel.h bindMountPath 的文档原话）。与 T1 的 resolv.conf 是同一个坑。
    # 约定为空：每个楼层挂成 /mnt/library/<slug>，宿主侧不许往这里放真东西。
    mkdir -p "$R/mnt/library"

    # root 用 /bin/sh
    [ -f "$R/etc/passwd" ] && sed -i '' 's|^root:.*|root:x:0:0:root:/root:/bin/sh|' "$R/etc/passwd"

    # shell 环境（中性品牌）
    cat >> "$R/etc/profile" <<'PROFILE_EOF'

# 记忆花园 离线沙箱
export PS1='\u@garden:\w\$ '
export TERM=xterm-256color
export HOME=/root
export LANG=C.UTF-8
export CHARSET=UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin

alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'

cd ~
PROFILE_EOF

    cat > "$R/etc/motd" <<'MOTD_EOF'

  记忆花园 · 离线沙箱
  Alpine Linux aarch64 (iSH-ARM64 emulator)

MOTD_EOF

    cat > "$R/etc/inittab" <<'INITTAB_EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
INITTAB_EOF

    # ⚠️ /etc/resolv.conf 在 Alpine minirootfs 的 tar 里**不存在**。上游在
    # fakefsify 之后建它 → meta.db 没有对应 inode → guest 里看不见（08-25 探针实证）。
    # 在 staging 里建，重新打 tar 后它就是一条正规 tar entry。
    # 运行期 ISHKernel.mountDnsConfig 会把它 bind mount 到宿主的 dns/resolv.conf；
    # bind 失败时这份种子内容就是兜底。
    cat > "$R/etc/resolv.conf" <<'RESOLV_EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
RESOLV_EOF

    mkdir -p "$R/etc/apk"
    cat > "$R/etc/apk/repositories" <<REPO_EOF
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
REPO_EOF

    # 重新打包：属主钉成 root:root（非 root 解包后本地属主是当前用户，
    # 不钉的话 fakefsify 会把 uid=501 写进 meta.db，guest 里 root 就不拥有系统文件了）
    info "重新打 tar（--uid 0 --gid 0）…"
    tar -czf "$CONFIGURED_TARBALL" \
        --uid 0 --gid 0 --uname root --gname root \
        -C "$R" .
    [ -s "$CONFIGURED_TARBALL" ] || die "重新打包失败"
    ok "配置完成的 tarball：$(stat -f%z "$CONFIGURED_TARBALL") 字节"
}

create_fakefs() {
    info "fakefsify 转换…"
    rm -rf "$FAKEFS_OUT"
    mkdir -p "$OUTPUT_DIR"
    "$NATIVE_BUILD/tools/fakefsify" "$CONFIGURED_TARBALL" "$FAKEFS_OUT"
    [ -d "$FAKEFS_OUT/data" ] || die "转换失败：没有 data/"
    [ -f "$FAKEFS_OUT/meta.db" ] || die "转换失败：没有 meta.db"
    # 关键断言：resolv.conf 必须真的落进 data/ 且在 meta.db 里有 inode
    # （paths.path 是 BLOB，要用 bytes 查）
    [ -f "$FAKEFS_OUT/data/etc/resolv.conf" ] || die "data/etc/resolv.conf 不存在——配置没进 tar"
    python3 "$REPO_ROOT/scripts/assert-rootfs-meta.py" "$FAKEFS_OUT/meta.db" || die "meta.db 断言失败"
    ok "fakefs 就绪（meta.db 里有 /etc/resolv.conf）"
}

create_zip() {
    info "打 zip（python3 zipfile，自动设 UTF-8 flag）…"
    rm -f "$ZIP_FILE"
    python3 "$REPO_ROOT/scripts/pack-rootfs-zip.py" "$FAKEFS_OUT" "$ZIP_FILE" || die "zip 生成失败"
    [ -s "$ZIP_FILE" ] || die "zip 是空的"
    ok "zip：$(stat -f%z "$ZIP_FILE") 字节 → $ZIP_FILE"
}

summary() {
    echo ""
    echo "============================================================"
    echo "  rootfs 就绪"
    echo "    data/    $(du -sh "$FAKEFS_OUT/data" | cut -f1)"
    echo "    meta.db  $(stat -f%z "$FAKEFS_OUT/meta.db") 字节"
    echo "    zip      $(stat -f%z "$ZIP_FILE") 字节"
    echo "============================================================"
}

clean() {
    rm -rf "$FAKEFS_OUT" "$ZIP_FILE" "$STAGING_DIR" "$NATIVE_BUILD" "$CACHE_DIR"
    ok "清理完成"
}

if [ "${1:-}" = "clean" ]; then clean; exit 0; fi

ensure_toolchain_path
check_prerequisites
download_alpine
build_fakefsify
stage_and_configure
create_fakefs
create_zip
summary
