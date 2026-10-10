#!/bin/bash
#
# build-rust-core.sh
#
# 编译 RustCore/ 里的 Rust 核心，并用 UniFFI 生成 Swift 绑定，装到四处：
#
#   RustCore/prefix/lib/libluma_core.a          ← 静态库，由 App 链进主二进制
#   RustCore/prefix/include/luma_coreFFI.h      ← UniFFI 生成的 C 头
#   RustCore/prefix/include/module.modulemap    ← Swift 靠它 import luma_coreFFI
#   LumaPlayer/Generated/luma_core.swift        ← 生成的 Swift 绑定
#
# ⚠️ modulemap 必须叫 `module.modulemap`，⛔ 不能保留 uniffi 生成的
#    `luma_coreFFI.modulemap` 这个名字（2026-10-10 实测）：
#      Clang 只会在 include 目录里隐式发现 `module.modulemap`，`<名字>.modulemap`
#      这个约定**不成立** ——
#        clang -fmodules -fimplicit-module-maps -I <dir> -fsyntax-only  → "module not found"
#      而 Xcode 走显式模块构建，会给 Clang 传 `-fno-implicit-module-maps`，
#      隐式发现被彻底关掉，只能靠扫描器按 `module.modulemap` 建显式模块图。
#      改名后同一目录下仍能正常隐式发现（都实测过）。
#
# 产物为什么分散在两处（见 docs/DECISIONS/rust-core-xcode-integration.md）：
#
#   * .a / .h / module.modulemap **不能**放进 LumaPlayer/ —— 同步文件夹会把它们
#     当成资源收进 App bundle。它们由 project.pbxproj 指过来：
#       - OTHER_LDFLAGS     → .a
#       - HEADER_SEARCH_PATHS → Clang 侧找 modulemap（**必须**，否则扫描器看不到）
#       - SWIFT_INCLUDE_PATHS → Swift 侧的 import 路径
#
#   * 生成的 .swift **必须**放进 LumaPlayer/ —— 同步文件夹会让它自动进编译，
#     不需要改 project.pbxproj。这是刻意利用既有机制，不是妥协。
#
# 用 staticlib 而不是 dylib：链进主二进制，不需要像 libmpv 那样再写一个
# 「把 48 个依赖塞进 Frameworks/ 并改 @rpath」的后处理脚本。
# （cdylib 也编，但只给 uniffi-bindgen 的 --library 模式读元数据用，不分发。）
#
# 用法：
#   ./Scripts/build-rust-core.sh
#
# 依赖（本机需先装）：Rust 工具链。用 rustup 官方安装器装到 ~/.cargo：
#
#   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
#
# ⛔ 不要用 `brew install rust`：它会拖 llvm / libgit2 等 6 个大依赖。
# ⛔ 也不要用 `brew install rustup`：实测在本机装不上 —— Homebrew 会给安装过程套一层
#    sandbox-exec，而嵌套沙箱会被 macOS 拒绝（sandbox_apply: Operation not permitted）。
#
# ⚠️ 与 libmpv 一样的纪律：**新克隆的仓库必须先跑一次本脚本**，否则
#    LumaPlayer/Generated/ 是空的，App 编不过（找不到 luma_core 的类型）。
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUST_CORE="${REPO_ROOT}/RustCore"
PREFIX="${RUST_CORE}/prefix"
GENERATED_SWIFT_DIR="${REPO_ROOT}/LumaPlayer/Generated"
NAMESPACE="luma_core"

CARGO="${CARGO:-${HOME}/.cargo/bin/cargo}"

# --- 0. 预检 -----------------------------------------------------------------
if [[ ! -x "${CARGO}" ]]; then
    if command -v cargo >/dev/null 2>&1; then
        CARGO="$(command -v cargo)"
    else
        echo "error: 找不到 cargo（找过 ${CARGO}）" >&2
        echo "       先装 Rust 工具链：" >&2
        echo "       curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal" >&2
        exit 1
    fi
fi

# uniffi-bindgen 内部会自己 spawn 一个 `cargo metadata`（它不看我们解析出的
# 绝对路径），所以 cargo 所在的目录**必须**在 PATH 上。装在最常见的
# ~/.cargo/bin 时，一个非登录 shell 里常常没有它 —— 不补这一步就会报
# "failed to start `cargo metadata`: No such file or directory"。
export PATH="$(/usr/bin/dirname "${CARGO}"):${PATH}"

# --- 1. 编译 -----------------------------------------------------------------
echo "编译 Rust 核心（cargo build --release）…"
"${CARGO}" build --release --manifest-path "${RUST_CORE}/Cargo.toml"

# --- 2. 生成 Swift 绑定 ------------------------------------------------------
# 用 workspace 自带的 uniffi-bindgen，而不是 `cargo install uniffi-bindgen`：
# 生成器的版本与 luma-ffi 依赖的 uniffi 版本就此锁死，不会生成对不上的绑定。
BINDGEN="${RUST_CORE}/target/release/uniffi-bindgen"
[[ -x "${BINDGEN}" ]] || { echo "error: 没生成 ${BINDGEN}" >&2; exit 1; }

SHARED_LIB="${RUST_CORE}/target/release/lib${NAMESPACE}.dylib"
[[ -f "${SHARED_LIB}" ]] || { echo "error: 没生成 ${SHARED_LIB}" >&2; exit 1; }

BINDGEN_OUT="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "${BINDGEN_OUT}"' EXIT

echo "生成 Swift 绑定（uniffi-bindgen --library）…"
# --library 模式：直接从编好的库里读元数据，不需要额外的 .udl 文件。
# ⚠️ 必须 cd 到 RustCore/ 再跑：bindgen 内部会调 `cargo metadata`，
#    在仓库根执行会报 "could not find Cargo.toml"。
(
    cd "${RUST_CORE}"
    "${BINDGEN}" generate \
        --library "${SHARED_LIB}" \
        --language swift \
        --out-dir "${BINDGEN_OUT}"
)

# --- 3. 安装 -----------------------------------------------------------------
echo "安装到 RustCore/prefix 与 LumaPlayer/Generated …"
/bin/mkdir -p "${PREFIX}/lib" "${PREFIX}/include" "${GENERATED_SWIFT_DIR}"

/bin/cp "${RUST_CORE}/target/release/lib${NAMESPACE}.a" "${PREFIX}/lib/"
/bin/cp "${BINDGEN_OUT}/${NAMESPACE}FFI.h" "${PREFIX}/include/"
# 改成 module.modulemap（理由见文件头）。同时清掉旧名字的残留，
# 免得扫描器在一个目录里看到两份 module map。
/bin/rm -f "${PREFIX}/include/${NAMESPACE}FFI.modulemap"
/bin/cp "${BINDGEN_OUT}/${NAMESPACE}FFI.modulemap" "${PREFIX}/include/module.modulemap"
/bin/cp "${BINDGEN_OUT}/${NAMESPACE}.swift" "${GENERATED_SWIFT_DIR}/"

# --- 4. 自检 -----------------------------------------------------------------
A_LIB="${PREFIX}/lib/lib${NAMESPACE}.a"
MODULEMAP="${PREFIX}/include/module.modulemap"
SWIFT_OUT="${GENERATED_SWIFT_DIR}/${NAMESPACE}.swift"

for f in "${A_LIB}" "${PREFIX}/include/${NAMESPACE}FFI.h" "${MODULEMAP}" "${SWIFT_OUT}"; do
    [[ -f "${f}" ]] || { echo "error: 缺少产物 ${f}" >&2; exit 1; }
done

# modulemap 里声明的 module 名必须与生成的 Swift 里 import 的一致。
if ! /usr/bin/grep -q "module ${NAMESPACE}FFI" "${MODULEMAP}"; then
    echo "error: ${MODULEMAP} 里没有 'module ${NAMESPACE}FFI'" >&2
    exit 1
fi

# 生成的 Swift 必须 import modulemap 里的那个 module，否则 SWIFT_INCLUDE_PATHS 白配。
if ! /usr/bin/grep -q "import ${NAMESPACE}FFI" "${SWIFT_OUT}"; then
    echo "error: ${SWIFT_OUT} 里没有 'import ${NAMESPACE}FFI'" >&2
    exit 1
fi

echo
echo "产物："
echo "  $(/usr/bin/lipo -archs "${A_LIB}")  lib${NAMESPACE}.a  $(/usr/bin/du -h "${A_LIB}" | /usr/bin/cut -f1)"
echo "  $(/usr/bin/basename "${SWIFT_OUT}")  $(/usr/bin/wc -l < "${SWIFT_OUT}" | /usr/bin/tr -d ' ') 行"
echo
echo "OK: Rust 核心已就绪。"
