#!/bin/bash
#
# bundle-libmpv.sh
#
# 把 LumaPlayer.app 依赖的 libmpv 及其全部传递依赖拷进
# Contents/Frameworks/，引用改成 @rpath，再逐个重签名。
# 处理后的 App 不再需要目标机安装 Homebrew / mpv（方案 B）。
#
# ⚠️ 有两个依赖根：
#   1. /opt/homebrew —— libmpv 的全部传递依赖（ffmpeg / libplacebo / …）；
#   2. Vendor/mpv/prefix —— **自编**的 libmpv 本体（Scripts/build-libmpv.sh 产物，
#      带 gpu-next 渲染后端，见 docs/DECISIONS/gpu-next-render-backend.md）。
#   主程序里 LC_LOAD_DYLIB 指向第 2 个根的绝对路径，其余依赖都在第 1 个根。
#
# 用法：
#   ./Scripts/bundle-libmpv.sh <path/to/LumaPlayer.app>
#
# ⚠️ 会原地修改传入的 App。只对拷贝出来的 App 用（make-dmg.sh 的暂存目录、
# /Applications 下的安装副本），不要直接改 DerivedData 里的构建产物 ——
# 那份还要给 Debug 运行和测试用，它们按方案 A 直接链接仓库内的绝对路径。
#
set -euo pipefail

SIGN_IDENTITY="-"   # ad-hoc
BREW_PREFIX="/opt/homebrew"
VENDOR_PREFIX="$(cd "$(dirname "$0")/.." && pwd)/Vendor/mpv/prefix"

APP="${1:-}"
if [[ -z "${APP}" || ! -d "${APP}/Contents/MacOS" ]]; then
    echo "用法: $0 <path/to/LumaPlayer.app>" >&2
    exit 64
fi
APP="$(cd "${APP}" && pwd)"
EXE="${APP}/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "${APP}/Contents/Info.plist")"
FW="${APP}/Contents/Frameworks"
/bin/mkdir -p "${FW}"

# 列出一个 Mach-O 引用的、位于任一依赖根下的 dylib（跳过 dylib 自己的 id 行）。
# 两个根都要收：自编的 libmpv 在 Vendor/mpv/prefix，其余依赖在 Homebrew。
bundled_deps() {
    local id
    id="$(/usr/bin/otool -D "$1" | /usr/bin/sed -n 2p)"
    /usr/bin/otool -L "$1" | /usr/bin/tail -n +2 \
        | /usr/bin/awk '{print $1}' \
        | /usr/bin/grep -E "^(${BREW_PREFIX}|${VENDOR_PREFIX})/" \
        | { [[ -n "${id}" ]] && /usr/bin/grep -vxF "${id}" || /bin/cat; } || true
}

# 列出一个 Mach-O 的全部 LC_RPATH。
rpaths() {
    /usr/bin/otool -l "$1" | /usr/bin/awk '/cmd LC_RPATH/{r=1} r && / path /{print $2; r=0}'
}

# --- 1. 沿依赖图收集并拷贝 ---------------------------------------------------
# 以引用路径的文件名（即 install name 的 basename，如 libavcodec.63.dylib）命名，
# 而不是解开符号链接后的真实文件名（libavcodec.63.1.102.dylib）—— 引用方认的是前者。
echo "收集依赖（Homebrew + 自编 libmpv）…"
queue=("${EXE}")
while ((${#queue[@]})); do
    cur="${queue[0]}"
    queue=("${queue[@]:1}")
    while IFS= read -r dep; do
        [[ -z "${dep}" ]] && continue
        name="$(/usr/bin/basename "${dep}")"
        dst="${FW}/${name}"
        [[ -e "${dst}" ]] && continue
        src="$(/bin/realpath "${dep}")"
        /bin/cp "${src}" "${dst}"
        /bin/chmod u+w "${dst}"
        queue+=("${dst}")
    done < <(bundled_deps "${cur}")
done

# --- 2. 改写 install name / 引用 / rpath ------------------------------------
# install_name_tool 改完会让原签名失效并打印 warning，这是预期的，第 4 步统一重签。
echo "改写加载路径…"
rewrite() {
    local f="$1" is_dylib="$2" args=() dep rp
    if [[ "${is_dylib}" == 1 ]]; then
        args+=(-id "@rpath/$(/usr/bin/basename "${f}")")
    fi
    while IFS= read -r dep; do
        [[ -n "${dep}" ]] && args+=(-change "${dep}" "@rpath/$(/usr/bin/basename "${dep}")")
    done < <(bundled_deps "${f}")
    # 删掉指向依赖根 / Xcode 的 rpath：留着的话在开发机上会悄悄回退去加载
    # 仓库内或 Homebrew 那份，打包缺库也照样能跑，问题就被掩盖了。
    while IFS= read -r rp; do
        case "${rp}" in
            "${BREW_PREFIX}"/*|"${VENDOR_PREFIX}"/*|/Applications/Xcode*|@loader_path/../lib) args+=(-delete_rpath "${rp}") ;;
        esac
    done < <(rpaths "${f}")
    if [[ "${is_dylib}" == 1 ]] && ! rpaths "${f}" | /usr/bin/grep -qxF '@loader_path'; then
        args+=(-add_rpath '@loader_path')
    fi
    if ((${#args[@]})); then
        /usr/bin/install_name_tool "${args[@]}" "${f}" 2>/dev/null
    fi
}
for lib in "${FW}"/*.dylib; do
    rewrite "${lib}" 1
done
rewrite "${EXE}" 0
if ! rpaths "${EXE}" | /usr/bin/grep -qxF '@executable_path/../Frameworks'; then
    echo "error: 主程序缺少 @executable_path/../Frameworks 这条 rpath" >&2
    exit 1
fi

# --- 3. 自检：包内不得再有任何指向依赖根的加载路径 ---------------------------
leaks=0
for f in "${EXE}" "${FW}"/*.dylib; do
    if /usr/bin/otool -L "${f}" | /usr/bin/tail -n +2 | /usr/bin/grep -qE "^[[:space:]]*(${BREW_PREFIX}|${VENDOR_PREFIX})/" \
        || rpaths "${f}" | /usr/bin/grep -qE "^(${BREW_PREFIX}|${VENDOR_PREFIX})/"; then
        echo "error: ${f##*/} 仍引用依赖根（${BREW_PREFIX} 或 Vendor/mpv/prefix）" >&2
        leaks=1
    fi
done
((leaks == 0)) || exit 1

# --- 4. 重签名：先签每个 dylib，最后签 App -----------------------------------
# App 签名时保留原有的 entitlements / DR / flags，不在这里另起一套配置。
# 每个文件都会打一行「replacing existing signature」，是预期的，滤掉；其他 stderr 照常输出。
echo "重签名…"
/usr/bin/codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none "${FW}"/*.dylib \
    2> >(/usr/bin/grep -v 'replacing existing signature' >&2)
/usr/bin/codesign --force --sign "${SIGN_IDENTITY}" --timestamp=none \
    --preserve-metadata=identifier,entitlements,requirements,flags "${APP}" \
    2> >(/usr/bin/grep -v 'replacing existing signature' >&2)
/usr/bin/codesign --verify --strict --deep "${APP}"

count="$(/bin/ls "${FW}"/*.dylib | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
size="$(/usr/bin/du -sh "${FW}" | /usr/bin/cut -f1)"
echo "已打入 ${count} 个 dylib（${size}），签名校验通过。"
