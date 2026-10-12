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
# 装好的 App 由 bundle-libmpv.sh 打入 libmpv 及全部依赖（方案 B），
# 之后 brew upgrade mpv 不会影响它。
#
set -euo pipefail

# realpath：取物理路径（bash 内建 `pwd -P` 只解软链、不改大小写）。经软链或大小写不同的
# 路径调用时，逻辑路径会和编译时写进二进制的 SRCROOT 不一致，bundle-libmpv.sh 就收不到依赖
# （见 PITFALLS.md 第 1 节）。
REPO_ROOT="$(/bin/realpath "$(dirname "$0")/..")"
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

# --- 1. 构建 -----------------------------------------------------------------
if [[ "${NO_BUILD}" == 0 ]]; then
    echo "构建 ${SCHEME} (${CONFIG})，构建号 ${BUILD_NUMBER}…"
    LOG="$(/usr/bin/mktemp -t lumaplayer-build)"
    if ! /usr/bin/xcodebuild -scheme "${SCHEME}" -configuration "${CONFIG}" \
            -destination "${DESTINATION}" \
            CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" build >"${LOG}" 2>&1; then
        /usr/bin/grep -E 'error:' "${LOG}" >&2 || /usr/bin/tail -30 "${LOG}" >&2
        echo "error: 构建失败，完整日志: ${LOG}" >&2
        exit 1
    fi
    echo "构建成功。"
fi

# --- 2. 定位构建产物 ---------------------------------------------------------
PRODUCTS_DIR="$(/usr/bin/xcodebuild -scheme "${SCHEME}" -configuration "${CONFIG}" \
        -destination "${DESTINATION}" -showBuildSettings 2>/dev/null \
    | /usr/bin/awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
SRC="${PRODUCTS_DIR}/${APP_NAME}"
if [[ ! -d "${SRC}" ]]; then
    echo "error: 找不到构建产物 ${SRC}" >&2
    exit 1
fi
echo "源: ${SRC}"

# --- 3. 退出正在运行的实例 ---------------------------------------------------
/usr/bin/osascript -e 'quit app "LumaPlayer"' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
    /usr/bin/pgrep -x LumaPlayer >/dev/null 2>&1 || break
    sleep 1
done
/usr/bin/pkill -x LumaPlayer >/dev/null 2>&1 || true

# --- 4. 拷贝到 /Applications -------------------------------------------------
# -L 解引用：Release/Archive 产物里可能含符号链接，不解开会拷出指向构建目录的坏链接。
/bin/rm -rf "${DEST}"
/bin/cp -R -L "${SRC}" "${DEST}"
echo "已安装到: ${DEST}"
"${REPO_ROOT}/Scripts/bundle-libmpv.sh" "${DEST}"

# --- 5. 校验签名，并刷新 LaunchServices（让 Dock / Finder 用上新图标）------
/usr/bin/codesign --verify --strict "${DEST}"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "${DEST}" >/dev/null 2>&1 || true
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${DEST}/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${DEST}/Contents/Info.plist")"
echo "签名校验通过，安装完成（版本 ${VERSION}，构建号 ${BUILD}）。"

# --- 6. 启动刚装好的 App -----------------------------------------------------
# 步骤 3 已经把旧实例退出，这里直接打开新版本，省得手动去 /Applications 点一次。
if [[ "${NO_OPEN}" == 0 ]]; then
    if /usr/bin/open "${DEST}"; then
        echo "已启动 ${DEST}。"
    else
        echo "error: 安装已完成，但启动 ${DEST} 失败（--no-open 可跳过启动）。" >&2
        exit 1
    fi
fi
