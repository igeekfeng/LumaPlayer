#!/bin/bash
#
# build-libmpv.sh —— 准备带 gpu-next 渲染后端的 libmpv,装到 Vendor/mpv/prefix/。
#
# 用法:
#   ./Scripts/build-libmpv.sh                 从 Vendor/mpv/prebuilt/ 的固化产物还原(默认,零额外工具)
#   ./Scripts/build-libmpv.sh --pack         在维护机上重新固化产物到 Vendor/mpv/prebuilt/
#   ./Scripts/build-libmpv.sh --from-source  从源码编译(维护者模式,需要构建工具与依赖库)
#   ./Scripts/build-libmpv.sh --force         仅对 --from-source 有效:连源码重新克隆
#                                            (build/ 每次都重配,--clean 等同默认,仍接受)
#   ./Scripts/build-libmpv.sh --help
#
# 固化产物 = libmpv 本体 + 全部传递依赖 dylib + 头文件,压成 tar.gz 随仓库分发。
# 包内 dylib 一律以 @rpath/<basename> 互引、带 @loader_path rpath,与机器路径无关。
# 还原时把 libmpv 的 install name 改成本仓库 prefix 的绝对路径(OTHER_LDFLAGS 按它链接),
# 再逐个 ad-hoc 重签:arm64 上 install_name_tool 改过的 dylib 签名失效,不重签会被 dyld 拒绝。
#
# 默认还原路径只用 /usr/bin 下的系统工具(shasum / tar / otool / install_name_tool /
# codesign),不依赖 Homebrew、meson、ninja、pkg-config,也不需要网络。
# LUMA_LIBMPV_BUNDLE 可覆盖产物来源:本地路径或 https URL(用 /usr/bin/curl 下载)。
# LUMA_MPV_PREFIX 可覆盖安装位置,用于把产物解到别处做隔离验证。
#
# 为什么要自编:Dolby Vision(P5)在老 gpu 渲染器上发紫发绿(它不处理 RPU/IPTPQc2),只有 gpu-next
# (libplacebo)做得对。而它进 render API 需要 mpv PR 16818,该 PR 至今未合并,上游正式版与
# Homebrew 的 mpv 都没有 MPV_RENDER_PARAM_BACKEND,所以只能把它作为补丁 0000 打在钉死的正式版上自己编。
#
set -euo pipefail

# realpath 取物理路径:libmpv 的 install name 会写进主程序,软链或大小写不同的路径会让 dyld 找不到它。
REPO_ROOT="$(/bin/realpath "$(dirname "$0")/..")"
VENDOR="${REPO_ROOT}/Vendor/mpv"
SRC_DIR="${VENDOR}/src"
BUILD_DIR="${VENDOR}/build"
PREFIX="${LUMA_MPV_PREFIX:-${VENDOR}/prefix}"
PREBUILT_DIR="${VENDOR}/prebuilt"
BUNDLE_NAME="libmpv-bundle.tar.gz"
BUNDLE="${PREBUILT_DIR}/${BUNDLE_NAME}"
SUMS="${PREBUILT_DIR}/SHA256SUMS"
BUNDLE_INFO="${PREBUILT_DIR}/BUNDLE_INFO"
# 还原会清空 PREFIX。只允许清空空目录或带本标记文件的目录(脚本自己写的),
# 避免 LUMA_MPV_PREFIX 指到 $HOME 之类的重要目录时被 rm -rf。
PREFIX_MARKER=".lumaplayer-prefix"

# 钉死 v0.42.0 tag 指向的 commit(按 sha 取,tag 被移动也不受影响)。源码模式用,BUNDLE_INFO 里也记它。
MPV_REPO="https://github.com/mpv-player/mpv.git"
MPV_SHA="b0841e8c4d156b8403dc1876c4cbd9011eb583f3"

MODE="restore"
CLEAN=0
FORCE=0
for arg in "$@"; do
    case "${arg}" in
        --pack)         MODE="pack" ;;
        --from-source)  MODE="source" ;;
        --clean)        CLEAN=1 ;;
        --force)        FORCE=1 ;;
        -h|--help)
            /usr/bin/sed -n '2,26p' "$0"
            echo
            echo "--from-source 是维护者模式:需要 meson / ninja / pkg-config 以及 ffmpeg、libplacebo、"
            echo "libass 等依赖库(本机由 Homebrew 提供)。它按 Vendor/mpv/patches/ 下的补丁重编一份,"
            echo "产物再用 --pack 固化;普通构建与新克隆不需要走这条路径。"
            exit 0 ;;
        *) echo "未知参数: ${arg}" >&2; exit 64 ;;
    esac
done
if [[ "${MODE}" != "source" && ( "${CLEAN}" == 1 || "${FORCE}" == 1 ) ]]; then
    echo "error: --clean / --force 只对 --from-source 有效" >&2
    exit 64
fi

# 到这里才建目录:--help / 参数错误不应有副作用。
/bin/mkdir -p "${PREFIX}" 2>/dev/null || { echo "error: 无法创建 ${PREFIX}" >&2; exit 1; }
PREFIX="$(/bin/realpath "${PREFIX}")"

# 防止误删:还原会清空 PREFIX。只允许空目录或带脚本标记文件的目录,且不得是 / 或仓库根。
if [[ "${MODE}" == "restore" ]]; then
    [[ "${PREFIX}" != "/" && "${PREFIX}" == */* && "${PREFIX}" != "${REPO_ROOT}" ]] || {
        echo "error: 拒绝在不安全的安装位置还原: ${PREFIX}" >&2; exit 1; }
    if [[ -n "$(/bin/ls -A "${PREFIX}" 2>/dev/null)" && ! -f "${PREFIX}/${PREFIX_MARKER}" ]]; then
        echo "error: ${PREFIX} 非空且没有 ${PREFIX_MARKER} 标记,拒绝清空。" >&2
        echo "       LUMA_MPV_PREFIX 只能指向空目录,或本脚本之前还原过的目录。" >&2
        exit 1
    fi
fi

for tool in /usr/bin/otool /usr/bin/install_name_tool /usr/bin/codesign /usr/bin/tar \
            /usr/bin/shasum /usr/bin/grep /bin/realpath; do
    [[ -x "${tool}" ]] || { echo "error: 缺少系统工具 ${tool}" >&2; exit 1; }
done

# 列出一个 Mach-O 的全部 LC_RPATH。
rpaths() {
    /usr/bin/otool -l "$1" | /usr/bin/awk '/cmd LC_RPATH/{r=1} r && / path /{print $2; r=0}'
}

# 输出 "<引用名>\t<源文件绝对路径>",供 --pack 逐层展开依赖图。
# 队列里放的是**原始文件**(不是包内副本):@rpath 要按原始位置解析,见 bundle-libmpv.sh。
# 系统库(/usr/lib、/System/Library)不收,它们随 macOS 提供。
collect_refs() {
    local src="$1" id dep ref name rp cand dir
    id="$(/usr/bin/otool -D "${src}" 2>/dev/null | /usr/bin/sed -n 2p)"
    dir="$(/usr/bin/dirname "${src}")"
    while IFS= read -r dep; do
        [[ -z "${dep}" || "${dep}" == "${id}" ]] && continue
        if [[ "${dep}" == /opt/homebrew/* || "${dep}" == "${PREFIX}"/lib/* ]]; then
            [[ -e "${dep}" ]] && /usr/bin/printf '%s\t%s\n' "$(/usr/bin/basename "${dep}")" "$(/bin/realpath "${dep}")"
        fi
    done < <(/usr/bin/otool -L "${src}" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')
    while IFS= read -r ref; do
        [[ -z "${ref}" || "${ref}" == "${id}" ]] && continue
        name="${ref#@rpath/}"
        while IFS= read -r rp; do
            cand="${rp/#@loader_path/${dir}}/${name}"
            if [[ -e "${cand}" ]]; then
                cand="$(/bin/realpath "${cand}")"
                [[ "${cand}" == /opt/homebrew/* || "${cand}" == "${PREFIX}"/lib/* ]] \
                    && /usr/bin/printf '%s\t%s\n' "${name}" "${cand}"
                break
            fi
        done < <(rpaths "${src}")
    done < <(/usr/bin/otool -L "${src}" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}' | /usr/bin/grep '^@rpath/' || true)
}

# 把一个目录里的 dylib 统一改写为自包含形态,并逐个 ad-hoc 重签。
relocate_lib_dir() {
    local dir="$1" f name dep rp args
    for f in "${dir}"/*.dylib; do
        [[ -e "${f}" ]] || continue
        name="$(/usr/bin/basename "${f}")"
        args=(-id "@rpath/${name}")
        while IFS= read -r dep; do
            [[ "${dep}" == /opt/homebrew/* || "${dep}" == "${PREFIX}"/lib/* ]] \
                && args+=(-change "${dep}" "@rpath/$(/usr/bin/basename "${dep}")")
        done < <(/usr/bin/otool -L "${f}" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}')
        while IFS= read -r rp; do
            case "${rp}" in
                /opt/homebrew*|"${PREFIX}"/lib*|@loader_path/../lib|/Applications/Xcode*) args+=(-delete_rpath "${rp}") ;;
            esac
        done < <(rpaths "${f}")
        rpaths "${f}" | /usr/bin/grep -qxF '@loader_path' || args+=(-add_rpath '@loader_path')
        /usr/bin/install_name_tool "${args[@]}" "${f}" 2>/dev/null
        /usr/bin/codesign --force --sign - --timestamp=none "${f}" 2>/dev/null
    done
}

verify_prefix() {
    local f
    [[ -f "${PREFIX}/lib/libmpv.2.dylib" ]] || { echo "error: 缺少 ${PREFIX}/lib/libmpv.2.dylib" >&2; exit 1; }
    [[ -f "${PREFIX}/include/mpv/render.h" ]] || { echo "error: 缺少 ${PREFIX}/include/mpv/render.h" >&2; exit 1; }
    # 这份 libmpv 的意义就在 MPV_RENDER_PARAM_BACKEND,缺了等于拿错产物。
    /usr/bin/grep -q "MPV_RENDER_PARAM_BACKEND" "${PREFIX}/include/mpv/render.h" || {
        echo "error: render.h 里没有 MPV_RENDER_PARAM_BACKEND —— 产物不含 gpu-next 后端" >&2; exit 1; }
    for f in "${PREFIX}"/lib/*.dylib; do
        if /usr/bin/otool -L "${f}" | /usr/bin/grep -qE '^[[:space:]]*/opt/homebrew/'; then
            echo "error: ${f##*/} 仍引用 /opt/homebrew" >&2
            exit 1
        fi
    done
}

# --- 默认:从固化产物还原 -----------------------------------------------------
if [[ "${MODE}" == "restore" ]]; then
    # 校验清单是所有分支(默认 / 本地路径 / URL)都要用的,先查,避免 URL 下载后
    # 才在 awk 里报「打不开文件」,掩盖脚本自己的错误信息。
    [[ -f "${SUMS}" ]] || { echo "error: 缺少校验清单 ${SUMS}" >&2; exit 1; }
    src="${LUMA_LIBMPV_BUNDLE:-}"
    downloaded=0
    dl_tmp=""
    if [[ -z "${src}" ]]; then
        src="${BUNDLE}"
    elif [[ "${src}" == http://* || "${src}" == https://* ]]; then
        echo "下载 ${src} …"
        [[ -x /usr/bin/curl ]] || { echo "error: 缺少 /usr/bin/curl" >&2; exit 1; }
        /bin/mkdir -p "${PREBUILT_DIR}"
        # 先下到临时文件、校验通过再替换仓库里的产物:校验失败时不能把已提交的好文件写成坏文件。
        dl_tmp="$(/usr/bin/mktemp -t lumaplayer-download)"
        trap '/bin/rm -f "${dl_tmp}" 2>/dev/null || true' EXIT
        /usr/bin/curl --fail --location --silent --show-error --retry 2 -o "${dl_tmp}" "${src}" || {
            echo "error: 下载失败" >&2; /bin/rm -f "${dl_tmp}"; exit 1; }
        want="$(/usr/bin/awk 'NR==1{print $1}' "${SUMS}")"
        got="$(/usr/bin/shasum -a 256 "${dl_tmp}" | /usr/bin/awk '{print $1}')"
        [[ "${want}" == "${got}" ]] || {
            echo "error: 下载产物的 sha256 与 SHA256SUMS 不符,仓库产物未改动" >&2
            /bin/rm -f "${dl_tmp}"; exit 1; }
        /bin/mv "${dl_tmp}" "${BUNDLE}"
        dl_tmp=""
        src="${BUNDLE}"
        downloaded=1
    fi
    [[ -f "${src}" ]] || {
        echo "error: 找不到固化产物 ${src}" >&2
        echo "       从别的机器拷一份,或设 LUMA_LIBMPV_BUNDLE=<路径|https URL>;" >&2
        echo "       也可在装有依赖的机器上跑 ./Scripts/build-libmpv.sh --pack 重新生成。" >&2
        exit 1; }
    if [[ "${downloaded}" == 0 ]]; then
        if [[ "${src}" == "${BUNDLE}" ]]; then
            ( cd "${PREBUILT_DIR}" && /usr/bin/shasum -a 256 -c SHA256SUMS ) >/dev/null || {
                echo "error: 产物 sha256 校验失败" >&2; exit 1; }
        else
            want="$(/usr/bin/awk 'NR==1{print $1}' "${SUMS}")"
            got="$(/usr/bin/shasum -a 256 "${src}" | /usr/bin/awk '{print $1}')"
            [[ "${want}" == "${got}" ]] || { echo "error: 产物 sha256 校验失败" >&2; exit 1; }
        fi
    fi

    echo "还原 ${src##*/} → ${PREFIX} …"
    /bin/rm -rf "${PREFIX}"
    /bin/mkdir -p "${PREFIX}"
    /usr/bin/tar -xzf "${src}" -C "${PREFIX}"
    # 标记这是脚本自己的产物目录,供下次还原时允许清空(见上面的保护条件)。
    /usr/bin/touch "${PREFIX}/${PREFIX_MARKER}"

    # 主程序按 OTHER_LDFLAGS 的绝对路径链接 libmpv,dyld 记的是它的 install name,
    # 所以这里改回本仓库的绝对路径;其余依赖靠 @rpath + @loader_path 在同目录自解析。
    LIB="${PREFIX}/lib/libmpv.2.dylib"
    /usr/bin/install_name_tool -id "${LIB}" "${LIB}" 2>/dev/null
    for f in "${PREFIX}"/lib/*.dylib; do
        /usr/bin/codesign --force --sign - --timestamp=none "${f}" 2>/dev/null
    done
    verify_prefix

    echo
    echo "产物:"
    /usr/bin/otool -D "${LIB}" | /usr/bin/sed -n '2s/^/  /p'
    echo "  lib/ 下 dylib: $(/bin/ls "${PREFIX}"/lib/*.dylib | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    echo
    echo "OK: libmpv 已就绪(含 gpu-next 渲染后端),未使用 Homebrew / meson / ninja / pkg-config。"
    exit 0
fi

# --- 维护者:重新固化产物 -----------------------------------------------------
if [[ "${MODE}" == "pack" ]]; then
    LIB="${PREFIX}/lib/libmpv.2.dylib"
    [[ -f "${LIB}" ]] || {
        echo "error: 先准备好 ${LIB}(还原产物或 --from-source 编译)" >&2; exit 1; }
    [[ -f "${PREFIX}/include/mpv/render.h" ]] || { echo "error: 缺少头文件" >&2; exit 1; }
    /usr/bin/grep -q "MPV_RENDER_PARAM_BACKEND" "${PREFIX}/include/mpv/render.h" || {
        echo "error: render.h 里没有 MPV_RENDER_PARAM_BACKEND" >&2; exit 1; }

    TMP="$(/usr/bin/mktemp -d -t lumaplayer-bundle)"
    trap '/bin/rm -rf "${TMP}"' EXIT
    /bin/mkdir -p "${TMP}/root/lib"
    /bin/cp -R "${PREFIX}/include" "${TMP}/root/include"
    /bin/cp "${LIB}" "${TMP}/root/lib/libmpv.2.dylib"
    /bin/chmod u+w "${TMP}/root/lib/libmpv.2.dylib"

    # 队列里放原始文件;按原始位置解析 @rpath,与 bundle-libmpv.sh 的收集逻辑一致。
    # 同时从每个 src 的 Cellar 物理路径记下 <formula>=<version>:记的是**实际打进包的库**,
    # 包括 ffmpeg 间接拉进来的 openssl / x264 / dav1d 等,且不会混入 meson 这类构建工具。
    queue=("${LIB}")
    seen=" libmpv.2.dylib "
    dep_pairs=""
    echo "收集依赖…"
    while ((${#queue[@]})); do
        cur="${queue[0]}"
        queue=("${queue[@]:1}")
        while IFS=$'\t' read -r name src; do
            [[ -z "${name}" ]] && continue
            [[ "${seen}" == *" ${name} "* ]] && continue
            [[ -e "${src}" ]] || { echo "error: 依赖不存在 ${src}" >&2; exit 1; }
            seen="${seen}${name} "
            if [[ "${src}" == *"/Cellar/"* ]]; then
                pair="$(/usr/bin/printf '%s' "${src}" \
                    | /usr/bin/sed -nE 's#.*/Cellar/([^/]+)/([^/]+)/.*#\1=\2#p')"
                [[ -n "${pair}" ]] && dep_pairs="${dep_pairs}${pair}"$'\n'
            fi
            dst="${TMP}/root/lib/${name}"
            /bin/cp "${src}" "${dst}"
            /bin/chmod u+w "${dst}"
            queue+=("${src}")
        done < <(collect_refs "${cur}")
    done

    echo "改写加载路径并重签…"
    relocate_lib_dir "${TMP}/root/lib"

    # 打包前自检:任何指向依赖根的绝对路径都不能留。
    for f in "${TMP}/root/lib"/*.dylib; do
        if /usr/bin/otool -L "${f}" | /usr/bin/grep -qE '^[[:space:]]*/opt/homebrew/'; then
            echo "error: ${f##*/} 仍引用 /opt/homebrew" >&2
            exit 1
        fi
    done

    # 产物要提交进仓库:任何 dylib 里都不得留本机路径(用户名)。
    for f in "${TMP}/root/lib"/*.dylib; do
        # 扫原始字节(strings 漏符号表);grep -c 读完整个文件,没有 SIGPIPE 问题。
        if [[ "$(/usr/bin/grep -acF "${HOME}" "${f}" || true)" != 0 ]]; then
            echo "error: ${f##*/} 里有本机路径(${HOME}),先用 --from-source 重编" >&2
            exit 1
        fi
    done

    /bin/mkdir -p "${PREBUILT_DIR}"
    # tar 头默认记属主用户名;改成 root:wheel,包里不带本机用户名(解包时普通用户会忽略属主)。
    /usr/bin/tar --uid 0 --gid 0 --uname root --gname wheel \
        -czf "${TMP}/${BUNDLE_NAME}" -C "${TMP}/root" include lib
    /bin/mv "${TMP}/${BUNDLE_NAME}" "${BUNDLE}"
    ( cd "${PREBUILT_DIR}" && /usr/bin/shasum -a 256 "${BUNDLE_NAME}" > SHA256SUMS )

    # deps 取自上面收集循环里每个 dylib 的 Cellar 物理路径,正是打进包的那些库;
    # 不看 build.ninja(它只列 mpv 直接依赖、混有构建工具、且可能与 prefix 不同步)。
    # ⚠️ 旧 deps= 必须在重定向块**之前**读:下面的 `{ } > "${BUNDLE_INFO}"` 一进来就会截断文件,
    # 块内再 grep 只能读到空文件。
    old_deps=""
    if [[ -f "${BUNDLE_INFO}" ]]; then
        old_deps="$(/usr/bin/grep -m1 '^deps=' "${BUNDLE_INFO}" || true)"
    fi
    {
        # dylibs 是包内 dylib 总数(含 libmpv 本体),传递依赖为 dylibs - 1。
        /usr/bin/printf 'mpv=%s\ntarget=macos27-arm64\ndylibs=%s\n' \
            "${MPV_SHA}" "$(/bin/ls "${TMP}/root/lib"/*.dylib | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
        if [[ -n "${dep_pairs}" ]]; then
            deps="$(/usr/bin/printf '%s' "${dep_pairs}" | /usr/bin/sort -u | /usr/bin/paste -sd, -)"
            /usr/bin/printf 'deps=%s\n' "${deps}"
        else
            # 从已还原的 prefix 重新固化时没有 Cellar 路径。保留旧 BUNDLE_INFO 里
            # 那条有效的 deps=,避免一次重新打包把正确的依赖记录冲成 unknown。
            if [[ -n "${old_deps}" && "${old_deps}" != *"(unknown"* ]]; then
                /usr/bin/printf '%s\n' "${old_deps}"
            else
                /usr/bin/printf 'deps=(unknown: no Cellar paths; packed from restored prefix)\n'
            fi
        fi
    } > "${BUNDLE_INFO}"

    echo
    echo "产物: ${BUNDLE} ($(/usr/bin/du -h "${BUNDLE}" | /usr/bin/awk '{print $1}'))"
    /bin/cat "${SUMS}"
    echo "把 ${PREBUILT_DIR} 下的文件提交进仓库,新克隆即可零依赖还原。"
    exit 0
fi

# --- 维护者:从源码编译 -------------------------------------------------------
# 这条路径只用于刷新固化产物,需要 meson / ninja / pkg-config 与依赖库(本机由 Homebrew 提供)。
BREW_PREFIX="/opt/homebrew"

missing=()
for tool in meson ninja pkg-config git clang otool; do
    command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
done
if ((${#missing[@]})); then
    echo "error: 缺少构建工具：${missing[*]}" >&2
    echo "       源码模式需要 meson / ninja / pkg-config 与 ffmpeg、libplacebo、libass 等依赖库" >&2
    exit 1
fi
if ! "${BREW_PREFIX}/bin/pkg-config" --exists libplacebo; then
    echo "error: 找不到 libplacebo(pkg-config)" >&2
    exit 1
fi
export PKG_CONFIG_PATH="${BREW_PREFIX}/lib/pkgconfig:${BREW_PREFIX}/opt/libarchive/lib/pkgconfig:${BREW_PREFIX}/opt/vulkan-loader/lib/pkgconfig:${BREW_PREFIX}/opt/vulkan-headers/lib/pkgconfig"

if ((FORCE)); then
    echo "强制重新克隆…"
    /bin/rm -rf "${SRC_DIR}"
fi
if [[ ! -d "${SRC_DIR}/.git" ]]; then
    echo "克隆 mpv 源码(钉死 ${MPV_SHA:0:12})…"
    /bin/mkdir -p "${SRC_DIR}"
    /usr/bin/git -C "${SRC_DIR}" init -q
    /usr/bin/git -C "${SRC_DIR}" remote add origin "${MPV_REPO}"
fi
/usr/bin/git -C "${SRC_DIR}" remote set-url origin "${MPV_REPO}"
/usr/bin/git -C "${SRC_DIR}" fetch --depth 1 origin "${MPV_SHA}"
# reset --hard 而非 checkout:src/ 是本脚本的产物,每次回到干净的钉死 commit 再打补丁。
# 补丁 0000 会新增文件,reset 不删未跟踪文件,必须再 clean,否则第二次 apply 报 already exists。
/usr/bin/git -C "${SRC_DIR}" reset -q --hard FETCH_HEAD
/usr/bin/git -C "${SRC_DIR}" clean -qfdx
echo "源码 HEAD: $(/usr/bin/git -C "${SRC_DIR}" rev-parse HEAD)"

# 本地补丁(Vendor/mpv/patches/*.patch,按文件名顺序):
#   0000  mpv PR 16818 的 head 80351bb3 移植到 v0.42.0:唯一冲突是 render.h 的枚举 ——
#         0.42 的 D3D11 render API 占了 21 / 22,MPV_RENDER_PARAM_BACKEND 从 21 挪到 23
#   0001  gpu-next 无视 FLIP_Y(画面上下颠倒)、渲染参数写死最近邻缩放且零初始化(运动画面闪烁)
#   0003  gpu-next 没注册硬解设备,hwdec=auto 退成 videotoolbox-copy(4K 每帧拷回内存,能耗高)
#   0005  init 失败后会调 uninit,但 init_audiounit 失败路径释放了 unit 不置空 → 二次释放
#   0006  v0.42.0 对 DV Profile 7 无条件拆出增强层(EL)并多开一个解码器,但只有 vo_gpu_next.c
#         会用它;0000 的精简渲染器把 EL 解完就丢。照 vo_gpu_next 把 FEL 的 EL 上传进
#         pl_frame.enhancement_layer(MEL 不上传,libplacebo 只按 nlq_active 合成)
# 编号不连续是有意的:文档与 PITFALLS.md 按编号引用。上游合并 16818 后删 0000、核对 BACKEND 编号。
for patch in "${VENDOR}"/patches/*.patch; do
    [[ -e "${patch}" ]] || continue
    echo "打补丁：$(/usr/bin/basename "${patch}")"
    /usr/bin/git -C "${SRC_DIR}" apply --whitespace=nowarn "${patch}"
done

# 产物要提交进仓库,不能带本机路径(用户名)。mpv 把 meson.build_options() 原样编进库
# (CONFIGURATION 字符串),所以带路径的参数都不能走 -D,各处来源与对策:
#   - C / ObjC 里 assert 的 __FILE__ → 环境变量 CFLAGS / OBJCFLAGS 加 -ffile-prefix-map
#     (环境变量不进 CONFIGURATION);
#   - Swift 编译经 bridging header 内联 misc/bstr.h,clang 按绝对 -I 路径记 __FILE__ →
#     -Xcc -ffile-prefix-map 只能经 swift-flags 选项传,放进 native file,并在 BUILD_DIR 里用
#     **相对路径**传给 meson setup,CONFIGURATION 里只出现文件名;
#   - -Dprefix 与 MPV_CONFDIR(<prefix>/etc/mpv)→ 用中性的 MESON_PREFIX 配置,装到临时
#     DESTDIR 再拷进 PREFIX。MPV_CONFDIR 指向不存在的目录,libmpv 不读配置文件,无影响。
# ⚠️ build/ 每次都整个重配(--clean 因此是默认行为):补丁 0000 改 meson.build,每次 reset + apply
# 都会让增量构建触发 meson 自动重新生成,重新生成时 native file 被记成绝对路径,又写回本机路径。
# 这也顺带免掉了「依赖升级后 meson 缓存的 Cellar 路径失效」的问题。
# 编完由下面的检查兜底:libmpv 里还有本机路径就失败。
MESON_PREFIX="/opt/lumaplayer/mpv"
NATIVE_FILE="lumaplayer-native.ini"
export CFLAGS="${CFLAGS:-} -ffile-prefix-map=${REPO_ROOT}/="
export OBJCFLAGS="${OBJCFLAGS:-} -ffile-prefix-map=${REPO_ROOT}/="
/bin/rm -rf "${BUILD_DIR}"
/bin/mkdir -p "${BUILD_DIR}"
/usr/bin/printf "[project options]\nswift-flags = '-Xcc -ffile-prefix-map=%s/='\n" "${REPO_ROOT}" \
    > "${BUILD_DIR}/${NATIVE_FILE}"

echo "meson setup …"
# -Dlibmpv=true 只出库(cplayer=false 不编 mpv 可执行文件)。
# gpl=true 与依赖里的 GPL ffmpeg 对齐;javascript/lua 保持 mpv 默认能力。
# libcurl 必须是 macOS 自带那份(/usr/lib/libcurl.4.dylib):tls-verify 默认开,系统 curl 用系统
# 证书库,沙盒里实测可用。缺了它网络流退回 ffmpeg + openssl,CA 路径落在依赖前缀下,
# 没装依赖库的机器上 HTTPS 全部失败 —— 所以写死 enabled,找不到就配置失败,不静默退化。
( cd "${BUILD_DIR}" && meson setup . "${SRC_DIR}" \
    --native-file "${NATIVE_FILE}" \
    --prefix="${MESON_PREFIX}" \
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
    -Dvapoursynth=disabled )

echo "编译 libmpv …"
meson compile -C "${BUILD_DIR}"

echo "安装到 ${PREFIX} …"
STAGE="$(/usr/bin/mktemp -d -t lumaplayer-mpv-stage)"
trap '/bin/rm -rf "${STAGE}"' EXIT
meson install -C "${BUILD_DIR}" --destdir "${STAGE}" >/dev/null
# 只替换 meson 装的 libmpv 与头文件。prefix 里若有还原留下的依赖 dylib 不动:
# 新编的 libmpv 链的是 Homebrew 那份,--pack 按 libmpv 的引用重新收集。
/bin/rm -rf "${PREFIX}/include/mpv" "${PREFIX}/lib/libmpv."*
/bin/mkdir -p "${PREFIX}/lib" "${PREFIX}/include"
/bin/cp -R "${STAGE}${MESON_PREFIX}/include/." "${PREFIX}/include/"
/bin/cp -R "${STAGE}${MESON_PREFIX}/lib/." "${PREFIX}/lib/"
# 标记这是脚本自己的产物目录,后续默认还原允许清空它。
/usr/bin/touch "${PREFIX}/${PREFIX_MARKER}"

LIB="${PREFIX}/lib/libmpv.2.dylib"
HEADER="${PREFIX}/include/mpv/render.h"
[[ -f "${LIB}" ]] || { echo "error: 没生成 ${LIB}" >&2; exit 1; }
# strip -S 删调试符号:链接器给 Swift 模块写了一条 N_AST stab,内容是 build/ 下 swiftmodule 的
# 绝对路径(在符号字符串表里,strings 扫不到)。导出符号不受影响。
/usr/bin/strip -S "${LIB}" 2>/dev/null
# install name 是 MESON_PREFIX 下的路径;改成本仓库 prefix,Debug 构建与测试按它加载。
/usr/bin/install_name_tool -id "${LIB}" "${LIB}" 2>/dev/null
/usr/bin/codesign --force --sign - --timestamp=none "${LIB}" 2>/dev/null
# 产物要进仓库:库里不得留本机路径(install name 除外,--pack 会改成 @rpath)。
# 用 grep -a 扫原始字节而不是 strings:后者漏符号表;先收进变量,pipefail 下 `| grep -q` 会因 SIGPIPE 判失败。
leaks="$(/usr/bin/grep -aoF "${HOME}" "${LIB}" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
if [[ "${leaks}" != 1 ]]; then
    echo "error: libmpv 里有 ${leaks} 处含 ${HOME} 的字节串(只允许 install name 那 1 处)" >&2
    exit 1
fi
/usr/bin/grep -q "MPV_RENDER_PARAM_BACKEND" "${HEADER}" || {
    echo "error: ${HEADER} 里没有 MPV_RENDER_PARAM_BACKEND —— 补丁 0000 没打上?" >&2; exit 1; }

echo
/usr/bin/otool -D "${LIB}"
echo
echo "OK: $(/usr/bin/basename "${LIB}") 已编译。跑 ./Scripts/build-libmpv.sh --pack 固化成产物。"
