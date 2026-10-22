#!/usr/bin/env bash
#
# 生成本地 Emby 开发实例的测试媒体(素材不入库,脚本入库,随时可重建)。
#
# 目录与文件名对齐 Emby 官方命名规则(TV-Naming.html),否则剧集扫不出来:
#
#   media/
#     Movies/                                 ← 媒体库「movies」
#       01-direct-h264-aac.mp4 (+ .zh.srt)     直连基线
#       02-multi-track.mkv                     多音轨多字幕
#       03-transcode-hevc.mkv                  1080p10bit,HEVC 转码判定
#       演示长片 (2024)/                        30 分钟,测拖动精度与断点续播上报
#     TV/                                     ← 媒体库「tvshows」
#       演示剧集 (2024)/Season 01|02|00/        2 季 6 集 + 特辑,测 Series/Season/Episode 三级浏览
#
# 长片与剧集都做三重「自证身份」:画面底部烧标签、色相按集错开、音轨频率按集错开。
# 手工验收最容易搞混(点开 E03 结果播的是 E01,截图里看不出来),所以留了这三重冗余。
# testsrc2 自带左上角时间码,是判断 seek 生效的依据,因此标签只放底部。
#
# 时长与分辨率可用环境变量覆盖:LONG_DUR=7200 ./gen-media.sh、WIDTH=1280 HEIGHT=720 ./gen-media.sh
# 用法:./gen-media.sh          # 全部重建
#       FFMPEG=/path/to/ffmpeg ./gen-media.sh

set -euo pipefail

FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
# 生成标签用;Pillow 缺失时降级为「不烧标签」而不是失败。
PYTHON="${PYTHON:-python3}"

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="$BASE/media"
# 标签 PNG 放在 media 之外:Emby 会把媒体目录里的图片当海报收走。
LABELS="$BASE/.labels"

WIDTH="${WIDTH:-854}"
HEIGHT="${HEIGHT:-480}"
FPS="${FPS:-24}"
CRF="${CRF:-30}"
PRESET="${PRESET:-veryfast}"

# 时长(秒)。默认总素材约 60 分钟 / 155 MB。
LONG_DUR="${LONG_DUR:-1800}"
EP_S01E01="${EP_S01E01:-720}"  # 首集 12 分钟,用来验证「同一部剧里集与集时长不同」
EP_DUR="${EP_DUR:-240}"
EP_S00="${EP_S00:-120}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ ! -x "$FFMPEG" ]; then
  echo "找不到 ffmpeg: $FFMPEG" >&2
  echo "用 FFMPEG=/path/to/ffmpeg ./gen-media.sh 指定。" >&2
  exit 1
fi

mkdir -p "$DIR/Movies" "$DIR/TV" "$LABELS"
echo "输出目录: $DIR"

# ---------------------------------------------------------------- 辅助

HAVE_LABEL=0
if [ -x "$PYTHON" ] && "$PYTHON" -c 'import PIL' 2>/dev/null; then
  HAVE_LABEL=1
else
  echo "提示: 没有可用的 Pillow($PYTHON),跳过画面标签烧制。" >&2
fi

# 秒 -> 标签上显示的时长文本
fmt_dur() {
  local s=$1
  if [ "$s" -ge 3600 ]; then
    printf '%d:%02d:%02d' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
  else
    printf '%d:%02d' $((s / 60)) $((s % 60))
  fi
}

# 生成底部标签条;失败不致命,encode_clip 会退回无标签路径。
make_label() {
  local out="$1" main="$2" sub="$3"
  [ "$HAVE_LABEL" -eq 1 ] || return 0
  "$PYTHON" "$BASE/make-label.py" "$out" "$WIDTH" "$main" "$sub" 2>/dev/null || true
}

# encode_clip <主标题> <副标题> <hue> <音轨频率> <时长秒> <输出文件>
#
# 关键帧间隔固定 2 秒(-g = FPS*2):seek 到任意位置最多等 2 秒就有解码入口,拖进度条不会长时间黑屏。
encode_clip() {
  local main="$1" sub="$2" hue="$3" freq="$4" dur="$5" out="$6"
  local stem="${out##*/}"; stem="${stem%.*}"
  local label="$LABELS/$stem.png"

  make_label "$label" "$main" "$sub"

  local src="testsrc2=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${dur}"
  local audio="sine=frequency=${freq}:duration=${dur}"
  local enc=(-c:v libx264 -profile:v high -preset "$PRESET" -crf "$CRF"
             -pix_fmt yuv420p -g $((FPS * 2))
             -c:a aac -b:a 96k -ac 2)

  mkdir -p "$(dirname "$out")"

  if [ -f "$label" ]; then
    # 标签作为第三个输入(索引 2),叠到底部。
    "$FFMPEG" -y -hide_banner -loglevel error \
      -f lavfi -i "$src" -f lavfi -i "$audio" -i "$label" \
      -filter_complex "[0:v]hue=h=${hue}[v];[v][2:v]overlay=0:main_h-overlay_h[vout]" \
      -map "[vout]" -map 1:a \
      "${enc[@]}" -movflags +faststart -shortest "$out"
  else
    "$FFMPEG" -y -hide_banner -loglevel error \
      -f lavfi -i "$src" -f lavfi -i "$audio" \
      -vf "hue=h=${hue}" -map 0:v -map 1:a \
      "${enc[@]}" -movflags +faststart -shortest "$out"
  fi
  echo "    -> ${out#"$DIR"/}  ($(fmt_dur "$dur"))"
}

# 外挂字幕:文件名与视频同名 + 语言后缀,Emby 扫描时关联成外挂字幕轨。
# $1=输出 srt 路径  $2...=每行「秒|文本」,生成等距时间轴。
write_srt() {
  local out="$1"; shift
  local n=0
  : > "$out"
  for entry in "$@"; do
    n=$((n + 1))
    local at="${entry%%|*}" text="${entry#*|}"
    printf '%d\n%s --> %s\n%s\n\n' "$n" \
      "$(printf '%02d:%02d:%02d,000' $((at / 3600)) $(((at % 3600) / 60)) $((at % 60)))" \
      "$(printf '%02d:%02d:%02d,000' $(((at + 4) / 3600)) $((((at + 4) % 3600) / 60)) $(((at + 4) % 60)))" \
      "$text" >> "$out"
  done
}

# ================================================================ 短片三条(规格不变)

echo
echo "== 原有短片(720p/2000k,保持原规格)"

echo "==> 01-direct-h264-aac.mp4"
"$FFMPEG" -y -hide_banner -loglevel error \
  -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=60" \
  -f lavfi -i "sine=frequency=440:duration=60" \
  -map 0:v -map 1:a \
  -c:v libx264 -profile:v high -level 4.1 -pix_fmt yuv420p -b:v 2000k -g 60 \
  -c:a aac -b:a 128k -ac 2 \
  -movflags +faststart \
  "$DIR/Movies/01-direct-h264-aac.mp4"

write_srt "$DIR/Movies/01-direct-h264-aac.zh.srt" \
  "1|外挂字幕第一行 —— 若能看到这一行,说明外挂字幕已关联" \
  "10|外挂字幕第二行 —— 用于验证时间轴对齐" \
  "30|外挂字幕第三行 —— 拖动进度后应跳到这里"

echo "==> 02-multi-track.mkv"
write_srt "$TMP/eng.srt" \
  "2|Embedded subtitle track 1 (eng)" "20|Track 1, second cue" "40|Track 1, third cue"
write_srt "$TMP/chi.srt" \
  "2|内嵌字幕轨 2(chi)" "20|第二条字幕" "40|第三条字幕"

"$FFMPEG" -y -hide_banner -loglevel error \
  -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=60" \
  -f lavfi -i "sine=frequency=440:duration=60" \
  -f lavfi -i "sine=frequency=880:duration=60" \
  -map 0:v -map 1:a -map 2:a \
  -c:v libx264 -pix_fmt yuv420p -b:v 2000k -g 60 \
  -c:a aac -b:a 128k -ac 2 \
  -metadata:s:a:0 language=eng -metadata:s:a:0 title="English 440Hz" \
  -metadata:s:a:1 language=chi -metadata:s:a:1 title="Chinese 880Hz" \
  "$TMP/base.mkv"

"$FFMPEG" -y -hide_banner -loglevel error \
  -i "$TMP/base.mkv" -i "$TMP/eng.srt" -i "$TMP/chi.srt" \
  -map 0 -map 1 -map 2 -c copy \
  -metadata:s:s:0 language=eng -metadata:s:s:0 title="English" \
  -metadata:s:s:1 language=chi -metadata:s:s:1 title="Chinese" \
  "$DIR/Movies/02-multi-track.mkv"

echo "==> 03-transcode-hevc.mkv(1080p10bit,生成较慢)"
"$FFMPEG" -y -hide_banner -loglevel error \
  -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=60" \
  -f lavfi -i "sine=frequency=660:duration=60" \
  -map 0:v -map 1:a \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -b:v 6000k -g 60 \
  -c:a aac -b:a 192k -ac 2 \
  "$DIR/Movies/03-transcode-hevc.mkv"

# ================================================================ 长片

echo
echo "== 长片"

encode_clip "演示长片 (2024)" "片长 $(fmt_dur "$LONG_DUR")" \
  0 440 "$LONG_DUR" "$DIR/Movies/演示长片 (2024)/演示长片 (2024).mp4"

# 每 5 分钟一行,拖到中段也有字幕可对齐。
srt_args=()
t=$((LONG_DUR / 10))
while [ "$t" -lt "$LONG_DUR" ]; do
  srt_args+=("$t|长片字幕 @ $(fmt_dur "$t") —— 应与此处时间码一致")
  t=$((t + LONG_DUR / 10))
done
write_srt "$DIR/Movies/演示长片 (2024)/演示长片 (2024).zh.srt" "${srt_args[@]}"

# ================================================================ 剧集

echo
echo "== 剧集(2 季 + 特辑,共 6 集)"

SERIES="$DIR/TV/演示剧集 (2024)"

encode_clip "演示剧集 (2024) · S01E01" "S01E01 · $(fmt_dur "$EP_S01E01")" \
  40 300 "$EP_S01E01" "$SERIES/Season 01/演示剧集 S01E01 - 首播集.mp4"
encode_clip "演示剧集 (2024) · S01E02" "S01E02 · $(fmt_dur "$EP_DUR")" \
  100 400 "$EP_DUR" "$SERIES/Season 01/演示剧集 S01E02 - 第二集.mp4"
encode_clip "演示剧集 (2024) · S01E03" "S01E03 · $(fmt_dur "$EP_DUR")" \
  160 500 "$EP_DUR" "$SERIES/Season 01/演示剧集 S01E03 - 第三集.mp4"

encode_clip "演示剧集 (2024) · S02E01" "S02E01 · $(fmt_dur "$EP_DUR")" \
  220 600 "$EP_DUR" "$SERIES/Season 02/演示剧集 S02E01 - 第二季第一集.mp4"
encode_clip "演示剧集 (2024) · S02E02" "S02E02 · $(fmt_dur "$EP_DUR")" \
  280 700 "$EP_DUR" "$SERIES/Season 02/演示剧集 S02E02 - 第二季第二集.mp4"

# 特辑季:官方规定用 Season 0 / Season 00 / Specials,集号写 S00E0x。
encode_clip "演示剧集 (2024) · S00E01" "特辑 · $(fmt_dur "$EP_S00")" \
  330 800 "$EP_S00" "$SERIES/Season 00/演示剧集 S00E01 - 幕后特辑.mp4"

# 只给首集配外挂字幕:验证「剧集也能关联外挂字幕」,不必每集都做。
write_srt "$SERIES/Season 01/演示剧集 S01E01 - 首播集.zh.srt" \
  "5|剧集外挂字幕 —— 说明分集文件同样能关联外挂字幕轨" \
  "120|第二行 —— 位置应落在 2 分钟处" \
  "480|第三行 —— 位置应落在 8 分钟处"

echo
echo "完成。素材清单:"
find "$DIR" -type f \( -name '*.mp4' -o -name '*.mkv' -o -name '*.srt' \) \
  | sort | while read -r f; do
      printf '  %6s  %s\n' "$(du -h "$f" | cut -f1)" "${f#"$DIR"/}"
    done
echo "  合计 $(du -sh "$DIR" | cut -f1)"
