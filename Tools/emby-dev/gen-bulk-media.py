#!/usr/bin/env python3
"""批量填充本地 Emby 开发实例的测试数据(列表/分页/排序/筛选这些只有「量大」才测得动)。

与 gen-media.sh 的分工:那个给约 10 条规格各异的标本(验证判定/播放/字幕/转码),这个给数百条填充物。

为什么用硬链接:需求只是「把列表填满」,150 部电影各存一份 720p 素材要多几百 MB 却毫无信息量。
硬链接让 N 个条目共用一份 inode —— Emby 按路径识别条目,看到的是 N 个独立条目。要真副本时用 `--mode copy`。

元数据一律走本地 .nfo(Emby 4.9.5.0 实测会读),不依赖在线刮削:否则扫一遍库要等网络超时,结果也不可复现。
海报同理,由 Pillow 就地画 poster.jpg。

用法:
    PY="$HOME/.workbuddy/binaries/python/envs/default/bin/python"
    $PY gen-bulk-media.py                          # 150 部电影 + 12 部剧
    $PY gen-bulk-media.py --movies 40 --series 3   # 小批量
    $PY gen-bulk-media.py --pool-only              # 只生成基线素材池
    $PY gen-bulk-media.py --clean                  # 按 manifest 删干净(不动 gen-media.sh 的素材)
    $PY gen-bulk-media.py --no-scan                # 只落文件,不触发 Emby 扫描

素材不入库,脚本入库。
"""

import argparse
import colorsys
import json
import os
import random
import shutil
import subprocess
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import xml.sax.saxutils as sx
from datetime import date, timedelta
from pathlib import Path

# ---------------------------------------------------------------- 路径与外部工具

BASE = Path(__file__).resolve().parent
MEDIA = BASE / "media"
MOVIES_DIR = MEDIA / "Movies"
TV_DIR = MEDIA / "TV"
# 基线素材池与标签 PNG 都刻意放在 media/ 之外:
# Emby 会把媒体目录里的图片当海报收走,基线视频则会被当成一部真电影入库。
POOL_DIR = BASE / ".bulk-pool"
MANIFEST = BASE / ".bulk-manifest.json"

FFMPEG = os.environ.get("FFMPEG", "/opt/homebrew/bin/ffmpeg")
FONTS = [
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
]

# ---------------------------------------------------------------- 素材基线池
#
# 所有填充条目都硬链接到这 6 条基线之一。规格刻意错开,列表里就能同时看到 mp4/mkv、单/双音轨、
# 15 秒到 5 分钟的不同时长,不必为每条单独编码。

POOLS = [
    dict(key="A", w=854, h=480, dur=30, hue=0, freq=300, ext="mp4", audio=1, subs=0, weight=30),
    dict(key="B", w=854, h=480, dur=90, hue=60, freq=380, ext="mp4", audio=1, subs=0, weight=15),
    dict(key="C", w=1280, h=720, dur=60, hue=120, freq=460, ext="mp4", audio=1, subs=0, weight=20),
    dict(key="D", w=640, h=360, dur=15, hue=180, freq=540, ext="mp4", audio=1, subs=0, weight=15),
    dict(key="E", w=854, h=480, dur=300, hue=240, freq=620, ext="mp4", audio=1, subs=0, weight=10),
    dict(key="F", w=854, h=480, dur=120, hue=300, freq=700, ext="mkv", audio=2, subs=2, weight=10),
]

# ---------------------------------------------------------------- 命名素材池

# 16 × 16 = 256 种组合,足够撑起 150 部不重名。
TITLE_PREFIX = ["沉默", "深海", "迷雾", "赤色", "星尘", "雪原", "长夜", "孤岛",
                "铁幕", "雾都", "荒原", "逆流", "暗河", "浮生", "极地", "风起"]
TITLE_SUFFIX = ["追缉", "回声", "黎明", "契约", "边际", "孤舟", "坐标", "旧梦",
                "余温", "时刻", "列车", "航线", "囚笼", "来客", "风暴", "序曲"]

SERIES_TITLES = ["星河纪元", "雾港档案", "第七号仓库", "青苔之城", "寒鸦计划", "红岸往事",
                 "月海列车", "沉默的证词", "荒村纪事", "灯下故人", "北纬四十度", "碎镜之城",
                 "深夜杂货铺", "芦苇与铁", "最后一场雨", "观测者日志"]

EPISODE_TITLES = ["启程", "暗涌", "裂痕", "信物", "回声", "断线", "归途", "对峙",
                  "余烬", "真相", "离别", "重逢", "代价", "落幕", "伏笔", "惊蛰",
                  "旧伤", "风声", "误认", "退路", "面谈", "空屋", "钥匙", "尾声"]

GENRES = ["动作", "科幻", "剧情", "喜剧", "悬疑", "犯罪", "动画", "纪录片",
          "恐怖", "爱情", "奇幻", "冒险", "历史", "战争", "家庭", "音乐"]

COUNTRIES = ["中国大陆", "美国", "日本", "法国", "英国", "韩国", "德国"]

RATINGS_R = ["G", "PG", "PG-13", "R", "TV-14", "TV-MA", "PG-12"]

STUDIOS = ["临海影业", "北岸制片厂", "长风影业", "深蓝工坊", "折叠影像", "白露制作"]

DIRECTORS = ["陈知远", "林见山", "苏禾", "周慕白", "许清和", "沈望舒", "高砚秋", "叶南舟"]

ACTORS = ["何书言", "柳青禾", "郑怀安", "白景行", "钟未眠", "孟悬", "于归", "程一鸣",
          "简纯", "卫长庚", "樊溪", "阮明河"]

PLOT_MOVIE = [
    "一座被雾气锁住的沿海小城,因为一桩旧案重新有了动静。",
    "三个互不相识的人在同一个雨夜收到同一条短信,从此再也回不去。",
    "为了找回失踪的同事,他走进了一个从未在任何地图上出现的地方。",
    "一次例行检修,让整座地下设施的秘密开始一格格显影。",
    "她原以为这只是一次普通的出差,直到行李箱里多了一样不属于她的东西。",
    "四十年后,当年被埋进剧本结尾的名字,出现在了一则讣告上。",
    "边境线上的信号塔每晚会多播一分钟,没有人知道那一分钟属于谁。",
    "一支考察队进入冻土带,带回来的只有一盘录着敲门声的磁带。",
]

PLOT_EPISODE = [
    "线索指向一个所有人都以为早就废弃的地方。",
    "他做了一个决定,而这个决定在第二天就让所有人付出了代价。",
    "旧照片背面的字迹,把时间线往前推了整整十年。",
    "两个本该站在对立面的人,第一次坐在了同一张桌子前。",
    "关于那晚究竟发生了什么,三个人的说法完全对不上。",
    "一份被撕掉两页的报告,成了整件事的转折点。",
    "她终于说出了那个名字,房间里的空气一下子变了。",
    "所有人都以为结束了,只有他还站在原地没有走。",
]

TAGLINES = ["有些真相,不适合被找到", "每个人都有一段不愿提起的路",
            "沉默有时比谎言更沉", "回不去的从来不是地方", "在雾散之前"]

# ---------------------------------------------------------------- Emby API


class Emby:
    """够用就好的最小客户端。只做「触发扫描 + 数条目」。"""

    def __init__(self, base_url, user, password):
        self.base = base_url
        self.user = user
        self.password = password
        self.token = None
        self.uid = None

    def _call(self, method, path, payload=None, query=None, timeout=60):
        url = self.base + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        headers = {
            "Authorization": 'Emby Client="LumaPlayer", Device="Mac", '
                             'DeviceId="luma-dev-bulk", Version="0.1"'
        }
        if self.token:
            headers["X-Emby-Token"] = self.token
        data = None
        if payload is not None:
            headers["Content-Type"] = "application/json"
            data = json.dumps(payload).encode()
        req = urllib.request.Request(url, method=method, headers=headers, data=data)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode("utf-8", "replace")
        except urllib.error.URLError as exc:
            return 0, str(exc)

    def login(self):
        status, body = self._call("POST", "/Users/AuthenticateByName",
                                  {"Username": self.user, "Pw": self.password})
        if status != 200:
            raise RuntimeError(f"登录失败 {status}: {body[:200]}")
        auth = json.loads(body)
        self.token = auth["AccessToken"]
        self.uid = auth["User"]["Id"]
        return auth["User"]["Name"]

    def count(self, item_type):
        status, body = self._call(
            "GET", f"/Users/{self.uid}/Items",
            query={"IncludeItemTypes": item_type, "Recursive": "true",
                   "Limit": 1, "EnableTotalRecordCount": "true"})
        if status != 200:
            raise RuntimeError(f"统计 {item_type} 失败 {status}: {body[:200]}")
        return json.loads(body).get("TotalRecordCount")

    def counts(self):
        return {t: self.count(t) for t in ("Movie", "Series", "Season", "Episode")}

    def refresh(self):
        return self._call("POST", "/Library/Refresh")[0]


# ---------------------------------------------------------------- 文件与文本工具


def pick_font(size):
    from PIL import ImageFont
    for path in FONTS:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    raise SystemExit("找不到可用的中文字体")


def fmt_dur(seconds):
    seconds = int(seconds)
    if seconds >= 3600:
        return "%d:%02d:%02d" % (seconds // 3600, seconds % 3600 // 60, seconds % 60)
    return "%d:%02d" % (seconds // 60, seconds % 60)


def run(cmd):
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(f"命令失败({proc.returncode}): {' '.join(cmd[:6])} …\n{proc.stderr[-500:]}")


def write_nfo(path, root_tag, fields, list_fields=None, people=None):
    """写一份 Kodi 风格 .nfo。fields 是标量字段,list_fields 是可重复字段。"""
    parts = ['<?xml version="1.0" encoding="utf-8" standalone="yes"?>', f"<{root_tag}>"]
    for key, value in fields.items():
        if value is None or value == "":
            continue
        parts.append(f"  <{key}>{sx.escape(str(value))}</{key}>")
    for key, values in (list_fields or {}).items():
        for value in values:
            parts.append(f"  <{key}>{sx.escape(str(value))}</{key}>")
    for kind, names in (people or {}).items():
        for name in names:
            parts.append(f"  <{kind}><name>{sx.escape(name)}</name></{kind}>")
    parts.append(f"</{root_tag}>")
    path.write_text("\n".join(parts) + "\n", encoding="utf-8")
    return path


def write_srt(path, dur, title):
    """等距时间轴的外挂字幕,用来验「外挂字幕是否关联」。"""
    lines, at, n = [], max(3, dur // 4), 0
    while at < dur - 1 and n < 8:
        n += 1
        start = "%02d:%02d:%02d,000" % (at // 3600, at % 3600 // 60, at % 60)
        end = "%02d:%02d:%02d,000" % ((at + 3) // 3600, (at + 3) % 3600 // 60, (at + 3) % 60)
        lines.append(f"{n}\n{start} --> {end}\n{title} 字幕 @ {fmt_dur(at)}\n")
        at += max(8, dur // 3)
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def make_poster(path, title, subtitle, footer, seed, width=400, height=600):
    """就地画一张海报。渐变底 + 自动换行的标题 + 页脚,
    目的是让列表 UI「看起来是满的」,不依赖任何在线刮削。"""
    from PIL import Image, ImageDraw

    hue = (seed * 0.137) % 1.0
    top = tuple(int(c * 255) for c in colorsys.hsv_to_rgb(hue, 0.55, 0.42))
    bottom = tuple(int(c * 255) for c in colorsys.hsv_to_rgb((hue + 0.08) % 1.0, 0.65, 0.14))

    img = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(img)
    for y in range(height):
        k = y / (height - 1)
        draw.line([(0, y), (width, y)],
                  fill=tuple(int(top[i] + (bottom[i] - top[i]) * k) for i in range(3)))

    pad = 28
    # 标题自动换行:逐字累加,放不下就断行(CJK 可以在任意字之间断)。
    font = pick_font(46)
    lines, cur = [], ""
    for ch in title:
        if draw.textlength(cur + ch, font=font) > width - pad * 2 and cur:
            lines.append(cur)
            cur = ch
        else:
            cur += ch
    if cur:
        lines.append(cur)
    lines = lines[:3]

    y = int(height * 0.30)
    for line in lines:
        draw.text((pad, y), line, font=font, fill=(255, 255, 255))
        y += 58

    if subtitle:
        draw.text((pad, y + 14), subtitle, font=pick_font(26), fill=(226, 226, 226))

    draw.rectangle([0, height - 62, width, height], fill=(0, 0, 0))
    draw.text((pad, height - 44), footer, font=pick_font(22), fill=(180, 180, 180))
    img.save(path, quality=82)
    return path


# ---------------------------------------------------------------- 基线素材池


class Builder:
    def __init__(self, args):
        self.args = args
        self.rng = random.Random(args.seed)
        self.manifest = {"files": [], "dirs": [], "pool": []}
        # 合并上一次的 manifest:小批量跑几次再补大批量时,--clean 要能一次删干净。
        if MANIFEST.exists():
            try:
                old = json.loads(MANIFEST.read_text(encoding="utf-8"))
                for key in self.manifest:
                    self.manifest[key] = list(dict.fromkeys(old.get(key, [])))
            except (ValueError, OSError):
                pass
        self.pool_paths = {}

    # ---- 记账:所有生成物都进 manifest,--clean 靠它删干净 ----

    def track_file(self, path, pool=False):
        entry = str(path.relative_to(BASE))
        (self.manifest["pool"] if pool else self.manifest["files"]).append(entry)

    def track_dir(self, path):
        self.manifest["dirs"].append(str(path.relative_to(BASE)))

    def save_manifest(self):
        MANIFEST.write_text(json.dumps(self.manifest, ensure_ascii=False, indent=1), encoding="utf-8")

    # ---- 硬链接:跨设备失败时退回复制,不静默跳过 ----

    def place(self, target, source):
        target.parent.mkdir(parents=True, exist_ok=True)
        if self.args.mode == "hardlink":
            try:
                os.link(source, target)
                self.track_file(target)
                return
            except OSError:
                pass  # 跨文件系统 / 不支持硬链接 → 退回复制
        shutil.copyfile(source, target)
        self.track_file(target)

    # ---- 基线池 ----

    def build_pool(self):
        POOL_DIR.mkdir(parents=True, exist_ok=True)
        label_dir = POOL_DIR / "labels"
        label_dir.mkdir(exist_ok=True)
        have_pillow = True
        try:
            import PIL  # noqa: F401
        except ImportError:
            have_pillow = False
            print("  提示: 没有 Pillow,基线池不烧标签、不画海报")

        for spec in POOLS:
            out = POOL_DIR / f"pool-{spec['key']}.{spec['ext']}"
            self.pool_paths[spec["key"]] = out
            if out.exists() and not self.args.force:
                continue

            label = label_dir / f"pool-{spec['key']}.png"
            if have_pillow:
                make_label(label, spec["w"], f"批量基线 {spec['key']}",
                           f"{spec['w']}x{spec['h']} · {fmt_dur(spec['dur'])}")

            # 输入顺序:0=画面 1=首音轨 [2=次音轨] [n=标签 PNG];
            # 标签的索引取决于前面插了几个输入,所以边拼边记,别写死。
            cmd = [FFMPEG, "-y", "-hide_banner", "-loglevel", "error",
                   "-f", "lavfi",
                   "-i", f"testsrc2=size={spec['w']}x{spec['h']}:rate=24:duration={spec['dur']}",
                   "-f", "lavfi", "-i", f"sine=frequency={spec['freq']}:duration={spec['dur']}"]
            if spec["audio"] > 1:
                cmd += ["-f", "lavfi", "-i",
                        f"sine=frequency={spec['freq'] + 200}:duration={spec['dur']}"]

            has_label = have_pillow and label.exists()
            if has_label:
                label_idx = 1 + spec["audio"]
                cmd += ["-i", str(label)]
                cmd += ["-filter_complex",
                        f"[0:v]hue=h={spec['hue']}[v];"
                        f"[v][{label_idx}:v]overlay=0:main_h-overlay_h[vout]",
                        "-map", "[vout]"]
            else:
                cmd += ["-vf", f"hue=h={spec['hue']}", "-map", "0:v"]
            for i in range(spec["audio"]):
                cmd += ["-map", f"{i + 1}:a"]

            cmd += ["-c:v", "libx264", "-profile:v", "high", "-preset", "veryfast",
                    "-crf", "32", "-pix_fmt", "yuv420p", "-g", "48",
                    "-c:a", "aac", "-b:a", "64k", "-ac", "2"]
            if spec["audio"] > 1:
                cmd += ["-metadata:s:a:0", "language=eng", "-metadata:s:a:0", "title=English",
                        "-metadata:s:a:1", "language=chi", "-metadata:s:a:1", "title=Chinese"]
            if spec["ext"] == "mp4":
                cmd += ["-movflags", "+faststart"]
            cmd += ["-shortest", str(out)]
            run(cmd)
            self.track_file(out, pool=True)
            print(f"  基线 {spec['key']}: {spec['w']}x{spec['h']} {fmt_dur(spec['dur'])} "
                  f"{spec['ext']} … {out.stat().st_size // 1024} KB")

    def pick_pool(self):
        keys = [s["key"] for s in POOLS]
        weights = [s["weight"] for s in POOLS]
        key = self.rng.choices(keys, weights=weights, k=1)[0]
        return next(s for s in POOLS if s["key"] == key), self.pool_paths[key]


def make_label(out, width, main_text, sub_text):
    """与 make-label.py 同构:底部半透明标签条,给截图带上身份信息。"""
    from PIL import Image, ImageDraw

    height = max(48, round(width * 0.085))
    font_main = pick_font(round(height * 0.46))
    font_sub = pick_font(round(height * 0.36))

    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.rectangle([0, 0, width, height], fill=(0, 0, 0, 170))
    pad = round(height * 0.22)

    def draw_text(text, font, x, fill):
        box = draw.textbbox((0, 0), text, font=font)
        draw.text((x, (height - (box[3] - box[1])) // 2 - box[1]), text, font=font, fill=fill)
        return box[2] - box[0]

    draw_text(main_text, font_main, pad, (255, 255, 255, 255))
    sub_w = draw.textbbox((0, 0), sub_text, font=font_sub)[2]
    main_w = draw.textbbox((0, 0), main_text, font=font_main)[2]
    if pad + main_w + pad * 3 + sub_w <= width:
        draw_text(sub_text, font_sub, width - pad - sub_w, (215, 215, 215, 255))
    img.save(out)


# ---------------------------------------------------------------- 电影

def gen_movies(builder, count):
    rng = builder.rng
    seen = set()
    made = 0

    while made < count:
        title = rng.choice(TITLE_PREFIX) + rng.choice(TITLE_SUFFIX)
        year = rng.randint(1995, 2026)
        if (title, year) in seen:
            continue
        seen.add((title, year))
        made += 1

        idx = made
        spec, src = builder.pick_pool()
        folder = MOVIES_DIR / f"{title} ({year})"
        folder.mkdir(parents=True, exist_ok=True)
        builder.track_dir(folder)

        # 每 25 部留一部做「多版本」:同一部片两个清晰度,验多 MediaSource 选择。
        multi = (idx % 25 == 0)
        if multi:
            spec2, src2 = builder.pick_pool()
            for tag, other, other_src in (("1080p", spec, src), ("720p", spec2, src2)):
                builder.place(folder / f"{title} ({year}) - {tag}.{other['ext']}", other_src)
            runtime = max(spec["dur"], spec2["dur"])
            # 多版本时没有哪一份文件对得上「片名 (年份)」,按 Kodi 约定用 movie.nfo。
            nfo_path = folder / "movie.nfo"
        else:
            builder.place(folder / f"{title} ({year}).{spec['ext']}", src)
            runtime = spec["dur"]
            nfo_path = folder / f"{title} ({year}).nfo"

        genres = rng.sample(GENRES, rng.randint(1, 3))
        premiered = date(year, rng.randint(1, 12), rng.randint(1, 28))
        plot = rng.choice(PLOT_MOVIE) + f"(《{title}》,{year})"
        write_nfo(
            nfo_path, "movie",
            {
                "title": title,
                "originaltitle": title,
                "sorttitle": f"bulk-{idx:04d}-{title}",
                "year": year,
                "premiered": premiered.isoformat(),
                "plot": plot,
                "tagline": rng.choice(TAGLINES),
                "runtime": max(1, round(runtime / 60)),
                "mpaa": rng.choice(RATINGS_R),
                "rating": round(rng.uniform(3.0, 9.5), 1),
                "votes": rng.randint(120, 98000),
                "studio": rng.choice(STUDIOS),
                "director": rng.choice(DIRECTORS),
            },
            list_fields={"genre": genres, "country": [rng.choice(COUNTRIES)]},
            people={"actor": rng.sample(ACTORS, 3)},
        )
        make_poster(folder / "poster.jpg", title, f"{year} · {' / '.join(genres)}",
                    f"批量测试数据 · 电影 {idx:03d}", idx)

        # 每 8 部配一条外挂字幕,验「外挂字幕关联」在面上也成立。
        if idx % 8 == 0:
            srt = folder / f"{title} ({year}).zh.srt"
            write_srt(srt, max(8, runtime), title)
            builder.track_file(srt)

        if idx % 25 == 0:
            print(f"  电影 {idx}/{count} …")


# ---------------------------------------------------------------- 剧集

def gen_series(builder, count):
    rng = builder.rng
    titles = rng.sample(SERIES_TITLES, min(count, len(SERIES_TITLES)))
    while len(titles) < count:  # 池子不够就补「第二季」式重名
        titles.append(f"{rng.choice(SERIES_TITLES)} · 重启篇 {len(titles)}")

    total_eps = 0
    for si, title in enumerate(titles, start=1):
        year = rng.randint(2005, 2024)
        folder = TV_DIR / f"{title} ({year})"
        folder.mkdir(parents=True, exist_ok=True)
        builder.track_dir(folder)

        seasons = rng.randint(2, 3)
        first_air = date(year, rng.randint(1, 12), rng.randint(1, 28))
        write_nfo(
            folder / "tvshow.nfo", "tvshow",
            {
                "title": title,

                "year": year,
                "premiered": first_air.isoformat(),
                "plot": f"{rng.choice(PLOT_MOVIE)}(《{title}》,共 {seasons} 季)",
                "mpaa": rng.choice(RATINGS_R),
                "rating": round(rng.uniform(4.0, 9.4), 1),
                "studio": rng.choice(STUDIOS),
                "status": "Continuing" if year >= 2022 else "Ended",
            },
            list_fields={"genre": rng.sample(GENRES, rng.randint(1, 3)),
                         "country": [rng.choice(COUNTRIES)]},
            people={"actor": rng.sample(ACTORS, 4)},
        )
        make_poster(folder / "poster.jpg", title, f"{year} · 共 {seasons} 季",
                    f"批量测试数据 · 剧集 {si:02d}", 1000 + si)

        # 三分之一的剧带特辑季(Season 00),覆盖「特别篇」分支。
        season_numbers = list(range(1, seasons + 1))
        if si % 3 == 0:
            season_numbers = [0] + season_numbers

        for snum in season_numbers:
            sdir = folder / ("Season 00" if snum == 0 else f"Season {snum:02d}")
            sdir.mkdir(parents=True, exist_ok=True)
            builder.track_dir(sdir)

            if snum == 0:
                eps = rng.randint(1, 2)
                snum_title = "特别篇"
            else:
                eps = rng.randint(4, 10)
                snum_title = f"第 {snum} 季"
            write_nfo(sdir / "season.nfo", "season",
                      {"title": snum_title, "seasonnumber": snum,
                       "plot": f"{title} · {snum_title}"})
            make_poster(sdir / "poster.jpg", f"{title}", snum_title,
                        f"批量测试数据 · S{snum:02d}", 2000 + si * 10 + snum, 400, 600)

            for ep in range(1, eps + 1):
                ep_title = rng.choice(EPISODE_TITLES)
                spec, src = builder.pick_pool()
                stem = f"{title} S{snum:02d}E{ep:02d} - {ep_title}"
                builder.place(sdir / f"{stem}.{spec['ext']}", src)
                aired = first_air + timedelta(days=(snum * 90) + ep * 7)
                write_nfo(
                    sdir / f"{stem}.nfo", "episodedetails",
                    {
                        "title": ep_title,
                        "season": snum,
                        "episode": ep,
                        "plot": rng.choice(PLOT_EPISODE),
                        "aired": aired.isoformat(),
                        "rating": round(rng.uniform(3.5, 9.5), 1),
                        "runtime": max(1, round(spec["dur"] / 60)),
                        "director": rng.choice(DIRECTORS),
                    },
                )
                # 每季首集配外挂字幕,其余不配 —— 保持「有的有、有的没有」。
                if ep == 1:
                    srt = sdir / f"{stem}.zh.srt"
                    write_srt(srt, max(8, spec["dur"]), f"{title} S{snum:02d}E{ep:02d}")
                    builder.track_file(srt)
                total_eps += 1

        print(f"  剧集 {si}/{count}: {title}  {seasons} 季")

    return total_eps


# ---------------------------------------------------------------- 清理


# 只清理自己认识的扩展名:别人往批量目录里丢的东西不动,那个目录也就留下来。
GENERATED_EXT = {".mp4", ".mkv", ".nfo", ".srt", ".jpg", ".png"}


def do_clean():
    if not MANIFEST.exists():
        print(f"没有 manifest({MANIFEST}),无可清理")
        return
    data = json.loads(MANIFEST.read_text(encoding="utf-8"))
    removed, kept = 0, []
    for rel in data.get("files", []) + data.get("pool", []):
        path = BASE / rel
        if path.is_file():
            path.unlink()
            removed += 1

    # 目录自深向浅:先清掉自己生成的文件,空了才删目录。
    for rel in sorted(data.get("dirs", []), key=lambda p: len(Path(p).parts), reverse=True):
        folder = BASE / rel
        if not folder.is_dir():
            continue
        for item in folder.iterdir():
            if item.is_file() and item.suffix.lower() in GENERATED_EXT:
                item.unlink()
                removed += 1
        try:
            folder.rmdir()
        except OSError:
            kept.append(rel)

    for extra in (POOL_DIR / "labels", POOL_DIR):
        if extra.exists():
            shutil.rmtree(extra, ignore_errors=True)
    MANIFEST.unlink(missing_ok=True)

    print(f"已删除 {removed} 个文件与空的批量目录(gen-media.sh 的素材未受影响)")
    for rel in kept:
        print(f"  保留(目录里还有非批量文件):{rel}")


# ---------------------------------------------------------------- 主流程


def main():
    parser = argparse.ArgumentParser(
        description="批量填充本地 Emby 的测试数据",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--movies", type=int, default=150, help="电影数量(默认 150)")
    parser.add_argument("--series", type=int, default=12, help="剧集数量(默认 12)")
    parser.add_argument("--seed", type=int, default=20261015, help="随机种子,保证可复现")
    parser.add_argument("--mode", choices=["hardlink", "copy"], default="hardlink",
                        help="硬链接(默认,几乎不占空间)或真副本")
    parser.add_argument("--pool-only", action="store_true", help="只生成基线素材池")
    parser.add_argument("--force", action="store_true", help="基线池已存在也重新生成")
    parser.add_argument("--clean", action="store_true", help="按 manifest 删除批量数据")
    parser.add_argument("--no-scan", action="store_true", help="不触发 Emby 扫描")
    parser.add_argument("--base-url", default=os.environ.get("BASE_URL", "http://127.0.0.1:8096/emby"))
    parser.add_argument("--user", default=os.environ.get("ADMIN_USER", "luma"))
    parser.add_argument("--password", default=os.environ.get("ADMIN_PASS", "lumadev"))
    args = parser.parse_args()

    if args.clean:
        do_clean()
        return

    if not Path(FFMPEG).exists():
        raise SystemExit(f"找不到 ffmpeg: {FFMPEG}(用 FFMPEG=... 覆盖)")

    builder = Builder(args)
    before = None
    emby = Emby(args.base_url, args.user, args.password)
    try:
        print(f"Emby 登录: {emby.login()}")
        before = emby.counts()
    except RuntimeError as exc:
        print(f"  跳过扫描与统计({exc})")

    print("\n== 基线素材池")
    builder.build_pool()

    if not args.pool_only:
        print(f"\n== 电影 {args.movies} 部({args.mode})")
        gen_movies(builder, args.movies)
        print(f"\n== 剧集 {args.series} 部({args.mode})")
        total_eps = gen_series(builder, args.series)
        print(f"\n  共 {total_eps} 集")

    builder.save_manifest()
    print(f"  manifest: {MANIFEST.relative_to(BASE)}")

    # 只统计新文件——硬链接模式下 du 看不出增量,条目数才是验收依据。
    created = [BASE / p for p in builder.manifest["files"]]
    print(f"  新建(未去重)文件 {len(created)} 个,"
          f"占用 {sum(f.stat().st_size for f in created if f.exists()) / 1e6:.1f} MB"
          f"(硬链接时磁盘实际增量接近 0)")

    if args.no_scan or before is None:
        print("\n未触发扫描。可在面板里手工扫描,或重跑去掉 --no-scan。")
        return

    print("\n== 触发扫描")
    print(f"  /Library/Refresh -> {emby.refresh()}")
    print("  扫描是异步的,请在面板确认条目数,或稍后用 API 复查:")
    print(f"     GET {args.base_url}/Users/<uid>/Items?IncludeItemTypes=Movie&Recursive=true")


if __name__ == "__main__":
    main()
