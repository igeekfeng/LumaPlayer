#!/bin/bash
#
# make-dmg.sh —— 用 Release 配置构建 LumaPlayer,打包成可拖拽安装的 DMG(App + /Applications 快捷方式)。
#
# 用法(任意目录):./Scripts/make-dmg.sh [--no-build] [--allow-dirty]   # --no-build 只打包已有产物
# 产物:build/LumaPlayer-{版本}-{构建号}.dmg(build/ 已被 gitignore)
#
# DMG 里的 App 已由 bundle-libmpv.sh 打入 libmpv 及全部依赖,目标机不需要 Homebrew / mpv。
# 但签名是 ad-hoc、未公证,其他机器首次打开要右键「打开」放行一次 —— 只在自己机器上用,不是分发包。
#
set -euo pipefail

# realpath 取物理路径，理由同 deploy-to-applications.sh（PITFALLS.md 第 1 节）。
REPO_ROOT="$(/bin/realpath "$(dirname "$0")/..")"
SCHEME="LumaPlayer"
CONFIG="Release"
DESTINATION="platform=macOS,arch=arm64"
APP_NAME="LumaPlayer.app"
VOLNAME="LumaPlayer"
SIGN_IDENTITY="-"   # ad-hoc

cd "${REPO_ROOT}"

# --- 0. 参数与构建号 ---------------------------------------------------------
# 构建号(CFBundleVersion)= `git rev-list --count HEAD`,构建时注入、不写回 pbxproj。
# 工作区不干净时构建号对不上实际代码,默认拒绝;确需临时打一版用 --allow-dirty。
NO_BUILD=0
ALLOW_DIRTY=0
for arg in "$@"; do
    case "${arg}" in
        --no-build)    NO_BUILD=1 ;;
        --allow-dirty) ALLOW_DIRTY=1 ;;
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

# --- 2. 定位构建产物与版本号 -------------------------------------------------
PRODUCTS_DIR="$(/usr/bin/xcodebuild -scheme "${SCHEME}" -configuration "${CONFIG}" \
        -destination "${DESTINATION}" -showBuildSettings 2>/dev/null \
    | /usr/bin/awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
SRC="${PRODUCTS_DIR}/${APP_NAME}"
if [[ ! -d "${SRC}" ]]; then
    echo "error: 找不到构建产物 ${SRC}" >&2
    exit 1
fi
# 版本号从产物自己的 Info.plist 读,--no-build 时也与实际打进去的一致。
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${SRC}/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${SRC}/Contents/Info.plist")"
/usr/bin/codesign --verify --strict "${SRC}"
echo "源: ${SRC}（版本 ${VERSION}，构建号 ${BUILD}）"

# --- 3. 组装 DMG 内容 --------------------------------------------------------
STAGE="$(/usr/bin/mktemp -d -t lumaplayer-dmg)"
trap '/bin/rm -rf "${STAGE}"' EXIT
# -L 解引用:Release 产物里可能含符号链接,不解开会拷出指向构建目录的坏链接。
/bin/cp -R -L "${SRC}" "${STAGE}/"
/bin/ln -s /Applications "${STAGE}/Applications"
"${REPO_ROOT}/Scripts/bundle-libmpv.sh" "${STAGE}/${APP_NAME}"

# --- 4. 生成、签名、校验 -----------------------------------------------------
OUT_DIR="${REPO_ROOT}/build"
OUT="${OUT_DIR}/${VOLNAME}-${VERSION}-${BUILD}.dmg"
/bin/mkdir -p "${OUT_DIR}"
/bin/rm -f "${OUT}"
# hdiutil 会提示 create/attach 已弃用、建议改用 diskutil image,是信息性输出,功能正常。
/usr/bin/hdiutil create -volname "${VOLNAME}" -srcfolder "${STAGE}" \
    -fs APFS -format UDZO -ov "${OUT}" >/dev/null
/usr/bin/codesign -s "${SIGN_IDENTITY}" --timestamp=none "${OUT}"
/usr/bin/hdiutil verify "${OUT}" >/dev/null 2>&1
/usr/bin/codesign --verify "${OUT}"

echo "已生成: ${OUT}"
/usr/bin/shasum -a 256 "${OUT}"
