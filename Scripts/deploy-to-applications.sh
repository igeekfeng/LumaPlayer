#!/bin/bash
#
# deploy-to-applications.sh
#
# 用 Release 配置构建 LumaPlayer，并安装到 /Applications。
#
# 用法（任意目录）：
#   ./Scripts/deploy-to-applications.sh            # 构建 + 安装 + 启动
#   ./Scripts/deploy-to-applications.sh --no-build # 只安装最近一次 Release 产物
#   ./Scripts/deploy-to-applications.sh --allow-dirty # 工作区有未提交改动也照样构建
#   ./Scripts/deploy-to-applications.sh --no-open  # 装完不自动启动
#
# 播放内核是 AVKit（Features/Player/AVKitPlaybackKernel.swift）+ Rust 决策核心，
# 已无 libmpv。Rust 侧出 staticlib（libluma_core.a）链进主二进制，所以装到
# /Applications 的 App 是自包含的，不需要「把 48 个 dylib 塞进 Frameworks/」那套后处理。
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="LumaPlayer"
CONFIG="Release"
DESTINATION="platform=macOS,arch=arm64"
APP_NAME="LumaPlayer.app"
DEST="/Applications/${APP_NAME}"

cd "${REPO_ROOT}"

# --- 0. 参数与构建号 ---------------------------------------------------------
# 构建号（CFBundleVersion）= `git rev-list --count HEAD`，构建时注入、不写回 pbxproj；
# 历史是线性的，用 `git rev-list --reverse HEAD | sed -n '{构建号}p'` 反查提交。
# 工作区不干净时构建号对不上实际代码，默认拒绝；确需临时装一版用 --allow-dirty。
NO_BUILD=0
ALLOW_DIRTY=0
NO_OPEN=0
for arg in "$@"; do
    case "${arg}" in
        --no-build)    NO_BUILD=1 ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
        --no-open)     NO_OPEN=1 ;;
        *) echo "error: 未知参数 ${arg}" >&2; exit 2 ;;
    esac
done
if [[ "${NO_BUILD}" == 0 ]]; then
    if [[ -n "$(/usr/bin/git status --porcelain)" ]]; then
        if [[ "${ALLOW_DIRTY}" == 0 ]]; then
            echo "error: 工作区有未提交的改动，构建号会对不上代码。先提交，或加 --allow-dirty。" >&2
            exit 1
        fi
        echo "warning: 工作区不干净（--allow-dirty），构建号只对应 HEAD，不含未提交的改动。" >&2
    fi
    BUILD_NUMBER="$(/usr/bin/git rev-list --count HEAD)"
fi

# --- 1. 编译 Rust 核心 -------------------------------------------------------
# App 链的是 RustCore/prefix/lib/libluma_core.a，靠 LumaPlayer/Generated/luma_core.swift
# 拿到类型 —— 两者都由 build-rust-core.sh 产出。必须先于 App 构建，否则 Xcode 找不到
# luma_core 的类型，直接编不过。增量构建很快（cargo 无改动时秒过）。
if [[ "${NO_BUILD}" == 0 ]]; then
    echo "编译 Rust 核心…"
    "${REPO_ROOT}/Scripts/build-rust-core.sh"
fi

# --- 2. 构建 -----------------------------------------------------------------
if [[ "${NO_BUILD}" == 0 ]]; then
    echo "构建 ${SCHEME} (${CONFIG})，构建号 ${BUILD_NUMBER}…"
    LOG="$(/usr/bin/mktemp -t lumaplayer-build)"
    # -disable-sandbox 是本机绕行（⛔ 不是项目配置，所以走命令行而不写进 project.pbxproj）：
    # 本机 sandbox-exec 对 deny-default profile 一律失败，而 Xcode 用它跑 swift-plugin-server
    # → 每个 @Observable 文件报 "produced malformed response"，Release 构建直接挂。
    # 详见 docs/KNOWN_ISSUES.md Q34。
    if ! /usr/bin/xcodebuild -scheme "${SCHEME}" -configuration "${CONFIG}" \
            -destination "${DESTINATION}" \
            OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox' \
            CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" build >"${LOG}" 2>&1; then
        /usr/bin/grep -E 'error:' "${LOG}" >&2 || /usr/bin/tail -30 "${LOG}" >&2
        echo "error: 构建失败，完整日志: ${LOG}" >&2
        exit 1
    fi
    echo "构建成功。"
fi

# --- 3. 定位构建产物 ---------------------------------------------------------
PRODUCTS_DIR="$(/usr/bin/xcodebuild -scheme "${SCHEME}" -configuration "${CONFIG}" \
        -destination "${DESTINATION}" -showBuildSettings 2>/dev/null \
    | /usr/bin/awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
SRC="${PRODUCTS_DIR}/${APP_NAME}"
if [[ ! -d "${SRC}" ]]; then
    echo "error: 找不到构建产物 ${SRC}" >&2
    exit 1
fi
echo "源: ${SRC}"

# --- 4. 退出正在运行的实例 ---------------------------------------------------
/usr/bin/osascript -e 'quit app "LumaPlayer"' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
    /usr/bin/pgrep -x LumaPlayer >/dev/null 2>&1 || break
    sleep 1
done
/usr/bin/pkill -x LumaPlayer >/dev/null 2>&1 || true

# --- 5. 拷贝到 /Applications -------------------------------------------------
# -L 解引用：Release/Archive 产物里可能含符号链接，不解开会拷出指向构建目录的坏链接。
# 产物自包含：Rust 核心以 staticlib 链进主二进制，没有任何 dylib 需要打包后处理。
/bin/rm -rf "${DEST}"
/bin/cp -R -L "${SRC}" "${DEST}"
echo "已安装到: ${DEST}"

# --- 6. 校验签名，并刷新 LaunchServices（让 Dock / Finder 用上新图标）------
/usr/bin/codesign --verify --strict "${DEST}"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "${DEST}" >/dev/null 2>&1 || true
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${DEST}/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${DEST}/Contents/Info.plist")"
echo "签名校验通过，安装完成（版本 ${VERSION}，构建号 ${BUILD}）。"

# --- 7. 启动刚装好的 App -----------------------------------------------------
# 步骤 4 已经把旧实例退出，这里直接打开新版本，省得手动去 /Applications 点一次。
# ⚠️ 本机（2026-10-10）App 带 app-sandbox，启动阶段即 SIGTRAP，所以这一步会「静默失败」：
#    open 返回 0（LaunchServices 已接手），但进程随后崩在 _libsecinit_appsandbox。
#    因此本脚本目前只能验收「已安装 + 签名校验通过」，运行验收不靠它（见 docs/KNOWN_ISSUES.md Q34）。
if [[ "${NO_OPEN}" == 0 ]]; then
    if /usr/bin/open "${DEST}"; then
        echo "已启动 ${DEST}。"
    else
        echo "error: 安装已完成，但启动 ${DEST} 失败（--no-open 可跳过启动）。" >&2
        exit 1
    fi
fi
