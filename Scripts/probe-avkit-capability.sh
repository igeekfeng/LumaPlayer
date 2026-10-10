#!/bin/bash
#
# probe-avkit-capability.sh
#
# P3 第一件事:`avkit-rust-rearchitecture.md` 第 2 节那张 AVFoundation 能力边界表
# 在本机实测量一遍。步骤 ——
#
#   1. 从 `Tools/emby-dev/media/` 的 5 条真实素材出发,用 ffmpeg **造隔离样本**:
#      把同一条音轨 / 字幕轨单独重封装进不同容器。⛔ 不能直接拿 MKV 去测 ——
#      MKV 打不开,任何失败都只能得出「容器不支持」,分不出是哪一维的问题。
#   2. 用独立 swiftc 可执行文件(probe-avkit-capability.swift)逐条问 AVFoundation:
#      能不能打开、轨是否 decodable、字幕进不进 AVMediaSelectionGroup。
#   3. 最后真起播一次本地 MP4,确认播放时刻真的在推进。
#
# 为什么不用 `xcodebuild test`:本机测试宿主建立不了连接(见 KNOWN_ISSUES.md Q34)。
# ⛔ 本脚本不替代 XCTest,只是这台机器上的等价证据(与 P1/P2 那两次自检同一手法)。
#
# 前置:`Tools/emby-dev/gen-media.sh` 已经跑过(素材在 Tools/emby-dev/media/),
#       本机有 ffmpeg(Homebrew)。
#
# 用法(仓库根):
#   ./Scripts/probe-avkit-capability.sh            # 造样本 + 探测,样本留在 build/avkit-probe
#   ./Scripts/probe-avkit-capability.sh --clean    # 先清掉旧样本再重来

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

FFMPEG="$(command -v ffmpeg || true)"
if [[ -z "${FFMPEG}" ]]; then
    echo "error: 找不到 ffmpeg(本脚本用它造隔离样本)。" >&2
    echo "       本机在 /opt/homebrew/bin/ffmpeg。" >&2
    exit 1
fi

FFPROBE="$(command -v ffprobe || true)"
if [[ -z "${FFPROBE}" ]]; then
    echo "error: 找不到 ffprobe(本脚本用它记录样本的真实轨构成)。" >&2
    echo "       本机在 /opt/homebrew/bin/ffprobe。" >&2
    exit 1
fi

MEDIA_DIR="${REPO_ROOT}/Tools/emby-dev/media/Movies"
if [[ ! -f "${MEDIA_DIR}/04-dts.mkv" ]]; then
    echo "error: 缺 ${MEDIA_DIR}/04-dts.mkv" >&2
    echo "       先跑一次 Tools/emby-dev/gen-media.sh" >&2
    exit 1
fi

WORK="${REPO_ROOT}/build/avkit-probe"
if [[ "${1:-}" == "--clean" ]]; then
    /bin/rm -rf "${WORK}"
fi
/bin/mkdir -p "${WORK}"

# ---------------------------------------------------------------- 1. 造样本

echo "造隔离样本(ffmpeg)→ ${WORK}"

make() {  # make <说明> <输出文件名> <ffmpeg 参数...>
    local label="$1" out="$2"; shift 2
    if [[ -s "${WORK}/${out}" ]]; then
        echo "  · 已有 ${out}"
        return 0
    fi
    if "${FFMPEG}" -hide_banner -loglevel error -y "$@" "${WORK}/${out}" 2>"${WORK}/.ffmpeg.log"; then
        echo "  ✅ ${label} → ${out}"
    else
        echo "  ⚠️ ${label} → ${out} 失败:$(tail -1 "${WORK}/.ffmpeg.log")"
        /bin/rm -f "${WORK}/${out}"
    fi
}

# 真实素材原样拷进来,与派生样本放在同一个目录里一起探测
for f in 01-direct-h264-aac.mp4 02-multi-track.mkv 03-transcode-hevc.mkv 04-dts.mkv 05-hevc-pgs.mkv; do
    /bin/cp -f "${MEDIA_DIR}/${f}" "${WORK}/${f}"
done

# 视频维:同一条 HEVC Main10,三种装法;外加 H.264 进 TS 做对照组
make "HEVC 进 MP4(hvc1 tag)" v-hevc-hvc1.mp4 -i "${MEDIA_DIR}/03-transcode-hevc.mkv" -c copy -tag:v hvc1 -movflags +faststart
make "HEVC 进 MP4(hev1 tag)" v-hevc-hev1.mp4 -i "${MEDIA_DIR}/03-transcode-hevc.mkv" -c copy -tag:v hev1 -movflags +faststart
make "HEVC 进 MPEG-TS"      v-hevc.ts      -i "${MEDIA_DIR}/03-transcode-hevc.mkv" -c copy -f mpegts
# 对照组:H.264 进 TS。Emby 的转码 / HLS 输出最常见就是这个形态,
# 先拿它证明「TS 这个容器本身在 AVFoundation 里没问题」。
make "H.264 进 MPEG-TS"     v-h264.ts      -i "${MEDIA_DIR}/01-direct-h264-aac.mp4" -c copy -f mpegts

# 音频维:同一条 H.264 视频,配不同音轨(逐个重编码),外加 DTS/TrueHD
make "H.264 + AC-3"   a-h264-ac3.mp4   -i "${MEDIA_DIR}/01-direct-h264-aac.mp4" -c:v copy -c:a ac3 -b:a 384k
make "H.264 + E-AC-3" a-h264-eac3.mp4  -i "${MEDIA_DIR}/01-direct-h264-aac.mp4" -c:v copy -c:a eac3 -b:a 384k
# AC-3 / E-AC-3 进 TS:Apple 平台的传统直通组合,而「源容器就是 TS」的片源
# (电视录制)也常是它。容器换掉后还认不认,必须单独量。
make "H.264 + AC-3 进 TS"   a-h264-ac3.ts  -i "${MEDIA_DIR}/01-direct-h264-aac.mp4" -c:v copy -c:a ac3 -b:a 384k -f mpegts
make "H.264 + E-AC-3 进 TS" a-h264-eac3.ts -i "${MEDIA_DIR}/01-direct-h264-aac.mp4" -c:v copy -c:a eac3 -b:a 384k -f mpegts
make "H.264 + FLAC"   a-h264-flac.mp4  -i "${MEDIA_DIR}/01-direct-h264-aac.mp4" -c:v copy -c:a flac
make "H.264 + ALAC"   a-h264-alac.mp4  -i "${MEDIA_DIR}/01-direct-h264-aac.mp4" -c:v copy -c:a alac
make "H.264 + MP3"    a-h264-mp3.mp4   -i "${MEDIA_DIR}/01-direct-h264-aac.mp4" -c:v copy -c:a libmp3lame
# MP3 本来的用法(裸音频文件)。上面那个 MP3-进-MP4 是非典型组合,
# 但正因为非典型,才要把它和典型的放在一起比。
make "裸 MP3 文件"    a-h264-mp3.mp3   -i "${MEDIA_DIR}/01-direct-h264-aac.mp4" -vn -c:a libmp3lame
make "H.264 + DTS 进 MP4" a-h264-dts.mp4 -i "${MEDIA_DIR}/04-dts.mkv" -c copy -movflags +faststart
make "H.264 + DTS 进 TS"  a-h264-dts.ts  -i "${MEDIA_DIR}/04-dts.mkv" -c copy -f mpegts
# ⚠️ TrueHD 编码器在 ffmpeg 里是 experimental,要 -strict experimental
make "H.264 + TrueHD 进 TS" a-h264-truehd.ts -i "${MEDIA_DIR}/01-direct-h264-aac.mp4" -c:v copy -c:a truehd -strict experimental

# 字幕维:同一条 H.264/AAC,配不同字幕格式
make "srt→mov_text 进 MP4" s-movtext.mp4 -i "${MEDIA_DIR}/02-multi-track.mkv" -map 0:v -map 0:a:0 -map 0:s:0 -c:v copy -c:a copy -c:s mov_text -movflags +faststart
make "subrip 进 TS"        s-subrip.ts  -i "${MEDIA_DIR}/02-multi-track.mkv" -map 0:v -map 0:a:0 -map 0:s:0 -c:v copy -c:a copy -c:s subrip -f mpegts
make "PGS 进 TS"           s-pgs.ts     -i "${MEDIA_DIR}/05-hevc-pgs.mkv" -c copy -f mpegts
make "PGS 进 MKV"          s-pgs.mkv    -i "${MEDIA_DIR}/05-hevc-pgs.mkv" -c copy -f matroska

# ASS / WebVTT:ffmpeg 的 mp4 封装器收不了(实测 "Nothing was written into output
# file"),只能进 TS / MKV。这里只造 TS 形态,用来回答「系统认不认这条轨」。
cat > "${WORK}/.probe-sample.ass" <<'ASS'
[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,28,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,{\b1}ASS 测试字幕{\b0}
Dialogue: 0,0:00:05.00,0:00:08.00,Default,,0,0,0,,第二行
ASS
cat > "${WORK}/.probe-sample.vtt" <<'VTT'
WEBVTT

00:00:01.000 --> 00:00:04.000
WebVTT 测试字幕

00:00:05.000 --> 00:00:08.000
第二行
VTT
make "ass 进 TS"    s-ass.ts -i "${MEDIA_DIR}/01-direct-h264-aac.mp4" -i "${WORK}/.probe-sample.ass" -map 0 -map 1 -c:v copy -c:a copy -c:s ass -f mpegts
make "webvtt 进 TS" s-vtt.ts -i "${MEDIA_DIR}/01-direct-h264-aac.mp4" -i "${WORK}/.probe-sample.vtt" -map 0 -map 1 -c:v copy -c:a copy -c:s webvtt -f mpegts

# 起播用
make "起播基线 MP4" base-h264-aac.mp4 -i "${MEDIA_DIR}/01-direct-h264-aac.mp4" -c copy -movflags +faststart

# ------------------------------------------------- 1.5 把「文件里实际有什么」也记下来
#
# ⭐ 这一步是必须的:AVFoundation 遇到不认识的编码**不报错**,而是把那条轨
#    悄悄丢掉。只看它的返回,「文件里没有这条轨」与「有但不认」长得一模一样。
#    所以先用 ffprobe 把真相写成一份证据文件,让探针两边对着看。

echo
echo "记录各样本的真实轨构成(ffprobe)→ .ffprobe-tracks.txt"
: > "${WORK}/.ffprobe-tracks.txt"
record() {  # record <文件名> <video|audio|subtitle> <逐行 codec_name>
    local name="$1" type="$2" codecs="$3"
    [[ -z "${codecs}" ]] && return 0
    while IFS= read -r codec; do
        # ffprobe 的 csv 输出在 TS 上会带尾逗号(流在 program 里重复列一次),
        # 去重交给文件末尾的 sort -u。
        codec="${codec%,}"
        [[ -n "${codec}" ]] && echo "${name}|${type}|${codec}" >>"${WORK}/.ffprobe-tracks.txt"
    done <<<"${codecs}"
}
for f in "${WORK}"/*; do
    name="$(basename "${f}")"
    case "${name}" in
        *.mp4|*.mkv|*.ts|*.mp3)
            record "${name}" video "$("${FFPROBE}" -v error -select_streams v -show_entries stream=codec_name -of csv=p=0 "${f}" 2>/dev/null)"
            record "${name}" audio "$("${FFPROBE}" -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "${f}" 2>/dev/null)"
            record "${name}" subtitle "$("${FFPROBE}" -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 "${f}" 2>/dev/null)"
            ;;
    esac
done
# TS 里同一条流会被 program 与 stream 各列一次,排序去重后才是真正的「有哪些轨型」
/usr/bin/sort -u -o "${WORK}/.ffprobe-tracks.txt" "${WORK}/.ffprobe-tracks.txt"
echo "  ✅ $(/usr/bin/wc -l <"${WORK}/.ffprobe-tracks.txt" | /usr/bin/tr -d ' ') 种轨型"
# ---------------------------------------------------------------- 2. 编译并探测

BIN="${WORK}/probe-avkit-capability"
echo
echo "编译探针(swiftc,不经 XCTest 宿主)…"
/usr/bin/xcrun swiftc -swift-version 6 -parse-as-library \
    -o "${BIN}" \
    "${REPO_ROOT}/Scripts/probe-avkit-capability.swift"

echo
"${BIN}" "${WORK}"
