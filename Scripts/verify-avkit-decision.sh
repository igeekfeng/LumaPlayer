#!/bin/bash
#
# verify-avkit-decision.sh
#
# 编译并运行 `Scripts/verify-avkit-decision.swift` —— 一个独立可执行文件,
# 真调一遍 Rust 核心的 DeviceProfile / 决策接口,对着真实 fixture 断言结果。
#
# 为什么不用 `xcodebuild test`:
#   本机 `sandbox_apply` 对所有 deny-default 沙箱都返回 `Operation not permitted`,
#   带 app-sandbox 的 App 在进程启动阶段即 SIGTRAP,测试宿主建立不了连接
#   (`The test runner hung before establishing connection`)。
#   ⛔ 与项目代码无关,是环境问题(见 docs/KNOWN_ISSUES.md Q34)。
#
#   因此本脚本**不替代** `LumaPlayerTests/RustPlaybackDecisionTests.swift` ——
#   两者断言等价;能跑测试宿主的机器上,XCTest 是正路,本脚本只是这台机器上的
#   等价证据(与 P1 阶段那次 `swiftc` 边界自检同一手法)。
#
# 前置:先跑过 `Scripts/build-rust-core.sh`(需要 RustCore/prefix 与 Generated/)。
#
# 用法(仓库根):
#   ./Scripts/verify-avkit-decision.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

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

BIN="$(/usr/bin/mktemp -d)/verify-avkit-decision"
trap '/bin/rm -rf "$(/usr/bin/dirname "${BIN}")"' EXIT

echo "编译自检程序(swiftc,不经 XCTest 宿主)…"
/usr/bin/xcrun swiftc -swift-version 6 \
    -o "${BIN}" \
    "${GENERATED_SWIFT}" \
    "${REPO_ROOT}/Scripts/verify-avkit-decision.swift" \
    -I "${INCLUDE_DIR}" \
    "${STATIC_LIB}"

echo
"${BIN}"
