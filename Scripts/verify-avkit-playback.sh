#!/bin/bash
#
# verify-avkit-playback.sh
#
# 编译并运行 `Scripts/verify-avkit-playback.swift` —— 一个独立可执行文件,
# 用**真的**播放内核(`AVKitPlaybackKernel`)把三段片源真播一遍:
#
#   ① 本地 mp4
#   ② Emby DirectStream
#   ③ Emby Transcode(含带 StartTimeTicks 的重新起流)
#   外加一个**真负例**:MP4 里的 DTS 音轨会被 AVFoundation 静默删掉,
#   内核必须报错而不是安静地播下去。
#
# 它编译的是 App target 里的**同一份源文件**(不是复制品),
# 决策也真过 Rust 的 FFI 边界,所以它同时是「内核能不能编过」与「内核能不能播」的证据。
#
# 为什么不用 `xcodebuild test`:本机 `sandbox_apply` 对所有 deny-default 沙箱都返回
# `Operation not permitted`,带 app-sandbox 的 App 进程启动阶段即 SIGTRAP,测试宿主
# 建立不了连接(`docs/KNOWN_ISSUES.md` Q34)。
# ⛔ 它**不替代** `LumaPlayerTests/` 下的 XCTest —— 能跑测试宿主的机器上两边都要跑。
#
# 前置(缺一样都会在这里的预检里报出来):
#   1. `./Scripts/build-rust-core.sh`        (RustCore/prefix 与 Generated/)
#   2. `./Scripts/probe-avkit-capability.sh` (本地起播样本在 build/avkit-probe/)
#   3. Tools/emby-dev 的实例在跑(127.0.0.1:8096)
#      账号用环境变量覆盖:LUMA_EMBY_USER / LUMA_EMBY_PASS
#
# 用法(仓库根):
#   ./Scripts/verify-avkit-playback.sh
#   ./Scripts/verify-avkit-playback.sh http://127.0.0.1:8096 build/avkit-probe

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

BASE_URL="${1:-http://127.0.0.1:8096}"
SAMPLE_DIR="${2:-build/avkit-probe}"

INCLUDE_DIR="${REPO_ROOT}/RustCore/prefix/include"
STATIC_LIB="${REPO_ROOT}/RustCore/prefix/lib/libluma_core.a"
GENERATED_SWIFT="${REPO_ROOT}/LumaPlayer/Generated/luma_core.swift"

for f in "${STATIC_LIB}" "${INCLUDE_DIR}/module.modulemap" "${GENERATED_SWIFT}"; do
    if [[ ! -f "${f}" ]]; then
        echo "error: 缺少 ${f}" >&2
        echo "       先跑一次 ./Scripts/build-rust-core.sh" >&2
        exit 1
    fi
done

if [[ ! -f "${SAMPLE_DIR}/base-h264-aac.mp4" || ! -f "${SAMPLE_DIR}/a-h264-dts.mp4" ]]; then
    echo "error: ${SAMPLE_DIR} 里缺本地起播样本" >&2
    echo "       先跑一次 ./Scripts/probe-avkit-capability.sh" >&2
    exit 1
fi

# 只读探一次实例:不通就直接说清,别让下面的登录报一个看不懂的状态码
if ! /usr/bin/curl -s -m 3 -o /dev/null "${BASE_URL}/System/Info/Public" \
     && ! /usr/bin/curl -s -m 3 -o /dev/null "${BASE_URL}/emby/System/Info/Public"; then
    echo "error: 连不上 ${BASE_URL}" >&2
    echo "       本地开发实例见 Tools/emby-dev/README.md(三条命令起一台)" >&2
    exit 1
fi

# 编译清单 = App target 里被这条链路用到的**源文件本体**。
# ⛔ 不要在这里复制一份实现:那样验的就不是应用要跑的东西了。
SOURCES=(
    "${GENERATED_SWIFT}"
    "${REPO_ROOT}/LumaPlayer/Core/Playback/PlaybackDecisionEngine.swift"
    "${REPO_ROOT}/LumaPlayer/Core/Playback/PlaybackPlanBuilder.swift"
    "${REPO_ROOT}/LumaPlayer/Core/Playback/PlaybackRules.swift"
    "${REPO_ROOT}/LumaPlayer/Core/Playback/PlaybackTrack.swift"
    "${REPO_ROOT}/LumaPlayer/Core/Playback/PlaybackURLBuilder.swift"
    "${REPO_ROOT}/LumaPlayer/Core/Playback/TickConverter.swift"
    "${REPO_ROOT}/LumaPlayer/Core/Playback/TrackExpectation.swift"
    "${REPO_ROOT}/LumaPlayer/Core/Security/SecretRedactor.swift"
    "${REPO_ROOT}/LumaPlayer/Components/DesignTokens.swift"
    "${REPO_ROOT}/LumaPlayer/Models/EmbyChapter.swift"
    "${REPO_ROOT}/LumaPlayer/Models/EmbyMediaSource.swift"
    "${REPO_ROOT}/LumaPlayer/Models/EmbyPlaybackInfo.swift"
    "${REPO_ROOT}/LumaPlayer/Models/PlaybackSession.swift"
    "${REPO_ROOT}/LumaPlayer/Features/Player/AVKitPlaybackKernel.swift"
    "${REPO_ROOT}/Scripts/verify-avkit-playback.swift"
)

BIN="$(/usr/bin/mktemp -d)/verify-avkit-playback"
trap '/bin/rm -rf "$(/usr/bin/dirname "${BIN}")"' EXIT

echo "编译自检程序(swiftc,不经 XCTest 宿主)…"
/usr/bin/xcrun swiftc -swift-version 6 \
    -o "${BIN}" \
    "${SOURCES[@]}" \
    -I "${INCLUDE_DIR}" \
    "${STATIC_LIB}"

echo
"${BIN}" "${BASE_URL}" "${SAMPLE_DIR}"
