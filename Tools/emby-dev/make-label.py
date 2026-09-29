#!/usr/bin/env python3
"""生成叠加在测试素材底部的半透明标签条。

为什么需要它:testsrc2 的左上角只自带时间码与帧号,能证明"播到了第几秒",
但证明不了"播的是哪一集"。手工验收最容易出的错就是点开 E03、实际播的是 E01,
而截图里看不出这一点。标签条让截图本身携带身份信息。

放在底部是为了不遮挡 testsrc2 左上角的时间码——那个才是判断 seek 是否生效的依据。

依赖 Pillow + macOS 自带中文字体。字体缺失时脚本以非 0 退出,
由调用方(gen-media.sh)决定降级,不要在这里假装成功。

用法: make-label.py <输出.png> <宽度> <主标题> <副标题>
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# macOS 自带,按优先级探测。ttc 用 index 0(即该字体的常规字重)。
FONT_CANDIDATES = [
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
]

BAR_ALPHA = 170


def pick_font(size: int) -> ImageFont.FreeTypeFont:
    for path in FONT_CANDIDATES:
        if Path(path).exists():
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    raise SystemExit("找不到可用的中文字体,标签无法生成")


def main() -> None:
    if len(sys.argv) < 5:
        raise SystemExit(__doc__)

    out, width, main_text, sub_text = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    height = max(48, round(width * 0.085))

    main_size = round(height * 0.46)
    sub_size = round(height * 0.36)
    font_main = pick_font(main_size)
    font_sub = pick_font(sub_size)

    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.rectangle([0, 0, width, height], fill=(0, 0, 0, BAR_ALPHA))

    pad = round(height * 0.22)
    # 垂直居中的基线:用 bbox 的实际高度算,别用 fontsize 近似。
    def draw_text(text: str, font, x: int, fill) -> int:
        box = draw.textbbox((0, 0), text, font=font)
        draw.text((x, (height - (box[3] - box[1])) // 2 - box[1]), text, font=font, fill=fill)
        return box[2] - box[0]

    draw_text(main_text, font_main, pad, (255, 255, 255, 255))

    # 副标题右对齐;空间不够就整条丢弃,不挤压主标题。
    sub_w = draw.textbbox((0, 0), sub_text, font=font_sub)[2]
    main_w = draw.textbbox((0, 0), main_text, font=font_main)[2]
    if pad + main_w + pad * 3 + sub_w <= width:
        draw_text(sub_text, font_sub, width - pad - sub_w, (215, 215, 215, 255))

    img.save(out)


if __name__ == "__main__":
    main()
