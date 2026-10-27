#!/bin/bash
#
# build-libmpv.sh —— 从上游未合并的 draft PR 自编带 `gpu-next` 后端的 libmpv,装到 Vendor/mpv/prefix/。
#
# 为什么要自编:Dolby Vision(P5)在老 gpu 渲染器上发紫发绿(它不处理 RPU/IPTPQc2),只有 gpu-next
# (libplacebo)做得对。而它进 render API 需要 mpv-player/mpv#16818,该 PR 至今未合并,Homebrew 的 mpv
# 和上游 master 都没有 MPV_RENDER_PARAM_BACKEND,所以只能钉死那个 commit 自己编。
#
# 用法:./Scripts/build-libmpv.sh [--clean|--force]  # --clean 删 build/ 重配,--force 连源码重克隆
# 依赖:brew install meson ninja pkgconf;libplacebo / ffmpeg / libass 复用 Homebrew 那份不重编。
#
set -euo pipefail

# realpath 取物理路径:meson 会把 prefix 写进 libmpv 的 install name,再被 App 继承。
# 经软链调用时 install name 会与编译时的 SRCROOT 不一致,打包就收不到依赖(PITFALLS.md 第 1 节)。
REPO_ROOT="$(/bin/realpath "$(dirname "$0")/..")"
MPV_REPO="https://github.com/sparky3387/mpv.git"
# 钉死 mpv-player/mpv#16818 的 head(fork sparky3387/mpv)。上游合并后改回官方仓库并更新此值。
MPV_SHA="80351bb32492402c894bb4291acdd44594db8450"

VENDOR="${REPO_ROOT}/Vendor/mpv"
SRC_DIR="${VENDOR}/src"
BUILD_DIR="${VENDOR}/build"
PREFIX="${VENDOR}/prefix"

BREW_PREFIX="/opt/homebrew"

CLEAN=0
FORCE=0
for arg in "$@"; do
    case "${arg}" in
        --clean) CLEAN=1 ;;
        --force) FORCE=1 ;;
        -h|--help) /usr/bin/sed -n '2,11p' "$0"; exit 0 ;;
        *) echo "未知参数: ${arg}" >&2; exit 64 ;;
    esac
done

# --- 0. 预检 -----------------------------------------------------------------
missing=()
for tool in meson ninja pkg-config git clang otool; do
    command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
done
if ((${#missing[@]})); then
    echo "error: 缺少构建工具：${missing[*]}" >&2
    echo "       先跑：brew install meson ninja pkgconf" >&2
    exit 1
fi

# libplacebo 是 gpu-next 后端的全部底气，必须有。
if ! /opt/homebrew/bin/pkg-config --exists libplacebo; then
    echo "error: 找不到 libplacebo（pkg-config）。先跑：brew install libplacebo" >&2
    exit 1
fi

# keg-only 的依赖不在默认 pkg-config 搜索路径里，显式补上。
export PKG_CONFIG_PATH="${BREW_PREFIX}/lib/pkgconfig:${BREW_PREFIX}/opt/libarchive/lib/pkgconfig:${BREW_PREFIX}/opt/vulkan-loader/lib/pkgconfig:${BREW_PREFIX}/opt/vulkan-headers/lib/pkgconfig"

# --- 1. 源码 -----------------------------------------------------------------
if ((FORCE)); then
    echo "强制重新克隆…"
    /bin/rm -rf "${SRC_DIR}"
fi
if [[ ! -d "${SRC_DIR}/.git" ]]; then
    echo "克隆 mpv 源码（钉死 ${MPV_SHA:0:12}）…"
    /bin/mkdir -p "${SRC_DIR}"
    /usr/bin/git -C "${SRC_DIR}" init -q
    /usr/bin/git -C "${SRC_DIR}" remote add origin "${MPV_REPO}" 2>/dev/null \
        || /usr/bin/git -C "${SRC_DIR}" remote set-url origin "${MPV_REPO}"
fi
# --depth 1 按 sha 取:拿到就是那个 commit,不拖全部历史。
/usr/bin/git -C "${SRC_DIR}" fetch --depth 1 origin "${MPV_SHA}"
# reset --hard 而非 checkout：src/ 是本脚本的产物，每次回到干净的钉死 commit 再打补丁，
# 保证补丁可重复应用（已打过补丁的工作区再 apply 会失败）。
/usr/bin/git -C "${SRC_DIR}" reset -q --hard FETCH_HEAD
echo "源码 HEAD: $(/usr/bin/git -C "${SRC_DIR}" rev-parse HEAD)"

# 本地补丁（Vendor/mpv/patches/*.patch，按文件名顺序），都是修 #16818 draft 或上游自身的缺陷：
#   0001  gpu-next 无视 FLIP_Y（画面上下颠倒）、渲染参数写死最近邻缩放且零初始化（运动画面闪烁）
#   0002  上游 PR #18383 原样（已合入 master，fork 基线早于它）：init 失败走 uninit 清理，
#         热插拔监听挪到 AudioUnit 建好之后注册 —— 否则失败后设备变化回调野指针 → 崩溃
#   0003  gpu-next 没注册硬解设备，hwdec=auto 退成 videotoolbox-copy（4K 每帧拷回内存，能耗高）
#   0004  上游 PR #18679 原样（未合并，钉在 head ea102c95）：ChannelMap 一直被传了 AudioChannelLayout
#         而不是 SInt32 数组，macOS 27 起直接 -50 → 全退回 ao_avfoundation（预排 2 秒音频，改倍速丢帧）；
#         删掉这次误用、立体声偏好布局优先，换设备时重载 ao。issue #18384 的另一候选 #18637 未选
#   0005  #18383 让 init 失败后调 uninit，但 init_audiounit 失败路径释放了 unit 不置空 → 二次释放
#         （上游 master 同样存在）
# 换到含 #18383 的上游基线后删 0002；上游修好后删掉对应补丁。
for patch in "${VENDOR}"/patches/*.patch; do
    [[ -e "${patch}" ]] || continue
    echo "打补丁：$(/usr/bin/basename "${patch}")"
    /usr/bin/git -C "${SRC_DIR}" apply --whitespace=nowarn "${patch}"
done

# --- 2. 配置与编译 -----------------------------------------------------------
if ((CLEAN)); then
    echo "清理 build/ …"
    /bin/rm -rf "${BUILD_DIR}"
fi

if [[ ! -f "${BUILD_DIR}/build.ninja" ]]; then
    echo "meson setup …"
    # -Dlibmpv=true 只出库（cplayer=false 不编 mpv 可执行文件）。
    # gpl=true 与 Homebrew 的 GPL ffmpeg 对齐；javascript/lua 保持 mpv 默认能力。
    meson setup "${BUILD_DIR}" "${SRC_DIR}" \
        --prefix="${PREFIX}" \
        --buildtype=release \
        -Dlibmpv=true \
        -Dcplayer=false \
        -Dgpl=true \
        -Dhtml-build=disabled \
        -Djavascript=enabled \
        -Dlua=luajit \
        -Dlibarchive=enabled \
        -Duchardet=enabled \
        -Dvapoursynth=disabled
fi

echo "编译 libmpv …"
meson compile -C "${BUILD_DIR}"

# --- 3. 安装到 Vendor/mpv/prefix --------------------------------------------
echo "安装到 ${PREFIX} …"
meson install -C "${BUILD_DIR}" >/dev/null

LIB="${PREFIX}/lib/libmpv.2.dylib"
HEADER="${PREFIX}/include/mpv/render.h"
[[ -f "${LIB}" ]] || { echo "error: 没生成 ${LIB}" >&2; exit 1; }
[[ -f "${HEADER}" ]] || { echo "error: 没安装 ${HEADER}" >&2; exit 1; }

# 自检：这份自编 libmpv 的意义就在 MPV_RENDER_PARAM_BACKEND，缺了等于白编。
if ! /usr/bin/grep -q "MPV_RENDER_PARAM_BACKEND" "${HEADER}"; then
    echo "error: ${HEADER} 里没有 MPV_RENDER_PARAM_BACKEND —— 这份源码不含 #16818？" >&2
    exit 1
fi

echo
echo "产物："
/usr/bin/otool -D "${LIB}"
/usr/bin/otool -L "${LIB}" | /usr/bin/tail -n +2 | /usr/bin/sed 's/^/  /'
echo
echo "OK: $(/usr/bin/basename "${LIB}") 已就绪（含 gpu-next 渲染后端）。"
