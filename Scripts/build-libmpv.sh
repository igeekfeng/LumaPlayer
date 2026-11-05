#!/bin/bash
#
# build-libmpv.sh —— 以 mpv 正式版为基线、打上未合并的 draft PR 自编带 `gpu-next` 后端的 libmpv,装到 Vendor/mpv/prefix/。
#
# 为什么要自编:Dolby Vision(P5)在老 gpu 渲染器上发紫发绿(它不处理 RPU/IPTPQc2),只有 gpu-next
# (libplacebo)做得对。而它进 render API 需要 mpv PR 16818,该 PR 至今未合并,Homebrew 的 mpv
# 和上游正式版都没有 MPV_RENDER_PARAM_BACKEND,所以只能把它作为补丁 0000 打在钉死的正式版上自己编。
#
# 用法:./Scripts/build-libmpv.sh [--clean|--force]  # --clean 删 build/ 重配,--force 连源码重克隆
# 依赖:brew install meson ninja pkgconf;libplacebo / ffmpeg / libass 复用 Homebrew 那份不重编。
#
set -euo pipefail

# realpath 取物理路径:meson 会把 prefix 写进 libmpv 的 install name,再被 App 继承。
# 经软链调用时 install name 会与编译时的 SRCROOT 不一致,打包就收不到依赖(PITFALLS.md 第 1 节)。
REPO_ROOT="$(/bin/realpath "$(dirname "$0")/..")"
MPV_REPO="https://github.com/mpv-player/mpv.git"
# 钉死 v0.42.0 tag 指向的 commit(按 sha 取,tag 被移动也不受影响)。
MPV_SHA="b0841e8c4d156b8403dc1876c4cbd9011eb583f3"

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
    /usr/bin/git -C "${SRC_DIR}" remote add origin "${MPV_REPO}"
fi
# 已有的 src/ 可能还指着别的仓库(换基线时),每次对齐。
/usr/bin/git -C "${SRC_DIR}" remote set-url origin "${MPV_REPO}"
# --depth 1 按 sha 取:拿到就是那个 commit,不拖全部历史。
/usr/bin/git -C "${SRC_DIR}" fetch --depth 1 origin "${MPV_SHA}"
# reset --hard 而非 checkout：src/ 是本脚本的产物，每次回到干净的钉死 commit 再打补丁，
# 保证补丁可重复应用（已打过补丁的工作区再 apply 会失败）。补丁 0000 会新增文件,reset 不删
# 未跟踪文件,必须再 clean,否则第二次运行时 apply 报 already exists。
/usr/bin/git -C "${SRC_DIR}" reset -q --hard FETCH_HEAD
/usr/bin/git -C "${SRC_DIR}" clean -qfdx
echo "源码 HEAD: $(/usr/bin/git -C "${SRC_DIR}" rev-parse HEAD)"

# 本地补丁(Vendor/mpv/patches/*.patch,按文件名顺序):
#   0000  mpv PR 16818 的 head 80351bb3 移植到 v0.42.0:唯一冲突是 render.h 的枚举 ——
#         0.42 的 D3D11 render API 占了 21 / 22,MPV_RENDER_PARAM_BACKEND 从 21 挪到 23
#         (Swift 侧用符号名,不受影响)
#   0001  gpu-next 无视 FLIP_Y(画面上下颠倒)、渲染参数写死最近邻缩放且零初始化(运动画面闪烁)
#   0003  gpu-next 没注册硬解设备,hwdec=auto 退成 videotoolbox-copy(4K 每帧拷回内存,能耗高)
#   0005  init 失败后会调 uninit,但 init_audiounit 失败路径释放了 unit 不置空 → 二次释放
#         (v0.42.0 同样存在)
#   0006  v0.42.0 对 DV Profile 7 无条件拆出增强层(EL)并多开一个解码器,但只有 vo_gpu_next.c
#         会用它;0000 的精简渲染器把 EL 解完就丢。照 vo_gpu_next 把 FEL 的 EL 上传进
#         pl_frame.enhancement_layer(MEL 不上传,libplacebo 只按 nlq_active 合成)
# 编号不连续是有意的:文档与 PITFALLS.md 按编号引用。上游合并 16818 后删 0000、核对 BACKEND 编号,
# 修好哪个缺陷就删掉对应补丁。
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

# meson 把依赖解析成带版本号的 Cellar 绝对路径(如 Cellar/ffmpeg/9.0.2/include)且缓存查找结果,
# --reconfigure 也不刷新;brew upgrade 清掉旧版本后旧 build.ninja 就找不到头文件,只能整个重配。
if [[ -f "${BUILD_DIR}/build.ninja" ]]; then
    while IFS= read -r dep_path; do
        if [[ ! -e "${dep_path}" ]]; then
            echo "Homebrew 依赖已升级（${dep_path} 不存在），清理 build/ 重新配置…"
            /bin/rm -rf "${BUILD_DIR}"
            break
        fi
    done < <(/usr/bin/grep -oE "${BREW_PREFIX}/Cellar/[^ :'\"]+" "${BUILD_DIR}/build.ninja" | /usr/bin/sort -u)
fi

if [[ ! -f "${BUILD_DIR}/build.ninja" ]]; then
    echo "meson setup …"
    # -Dlibmpv=true 只出库（cplayer=false 不编 mpv 可执行文件）。
    # gpl=true 与 Homebrew 的 GPL ffmpeg 对齐；javascript/lua 保持 mpv 默认能力。
    # libcurl 必须是 macOS 自带那份(/usr/lib/libcurl.4.dylib,Homebrew 的 curl 是 keg-only,不在上面的
    # PKG_CONFIG_PATH 里):tls-verify 默认开,系统 curl 用系统证书库,沙盒里实测可用。缺了它网络流退回
    # ffmpeg + Homebrew openssl,CA 路径在 /opt/homebrew 下,没装 Homebrew 的机器上 HTTPS 全部失败 ——
    # 所以写死 enabled,找不到就配置失败,不静默退化。
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
        -Dlibcurl=enabled \
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
    echo "error: ${HEADER} 里没有 MPV_RENDER_PARAM_BACKEND —— 补丁 0000 没打上?" >&2
    exit 1
fi

echo
echo "产物："
/usr/bin/otool -D "${LIB}"
/usr/bin/otool -L "${LIB}" | /usr/bin/tail -n +2 | /usr/bin/sed 's/^/  /'
echo
echo "OK: $(/usr/bin/basename "${LIB}") 已就绪（含 gpu-next 渲染后端）。"
