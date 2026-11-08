#!/bin/bash
#
# run-debug.sh —— 增量构建 Debug 版并直接启动,不需要开 Xcode。
#
# 用法(任意目录):./Scripts/run-debug.sh [--no-build] [--verbose]
#   --no-build  跳过编译,直接启动最近一次的 Debug 产物
#   --verbose   把 xcodebuild 的完整输出打到终端(默认只在失败时打印 error:)
#
# 和 deploy-to-applications.sh 的分工:那条是 Release + bundle-libmpv.sh 打包 + 装到
# /Applications,验证的是「产物脱离仓库也能跑」;日常功能验证用这条就够 —— Debug 产物直接
# 链接 Vendor/mpv/prefix 里的 libmpv(PITFALLS.md 第 1 节),不经过打包脚本。
#
# ⚠️ 必须先退出旧的 Debug 实例再 open:open 只负责「激活到前台」,不会重新加载可执行文件,
# 同路径下它会把还在跑的旧进程拉到前面,让人误以为改动没生效。
#
set -euo pipefail

REPO_ROOT="$(/bin/realpath "$(dirname "$0")/..")"
SCHEME="LumaPlayer"
CONFIG="Debug"
DESTINATION="platform=macOS,arch=arm64"
APP_NAME="LumaPlayer.app"
EXE_NAME="LumaPlayer"

cd "${REPO_ROOT}"

NO_BUILD=0
VERBOSE=0
for arg in "$@"; do
    case "${arg}" in
        --no-build) NO_BUILD=1 ;;
        --verbose)  VERBOSE=1 ;;
        -h|--help)
            /usr/bin/sed -n '3,16p' "$0"
            exit 0 ;;
        *) echo "error: 未知参数 ${arg}" >&2; exit 2 ;;
    esac
done

# --- 1. 依赖前置:新克隆要先把 prefix 还原出来 -------------------------------
# 链接的是 Vendor/mpv/prefix/lib/libmpv.2.dylib,缺了构建会以一条难懂的 ld 错误失败。
if [[ ! -f "${REPO_ROOT}/Vendor/mpv/prefix/lib/libmpv.2.dylib" ]]; then
    echo "error: 缺少 Vendor/mpv/prefix/lib/libmpv.2.dylib" >&2
    echo "       先跑一次 ./Scripts/build-libmpv.sh 还原(新克隆只需一次)。" >&2
    exit 1
fi

# --- 2. 增量构建 -------------------------------------------------------------
# 构建失败必须立刻停:继续往下会 open 上一次的旧产物,看起来一切正常,实际验证的是旧代码。
if [[ "${NO_BUILD}" == 0 ]]; then
    echo "构建 ${SCHEME} (${CONFIG})…"
    LOG="$(/usr/bin/mktemp -t lumaplayer-debug-build)"
    # 判定看 xcodebuild 自己的退出码,不看输出结尾(README「构建」);set -e 下要先摘掉 e。
    set +e
    if [[ "${VERBOSE}" == 1 ]]; then
        /usr/bin/xcodebuild -scheme "${SCHEME}" -configuration "${CONFIG}" \
            -destination "${DESTINATION}" build 2>&1 | /usr/bin/tee "${LOG}"
        rc="${PIPESTATUS[0]}"
    else
        /usr/bin/xcodebuild -scheme "${SCHEME}" -configuration "${CONFIG}" \
            -destination "${DESTINATION}" build >"${LOG}" 2>&1
        rc=$?
    fi
    set -e
    if [[ "${rc}" != 0 ]]; then
        # 只挑 error: 行;没有就退回结尾,避免把几千行日志灌给用户。
        if ! /usr/bin/grep -E 'error:' "${LOG}"; then
            /usr/bin/tail -30 "${LOG}"
        fi
        # 日志留在原地,方便直接打开看;成功时才删。
        echo "error: 构建失败(完整日志: ${LOG})。" >&2
        echo "       没有启动任何实例:避免把上一次的旧产物当成这次的验证结果。" >&2
        exit 1
    fi
    /bin/rm -f "${LOG}"
    [[ "${VERBOSE}" == 1 ]] || echo "构建成功。"
fi

# --- 3. 定位产物 -------------------------------------------------------------
PRODUCTS_DIR="$(/usr/bin/xcodebuild -scheme "${SCHEME}" -configuration "${CONFIG}" \
        -destination "${DESTINATION}" -showBuildSettings 2>/dev/null \
    | /usr/bin/awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
APP="${PRODUCTS_DIR}/${APP_NAME}"
if [[ ! -d "${APP}" ]]; then
    echo "error: 找不到构建产物 ${APP}" >&2
    echo "       去掉 --no-build 重新编译一次。" >&2
    exit 1
fi

# --- 4. 退出旧的 Debug 实例(/Applications 里的安装版不动)--------------------
# 两份是同一个 bundle id、同一个进程名,只能靠可执行文件路径区分。
# 注意 ps 在 /bin/ps,不是 /usr/bin/ps(写错会让这里永远取不到路径,静默跳过重启)。
all_pids() {
    /usr/bin/pgrep -x "${EXE_NAME}" 2>/dev/null || true
}
debug_pids() {
    local pid path
    for pid in $(all_pids); do
        path="$(/bin/ps -o command= -p "${pid}" 2>/dev/null || true)"
        case "${path}" in
            "${PRODUCTS_DIR}/"*|*"/DerivedData/"*) echo "${pid}" ;;
        esac
    done
}

DEAD_PIDS="$(debug_pids | /usr/bin/tr '\n' ' ')"
if [[ -n "${DEAD_PIDS// /}" ]]; then
    # 只有「在跑的全是 Debug 实例」时才走 AppleScript 优雅退出:它按 App 名字找目标,
    # 分不清两份,会把 /Applications 那份一起关掉。优雅退出能让播放收尾把进度报完。
    if [[ "$(all_pids | /usr/bin/tr '\n' ' ')" == "${DEAD_PIDS}" ]]; then
        echo "退出旧实例(PID ${DEAD_PIDS})…"
        /usr/bin/osascript -e 'quit app "LumaPlayer"' >/dev/null 2>&1 || true
    else
        echo "退出旧 Debug 实例(PID ${DEAD_PIDS}),保留 /Applications 里的安装版…"
        # shellcheck disable=SC2086
        /bin/kill -TERM ${DEAD_PIDS} 2>/dev/null || true
    fi
    # 等进程真的消失:0.5s × 20 = 最多 10s,超时再补 SIGKILL。
    for _ in $(/usr/bin/seq 1 20); do
        [[ -n "$(debug_pids)" ]] || break
        /bin/sleep 0.5
    done
    LEFT="$(debug_pids | /usr/bin/tr '\n' ' ')"
    if [[ -n "${LEFT// /}" ]]; then
        # shellcheck disable=SC2086
        /bin/kill -KILL ${LEFT} 2>/dev/null || true
        /bin/sleep 1
    fi
fi

# 两份共用同一个沙盒容器(~/Library/Containers/com.local.LumaPlayer),同时跑会抢同一批
# 凭据文件与缓存。不阻止,但要让人知道看到的状态可能不是这份 Debug 版写的。
if [[ -n "$(all_pids)" ]]; then
    echo "warning: /Applications 里的 LumaPlayer 仍在运行;两份共用同一沙盒容器," >&2
    echo "         凭据 / 缓存可能互相干扰,建议先退出安装版。" >&2
fi

# --- 5. 启动 -----------------------------------------------------------------
if ! /usr/bin/open "${APP}"; then
    echo "error: 启动失败: ${APP}" >&2
    exit 1
fi
/bin/sleep 2
PID="$(debug_pids | /usr/bin/head -1)"
if [[ -z "${PID}" ]]; then
    echo "error: open 返回成功,但没有看到新的 Debug 实例。" >&2
    echo "       可能有同 bundle id 的实例占位;手动确认后重试。" >&2
    exit 1
fi
echo "已启动(PID ${PID}): ${APP}"
