#!/bin/bash
#
# make-dmg.sh
#
# 用 Release 配置构建 LumaPlayer，打包成可拖拽安装的 DMG（App + /Applications 快捷方式）。
#
# 用法（任意目录）：
#   ./Scripts/make-dmg.sh            # 构建 + 打包
#   ./Scripts/make-dmg.sh --no-build # 只打包最近一次 Release 产物
#   ./Scripts/make-dmg.sh --allow-dirty # 工作区有未提交改动也照样构建
#
# 产物：build/LumaPlayer-{版本}-{构建号}.dmg（build/ 已被 .gitignore 忽略）
#
# 播放内核是 AVKit（Features/Player/AVKitPlaybackKernel.swift）+ Rust 决策核心，
# 已无 libmpv。Rust 侧出 staticlib（libluma_core.a）链进主二进制，所以 DMG 里的
# App 自包含，目标机不需要装 Homebrew / mpv，也不需要任何 dylib 后处理。
# 但签名是 ad-hoc、未公证：其他机器首次打开要右键「打开」放行一次。
# 只在自己的 Apple Silicon + macOS 27 机器上用，不是分发包。
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="LumaPlayer"
CONFIG="Release"
DESTINATION="platform=macOS,arch=arm64"
APP_NAME="LumaPlayer.app"
VOLNAME="LumaPlayer"
SIGN_IDENTITY="-"   # ad-hoc

cd "${REPO_ROOT}"

# --- 0. 参数与构建号 ---------------------------------------------------------
# 构建号（CFBundleVersion）= `git rev-list --count HEAD`，构建时注入、不写回 pbxproj；
# 历史是线性的，用 `git rev-list --reverse HEAD | sed -n '{构建号}p'` 反查提交。
# 工作区不干净时构建号对不上实际代码，默认拒绝；确需临时装一版用 --allow-dirty。
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

# --- 3. 定位构建产物与版本号 -------------------------------------------------
PRODUCTS_DIR="$(/usr/bin/xcodebuild -scheme "${SCHEME}" -configuration "${CONFIG}" \
        -destination "${DESTINATION}" -showBuildSettings 2>/dev/null \
    | /usr/bin/awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
SRC="${PRODUCTS_DIR}/${APP_NAME}"
if [[ ! -d "${SRC}" ]]; then
    echo "error: 找不到构建产物 ${SRC}" >&2
    exit 1
fi
# 版本号从产物自己的 Info.plist 读，--no-build 时也与实际打进去的 App 一致。
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${SRC}/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${SRC}/Contents/Info.plist")"
/usr/bin/codesign --verify --strict "${SRC}"
echo "源: ${SRC}（版本 ${VERSION}，构建号 ${BUILD}）"

# --- 4. 组装 DMG 内容 --------------------------------------------------------
# 拷贝出来的 App 已经自包含，不需要任何后处理。
STAGE="$(/usr/bin/mktemp -d -t lumaplayer-dmg)"
trap '/bin/rm -rf "${STAGE}"' EXIT
# -L 解引用：Release 产物里可能含符号链接，不解开会拷出指向构建目录的坏链接。
/bin/cp -R -L "${SRC}" "${STAGE}/"
/bin/ln -s /Applications "${STAGE}/Applications"

# --- 5. 生成、签名、校验 -----------------------------------------------------
OUT_DIR="${REPO_ROOT}/build"
OUT="${OUT_DIR}/${VOLNAME}-${VERSION}-${BUILD}.dmg"
/bin/mkdir -p "${OUT_DIR}"
/bin/rm -f "${OUT}"
# hdiutil 会提示 create/attach 已弃用、建议改用 diskutil image，这是信息性输出，功能正常。
/usr/bin/hdiutil create -volname "${VOLNAME}" -srcfolder "${STAGE}" \
    -fs APFS -format UDZO -ov "${OUT}" >/dev/null
/usr/bin/codesign -s "${SIGN_IDENTITY}" --timestamp=none "${OUT}"
/usr/bin/hdiutil verify "${OUT}" >/dev/null 2>&1
/usr/bin/codesign --verify "${OUT}"

echo "已生成: ${OUT}"
/usr/bin/shasum -a 256 "${OUT}"
