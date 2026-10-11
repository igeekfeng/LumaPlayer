#!/bin/bash
#
# build-libmpv.sh
#
# 从上游未合并的 draft PR 自编一份带 `gpu-next` 渲染后端的 libmpv，
# 装到 Vendor/mpv/prefix/。App 通过 Vendor/mpv/module.modulemap 与
# OTHER_LDFLAGS 指向它（见 docs/MPV_INTEGRATION.md §0、§3.3）。
#
# 为什么要自编：Dolby Vision（Profile 5）片源在 `vo=libmpv` 的**老 gpu 渲染器**
# 上会发紫发绿 —— 那个渲染器不处理 DV 的 RPU/IPTPQc2。`gpu-next`（libplacebo）
# 才做得对，但它进 render API 需要 mpv-player/mpv#16818，而该 PR 至今未合并，
# Homebrew 的 mpv（0.41.0）和上游 master 都没有 MPV_RENDER_PARAM_BACKEND。
# 所以只能钉死那个 PR 的 commit 自己编。
#
# 用法：
#   ./Scripts/build-libmpv.sh            # 增量（已编过就只重编改动）
#   ./Scripts/build-libmpv.sh --clean    # 删掉 build/ 重新配置
#   ./Scripts/build-libmpv.sh --force    # 连源码一起重新克隆
#
# 依赖（本机需先装）：brew install meson ninja pkgconf
# 其余依赖（libplacebo / ffmpeg / libass / …）复用 Homebrew 那份，不重编。
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MPV_REPO="https://github.com/sparky3387/mpv.git"
# 钉死的 commit：mpv-player/mpv#16818 "vo_libmpv: introduce 'gpu-next' render backend"
# 的 head（fork sparky3387/mpv）。上游合并后应改回官方仓库并更新此值。
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
        -h|--help) /usr/bin/sed -n '2,30p' "$0"; exit 0 ;;
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
# --depth 1 按 sha 取：拿到就是那个 commit，不拖全部历史。
/usr/bin/git -C "${SRC_DIR}" fetch --depth 1 origin "${MPV_SHA}"
# reset --hard 而非 checkout：src/ 是本脚本的产物，每次都回到干净的钉死 commit
# 再打补丁，保证补丁可重复应用（已打过补丁的工作区再 apply 会失败）。
/usr/bin/git -C "${SRC_DIR}" reset -q --hard FETCH_HEAD
echo "源码 HEAD: $(/usr/bin/git -C "${SRC_DIR}" rev-parse HEAD)"

# 本地补丁（Vendor/mpv/patches/*.patch，按文件名顺序）：修 #16818 draft 里的缺陷。
#   0001：gpu-next 后端无视 MPV_RENDER_PARAM_FLIP_Y（画面上下颠倒）；
#         渲染参数写死最近邻缩放且零初始化（4K 缩到窗口时运动画面闪烁、无抖动）；
#         改用 libplacebo 默认参数，但关掉帧混合（与 vo_gpu_next 默认一致）。
#   0002：ao_coreaudio 的 init() 在注册设备热插拔监听之后失败时（如 5.1 片源 + 立体声设备，
#         设声道布局报 -50，回退 avfoundation）不注销监听，ao 却被释放；之后任何音频设备
#         变化（连蓝牙耳机）都会回调到野指针 → 崩溃。非 #16818 引入，上游代码本身的缺陷。
#   0003：gpu-next 后端没注册硬解设备，hwdec=auto 只能退成 videotoolbox-copy（4K 帧每帧
#         拷回内存 + CPU 重排上传，能耗高）。补上 VideoToolbox 设备，IOSurface 平面在 GPU 上
#         blit 进 libplacebo 纹理（libplacebo 的 GL 后端采样 sampler2DRect 会生成非法 GLSL）。
# 上游修好后删掉对应补丁。
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
