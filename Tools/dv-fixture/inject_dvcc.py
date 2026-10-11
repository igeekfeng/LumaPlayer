"""给普通 HEVC MP4 的 sample entry 塞一个 `dvcC`(Dolby Vision 配置记录),造「demux 看起来是 DV」的测试片源。

只有容器层的配置记录,码流里没有 RPU —— 够验 mpv 的 `track-list/N/dolby-vision-profile`
与按片源选渲染后端(MPVRenderBackendPolicy),⛔ 验不了 DV 画面颜色。

重新生成 LumaPlayerTests/Fixtures/Media/ 下的两个文件(仓库根执行):
  ffmpeg -y -f lavfi -i testsrc2=size=160x90:rate=24:duration=1 -c:v libx265 -pix_fmt yuv420p10le \
    -tag:v hvc1 -x265-params log-level=error -map_metadata -1 -fflags +bitexact -flags:v +bitexact \
    LumaPlayerTests/Fixtures/Media/sdr_hevc_synthetic.mp4
  python3 -I Tools/dv-fixture/inject_dvcc.py LumaPlayerTests/Fixtures/Media/sdr_hevc_synthetic.mp4 \
    LumaPlayerTests/Fixtures/Media/dv_profile8_synthetic.mp4
"""
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
data = bytearray(open(src, 'rb').read())
CONTAINERS = {b'moov', b'trak', b'mdia', b'minf', b'stbl'}
def boxes(buf, start, end):
    i = start
    while i < end:
        size, typ = struct.unpack('>I4s', buf[i:i+8])
        yield i, size, typ
        i += size
path = []
def find(buf, start, end, chain):
    for off, size, typ in boxes(buf, start, end):
        if typ == b'stsd':
            # stsd: 8 hdr + 4 ver/flags + 4 count, then first sample entry
            entry = off + 16
            esize, etyp = struct.unpack('>I4s', buf[entry:entry+8])
            return chain + [(off, size)], entry, esize
        if typ in CONTAINERS:
            r = find(buf, off + 8, off + size, chain + [(off, size)])
            if r: return r
    return None
moov_after_mdat = data.find(b'moov') > data.find(b'mdat')
assert moov_after_mdat, 'moov must follow mdat so chunk offsets stay valid'
chain, entry, esize = find(data, 0, len(data), [])
# DOVIDecoderConfigurationRecord: major 1, minor 0, profile 8, level 1, rpu 1, el 0, bl 1, compat 1
profile, level = 8, 1
bits = (profile << 9) | (level << 3) | (1 << 2) | (0 << 1) | 1
payload = bytes([1, 0]) + struct.pack('>H', bits) + bytes([1 << 4]) + bytes(19)
box = struct.pack('>I4s', 8 + len(payload), b'dvcC') + payload
data[entry + esize:entry + esize] = box
struct.pack_into('>I', data, entry, esize + len(box))
for off, size in chain:
    struct.pack_into('>I', data, off, size + len(box))
open(dst, 'wb').write(data)
