# 夸克网盘(TV 端 OAuth)接口 — 本项目用到的部分

> 本文件是**夸克网盘 TV 端接口的唯一事实来源**,与 `API_CONTRACT.md`(Emby)、
> `BAIDU_PAN_API.md`(百度)、`PAN115_API.md`(115)平行。
> ⛔ 只用本文件列出的端点 / 参数 / 字段,不自行发明接口。
>
> **状态:已按本文件实现(`Core/Sources/Quark/`),文字部分仍按「调研稿 + 实测补记」对待。**
> 接入过程补了一批**无凭据实测**(2026-11-20),下文用【实测】标出 —— 它们只覆盖「不需要登录
> 就能观察到的服务端行为」(签名校验、错误码语义、轮询等待态、换 token 主机);
> 真正需要账号的那几项(列目录字段、直链能否 Range、时长单位)仍然**未实测**,见 §11。
>
> 标注规则(沿用 `PAN115_API.md`):
> - **【源码】** 开源实现里读到的原话(附 `仓库 路径:行号`),这是本文件最主要的事实来源 ——
>   夸克这套接口**没有官方文档**,开放平台那套是另一回事(见 §0)。
> - **【实测】** 亲手发请求看到的响应。截至 2026-11-20,**只做了无凭据的实测**(签名、错误码、
>   扫码轮询、换 token 主机);**带账号的实测一项都没有**(手里没有夸克账号),所以凡是涉及
>   目录内容 / 直链 / 时长的地方仍然只有【源码】与【推断】。
> - **【推断】** 无一手证据的判断,⛔ 不据此写代码。
>
> 取证仓库(`git clone --depth 1`,2026-11-20 拉取):
> - `OpenListTeam/OpenList` — `drivers/quark_uc_tv/`(主依据)、`drivers/quark_uc/`(网页 Cookie 版,对比用)
> - `H2orange/quarkDav` — `src/quarkTv.mjs` 等(独立移植,交叉验证用)
> 两个独立实现在端点 / 签名 / 常量上一致的地方,可信度更高。

## 0. 三套接口,不要混(为什么选 TV)

| | 开放平台 | 网页 Cookie | TV 端(**本文件**) |
|---|---|---|---|
| 主机 | `open-api-drive.quark.cn`(与 TV 共用域,但走 OAuth2 应用) | `drive.quark.cn/1/clouddrive` | `open-api-drive.quark.cn` |
| 认证 | AppID / SignKey OAuth2 | 网页 Cookie(F12 抓) | TV 扫码 → `access_token` + `refresh_token` |
| 文档 | 【推断】有但非面向个人(OpenList 实现走 `api.oplist.org` 中转续期,见 `drivers/quark_open/meta.go`) | 无 | 无,靠逆向 |
| 播放 | — | ⛔ 限速,必须本地代理中转 | **可拿 302 直链 / 转码直链** |
| 写操作 | — | 有 | ❌ 全部不支持(§9) |
| 本项目 | ⛔ 不用 | ⛔ 不用 | ✅ 只用它 |

**为什么不用网页 Cookie**:OpenList 文档明确写着「由于夸克网盘限速问题,夸克网盘现在只能使用本地代理进行传输」[来源](https://doc.oplist.org/guide/drivers/quark);
AList 文档也说原始下载链路「依赖请求头、账号状态和服务器带宽,普通下载路径下本地代理依然是兼容性最好的选择」[来源](https://alistgo.com/zh/guide/drivers/quark.html)。
对本项目(播放器跑在用户 Mac 上)来说,本地代理等于「夸克先限速下载到 Mac、再喂给 libmpv」,体验不可接受。
⇒ 只走 TV 端,拿直链交给内核。

> 上表「开放平台」列整体属【推断】:一手只看到 OpenList `drivers/quark_open` 用
> `https://open-api-drive.quark.cn` + `https://api.oplist.org/quarkyun/renewapi` 做续期,
> 未拿到官方开放平台的文档页或注册入口。⛔ 不据此实现开放平台接入。

⚠️ **TV 端的代价**:只有「访问 / 列目录 + 取直链」两个能力,没有上传 / 改名 / 删除 / 移动 / 建目录(§9)。
这与「完全对齐百度 / 115 网盘源」的目标**冲突** —— 见 §9 的取舍建议。

## 1. 常量与主机

【源码:`OpenList/drivers/quark_uc_tv/meta.go:41-48`】

| 项 | 值 | 备注 |
|---|---|---|
| `api` | `https://open-api-drive.quark.cn` | 业务主机 |
| `codeApi` | `http://api.extscreen.com/quarkdrive` | **第三方**服务,换 token 用;⚠️ 明文 HTTP。**本项目改用 `https://`**,见下方【实测】|
| `clientID` | `d3194e61504e493eb6222857bccfed94` | 与签名绑定 |
| `signKey` | `kw2dvtd7p4t3pjl2d9ed9yc8yej8kw2d` | 签名密钥 |
| `appVer` | `1.8.2.2` | ⚠️ quarkDav 用 `1.5.6`(见下) |
| `channel` | `GENERAL` | ⚠️ quarkDav 用 `CP`(见下) |
| 默认根 `fid` | `0` | |

【源码:`H2orange/quarkDav/src/quarkTv.mjs:9-16`】用的是 `appVer: '1.5.6'`、`channel: 'CP'`,
其余常量与 OpenList 一致。两份独立实现取值不同 —— **【推断】** 这两个字段可能不参与签名、
只是上报值,所以两边都能跑;⛔ 不要自己折中取值,接入时先固定用 OpenList 那套并实机验证。

**【实测】换 token 主机支持 https(2026-11-20)**:同一个 `api.extscreen.com/quarkdrive/token`,
`http://` 与 `https://` 返回**完全一致**的响应体(`{"code":200,…,{"errno":11004,"error_info":"授权码Code无效"}}`
与 `errno 11000 Refresh Token无效` 都复现)。⇒ 本项目用 `https://`:
明文 HTTP 会被 ATS 直接拦下、还要给整个 App 开例外,收益为零。⛔ 不要改回 http。

**【实测】`appVer` / `channel` 不参与服务端校验**:把 `app_ver` 改成 `9.9.9`、`channel` 改成 `FOO`,
业务请求的判定结果与 `1.8.2.2 / GENERAL` 完全相同(都回 `11001 Access Token无效`)。
⇒ §1 里「两份实现取值不同」的疑问解决了:它们只是上报值,不影响可用性。本项目固定用 OpenList 那套。

**【实测】签名确实被服务端校验**:签名头全缺 → `errno 10001 公参缺失，x-pan-client-id, x-pan-tm, x-pan-token不能为空`;
`x-pan-token` 填 64 个 0 → `errno 10001 签名验证失败，禁止访问`。

设备指纹(所有请求都带,【源码:`OpenList/drivers/quark_uc_tv/util.go:22-32`】):

```
User-Agent:    Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2004J7AC Build/UKQ1.231108.001) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1
device_brand:  Xiaomi
platform:      tv
device_name / device_model / build_device / build_product: M2004J7AC
device_gpu:    Adreno (TM) 550
activity_rect: {}
```

- `device_id`:首次生成 `md5(now.String())`(OpenList)或 32 位随机 hex(quarkDav),**必须持久化** ——
  它参与 `req_id` 与 token 刷新,换了就要重新登录【源码:`driver.go:37-39`、`quarkTv.mjs:33-35`】。
- `User-Agent` 与设备指纹看起来是服务端识别「TV 客户端」的依据,⛔ 不要改成 Mac Safari。

## 2. 签名算法(每个业务请求都要)

【源码:`OpenList/drivers/quark_uc_tv/util.go:204-223`】,【源码:`quarkDav/src/quarkTv.mjs:49-55`】交叉确认:

```
timestamp = 当前毫秒时间戳(13 位十进制字符串)
req_id    = md5(device_id + timestamp)                       → 32 位小写 hex
x-pan-tm  = timestamp                                         (请求头)
x-pan-token = sha256(method + "&" + pathname + "&" + timestamp + "&" + signKey)
                                                              → 64 位小写 hex(请求头)
```

- `method` 用**大写 HTTP 方法**字符串(`GET` / `POST`),`pathname` 是**不含查询串**的路径(如 `/file`)。
- `x-pan-token` 与 `req_id` 都放进请求头 / 查询串:
  - 请求头:`x-pan-tm`、`x-pan-token`、`x-pan-client-id`、`Accept`、`User-Agent`;
  - 查询串:`req_id`、`access_token`、`app_ver`、`device_id` 等全部设备字段 + `channel`。

⚠️ `sha256` 的入参是**字符串拼接**,不是 URL 编码后的结果;⛔ 不要加空格或改大小写。
⚠️ Swift 侧用 `CryptoKit` 的 `MD5` / `SHA256` 即可,不需要第三方库。

## 3. 通用信封与 token 失效判定

【源码:`OpenList/drivers/quark_uc_tv/types.go:10-19`】

```json
{"status": 0, "errno": 0, "error_info": "", "req_id": "..."}
```

- 成功:`status == 0` 且 `errno == 0`(`errno` 缺失按 0 处理,【源码:`quarkTv.mjs:96`】)。
- 失败:`status >= 400` 或 `errno != 0`,取 `error_info`。
- **token 失效判定**:

  ⚠️ **【实测】这里必须纠正 OpenList 的推断**。文档原稿照抄了 `util.go:74-91` 的
  「`errno ∈ {10001, 11001}` 就当 token 过期」,2026-11-20 的实测证明**这两码语义完全相反**:

  | 码 | 实测响应 | 真实含义 | 处置 |
  |---|---|---|---|
  | `10001` | `签名验证失败，禁止访问` / `公参缺失，x-pan-client-id, x-pan-tm, x-pan-token不能为空` | **签名或公共参数不对** | ⛔ **不要刷新 token**(刷新也治不好),如实报错 |
  | `11001` | `Access Token无效` | access_token 过期 / 无效 | ✅ 刷新一次,重试一次 |

  第三方整理文档(2026-08 版)对这两个码的描述与本次实测一致,可作为交叉印证。
  ⇒ 本项目只对 `11001` 刷新,⛔ 不对 `10001` 刷新;`error_info` 的文案匹配也不再用
  (它与码一一对应,匹配文案反而会把「签名失败」误判成「token 失效」)。

处理:用 `refresh_token` 刷一次 → **重试原请求一次**(带 10 秒超时)。
⚠️ 刷新后 `refresh_token` 本身也会被轮换(响应里给新的),新的必须落盘;
⚠️ 只重试**一次**,`isRetry` 为真仍失败就抛错(【源码:`quarkTv.mjs:98-101`】),⛔ 不循环。

## 4. OAuth 扫码登录(四步)

全部【源码:`OpenList/drivers/quark_uc_tv/util.go:99-193`】+【源码:`driver.go:47-80`】:

```
1. GET  {api}/oauth/authorize
       ?auth_type=code&client_id=<clientID>&scope=netdisk
       &qrcode=1&qr_width=460&qr_height=460
   → { "status":0, "qr_data":"<base64 图片>", "query_token":"<qt>" }
   ⚠️ qr_data 是图片本身(base64),不是要编进二维码的内容 —— 直接用。

2. 手机夸克 App 扫 qr_data 并在手机上确认。
   ⚠️ 服务端在两步之间没有「状态查询」端点:客户端拿 query_token 反复调第 3 步。
   【源码:quarkDav/src/app.mjs:250-275 + consoleHtml.mjs 的 poll()】前端每 2 秒
   调一次 /api/login/status(内部就是第 3 步),直到成功或用户放弃。
   【推断】「未确认 / 未扫码 / 等待 / pending / scan / 无效 / 过期」这类 error_info
   表示"继续等",quarkDav 用正则判断;⛔ 这不是官方语义,实机要核对文案。

3. GET  {api}/oauth/code
       ?client_id=<clientID>&scope=netdisk&query_token=<qt>
   → { "status":0, "code":"<授权码>" }
   ⚠️ OpenList 在 Init() 里只调一次;quarkDav 靠前端轮询 —— 接入必须实现轮询,
   否则用户扫码后永远拿不到 code。
   ✅ **【实测】未确认时返回 `HTTP 400 {"status":-1,"errno":11003,"error_info":"用户未确认授权"}`**
   —— 这就是「继续等」的信号,⛔ 不要把它折成失败。反复调用不会让二维码失效。
   **【实测】`query_token` 失效时**返回 `errno 11002 授权码Code二维码过期`;
   完全不传则回 `errno 14001 query_token不允许为空`。

4. POST {codeApi}/token            ← 注意是第三方主机、明文 HTTP
   Content-Type: application/json
   body: { req_id, app_ver, device_id, device_brand, platform, device_name,
           device_model, build_device, build_product, device_gpu,
           activity_rect, channel, code: "<第3步的 code>" }
   → { "code":200, "message":"", "data":{
         status, errno, error_info, req_id,
         access_token, refresh_token, expires_in, scope } }
   ⚠️ 外层 code==200 只是"受理",内层 data.status==-1 / data.errno!=0 才是真失败
      (如 data.errno=11004「授权码Code无效」)【源码:quarkTv.mjs:138-143】。
```

**刷新**走同一个 `{codeApi}/token`,只是 body 里把 `code` 换成 `refresh_token`
(【源码:`util.go:148-193`】的 `isRefresh` 分支);`data.refresh_token` 为空视为失败。
`expires_in` 有给,但两份实现都不用它做定时刷新,而是靠请求失败触发(§3)。
⚠️ 本项目照这个「失败触发」模式,⛔ 不要另起定时器提前刷新 —— 刷新请求发到第三方明文
HTTP,少一次调用少一次暴露面。

⚠️ **凭据存哪里**:`access_token` / `refresh_token` / `device_id` / `query_token` 四件套,
必须放进现有 `CredentialStore`(走 Keychain 通道),⛔ 不进 `UserDefaults`、日志、诊断文件;
日志里的完整 URL 经 `SecretRedactor` 脱敏(`access_token` 在查询串上,极易漏)。

## 5. 列目录

【源码:`OpenList/drivers/quark_uc_tv/driver.go:94-135`】

```
GET {api}/file
    ?method=list
    &parent_fid=<目录fid,根目录为 "0">
    &order_by=1|3          // 1=文件名, 3=更新时间(默认)
    &desc=0|1              // 0=升序, 1=降序(默认)
    &category=&source=&ex_source=
    &list_all=0
    &page_size=100
    &page_index=<从 0 开始>
```

- 响应:`{ status, errno, data:{ total_count, files:[...] } }`。
- 分页终止:`page_index * page_size >= total_count` 即停(OpenList 的做法);
  quarkDav 多加一条 `files.length === 0` 的兜底(【源码:`quarkTv.mjs:203-207`】)——
  ✅ 本项目采用带兜底的版本,防止 total_count 异常时死循环。
- ⚠️ 下一页用 `page_index + 1`,不是用已解码条数推进(与百度/115 的坑同类)。
- 频控:两份参考实现都没有显式限速 / 重试退避。**【推断】** TV 端频控可能比网页端宽松,
  但本项目仍按「串行 + 至少 500ms 间隔」处理(与 `PAN115_API.md §6` 同口径),
  ⛔ 不做并发批量请求、不做后台预取。

### 5.1 文件条目字段(`data.files[]`)

【源码:`OpenList/drivers/quark_uc_tv/types.go:35-49`】

| 字段 | 类型 | 含义 / 本项目用途 |
|---|---|---|
| `fid` | string | 文件/目录 ID,取直链、进子目录都用它(等价百度 `fs_id`、115 `fid`) |
| `parent_fid` | string | 所在目录 ID |
| `filename` | string | 名字 |
| `size` | int64 | 字节;目录可能为 0 |
| `isdir` | int | `1` = 目录,`0` = 文件 |
| `category` | int | `1` = 视频(取直链时据此判断,见 §6) |
| `duration` | int | 时长(秒)。⚠️ 单位没有一手证据,【推断】是秒,接入后实机核对 |
| `file_type` | string | 文件类型 |
| `sub_items` | int | 子项数(可选) |
| `created_at` / `updated_at` | int64 | **毫秒**时间戳(`types.go:59-67` 用 `time.Unix(0, v*1e6)`) |
| `thumbnail_url` | string | 缩略图(可选) |
| `is_backup` | int | — |

- ⚠️ 时间戳是**毫秒**,和百度(秒)、115(秒)都不同,解码后要 `/1000` 再转 `Date`。
- ⚠️ `GetPath()` 返回空串 —— TV API 不提供路径,只有 `fid` 树。

### 5.2 没有路径这件事怎么处置(**实现决定**)

原稿说「所有按路径做的事都要改成按 `fid` 组织」。实现时换了个做法,理由与本地文件夹那套一致
(`Core/Sources/LocalFolder/LocalFolderListing.swift`):

**由客户端按 fid 树现拼一份虚拟路径**(`Core/Sources/Quark/QuarkPath.swift`)。
条目在来源内的 id = `SHA-256(来源 id + "quark|" + 虚拟路径)` 前 8 字节,
喂给现有的 `BaiduPanFile.fsID`,于是续播 / 隐藏 / 刮削缓存 / 弹幕与片头片尾的键
**一行都不用改**,也不用把 `SourceItem` 的 id 从数字改成字符串(那会波及全部来源)。

代价(与本地文件夹同一条已知限制,记在 `KNOWN_ISSUES.md`):
- **网盘里改名 / 挪目录 → id 变**,旧的续播记录与刮削缓存跟不过去;
- 路径 → `fid` 的换算靠 `QuarkConnection` 的内存索引;冷启动直接播某条续播记录时要从根按路径
  走一遍(每层一次请求,间隔 ≥ 500ms),浏览过的目录都在索引里,所以正常浏览不额外花请求;
- 取直链的接口因此按**路径**收参数,⛔ 不收 `fsID`(那是哈希,反推不回 `fid`)。

## 6. 取播放直链

### 6.1 原文件直链 `method=download`(默认,推荐)

【源码:`OpenList/drivers/quark_uc_tv/util.go:254-274`】

```
GET {api}/file
    ?method=download
    &group_by=source
    &fid=<文件fid>
    &resolution=low,normal,high,super,2k,4k
    &support=dolby_vision
→ { status, errno, data:{ fid, file_name, size, download_url } }
```

`download_url` 就是给 libmpv 的地址:普通 https,内核自己跟 302、自己发 `Range`。
⚠️ 地址原样采用,⛔ 不经 `PlaybackURLBuilder`、⛔ 不用 `URLComponents.queryItems` 往返
(会改签名参数,与 `PAN115_API.md §4.3`、`BAIDU_PAN_API.md §2.2` 同一个坑)。

- 是否要带请求头(TV 端 `User-Agent` / token):**【推断】未知**。两份参考实现都直接把
  URL 丢给下载器 / 302 跳转,没额外挂头,推测 URL 自带签名的 CDN 直链不需要。
  ⇒ 实机验证:不带任何头能否直接 Range 播放;若 403 再按响应补头,⛔ 不预先塞一堆头。

### 6.2 转码直链 `method=streaming`

【源码:`OpenList/drivers/quark_uc_tv/util.go:225-252`】

```
GET {api}/file
    ?method=streaming
    &group_by=source
    &fid=<文件fid>
    &resolution=low,normal,high,super,2k,4k
    &support=dolby_vision
→ data.video_info[]: { resolution, accessable, trans_status, duration,
                       size, format, width, height, url, bitrate,
                       dolby_vision:{profile,level} }
   data.audio_info[]
   data.default_resolution, data.last_play_time
```

- 取第一个 `url` 非空的 `video_info` 条目,它的 `size` 作为 Content-Length。
- 只有 `video` 类文件(`category == 1`)且 `size > 0` 才走这条(【源码:`driver.go:140-144`】),
  由 `VideoLinkMethod == "streaming"` 开关控制,默认 `download`。
- ⚠️ 转码流**不是原画**,分辨率由服务端决定;⚠️ `trans_status` 的取值与含义没有一手证据,
  【推断】未转完时 `url` 可能为空或页数不全,接入后要按"取不到 url 就回退 download"处理。
- ⚠️ 社区有「夸克网盘 302 转码直链播放失败,`plf_invalid`」的反馈[来源](https://github.com/Cp0204/SmartStrm/issues/57),
  ⇒ streaming 路径必须带 fallback 到 download,⛔ 不能当唯一路径。

### 6.3 播放决策映射(对齐现有网盘源)

✅ 已按下面这条实现(`Core/Sources/Quark/QuarkPlayback.swift`):
- `supportsTranscoding: false`,`headers` 恒空(TV 端直链自带签名,§6.1);
- 有起流位置就抛 `playbackUnsupported`(静态文件没有起流参数);
- 每次 `makeSession` 都重新取链(直链是死 URL)。

照 `Pan115Playback.swift` / `BaiduPanPlayback.swift` 的模式:
- 新建 `QuarkPlaybackPlanner`,把文件 + 直链合成 `EmbyPlaybackInfoResponse` 形状去问
  `PlaybackDecisionEngine`,只借形状,地址由夸克给;
- `supportsDirectStream: true`,`supportsTranscoding: false`(本项目不实现第二条转码路径,
  streaming 直链本身也是当 DirectStream 喂给内核的 —— 它就是个静态流地址);
- `PlaybackPlan.directStream(url:headers:...)`,`seekStrategy: .clientSeek`;
- ⛔ 不填 `MediaStreams`(TV API 不给轨道级编码信息,不虚构)。

## 7. 用户态校验

【源码:`OpenList/drivers/quark_uc_tv/util.go:195-202`】

```
GET {api}/user?method=user_info
```

只为验证 `access_token` 是否有效,没有其它用途。⚠️ 与 115 不同,这里**没有**「会踢设备」
的探活端点,登录态校验是安全的;但本项目仍按最小调用原则,只在启动时校验一次。

## 8. 错误码与边界

下表全部是 **2026-11-20 实测**(无凭据打出来的响应原话),不是从别处抄的:

| 码 / 信号 | 实测 `error_info` | 含义 | 本项目处置 |
|---|---|---|---|
| `status=0, errno=0` | — | 成功 | — |
| `errno=10001` | `签名验证失败，禁止访问` / `公参缺失，x-pan-client-id, x-pan-tm, x-pan-token不能为空` | 签名 / 公共参数不对 | 如实抛错,⛔ **不刷新 token**(§3) |
| `errno=11001` | `Access Token无效` | access_token 失效 | 刷新一次,重试一次(§3) |
| `errno=11002` | `授权码Code二维码过期` | `query_token` 失效 | 抛「二维码过期,请重新获取」 |
| `errno=11003` | `用户未确认授权` | 扫码轮询的**正常等待态** | 继续轮询,⛔ 不算失败 |
| `errno=11004`(内层) | `授权码Code无效` | 换 token 时 code 不可用 | 重新扫码,⛔ 不重试同一个 code |
| `errno=11000`(内层) | `Refresh Token无效` | 刷新令牌也失效 | 重新扫码 |
| `errno=14001` | `参数错误: [access_token不能为空]` / `query_token不允许为空` | 必填参数缺失 | 如实抛错(本项目自己的 bug) |

- ❗ `expires_in` 的具体秒数、token 是否单次使用、刷新是否轮换 refresh_token ——
  响应里有 `expires_in` 字段但**没有一手证据**说明其语义,【推断】同 OAuth 惯例;
  ⛔ 不据此实现定时刷新。
- ❗ **目录不存在没有可用的错误码**:TV 端没有公开的响应样本。本项目因此**不猜码**,
  只在「按虚拟路径解析 fid 时确实没找到那一层」时报 `directoryNotFound` 并回落网盘根(§5.1)。
- ❗ 二维码 / `query_token` 有效期未知,【推断】与常见扫码登录同量级(分钟级);
  本项目自己定 180 秒上限,超时提示换一张。
- ❗ 直链 URL 的有效期未知,【推断】CDN 签名链接通常有时效;若播到一半 403,
  按 115 的做法「重取一次直链,再失败就报错」,⛔ 不循环重试。

## 9. 能力边界 —— 与「完全对齐现有网盘源」的冲突

【源码:`OpenList/drivers/quark_uc_tv/driver.go:147-169`】TV 驱动里:

| 操作 | 实现 |
|---|---|
| `MakeDir` / `Move` / `Rename` / `Copy` / `Remove` / `Put` | 全部 `return nil, errs.NotImplement` |
| 配置 | `NoUpload: true`,`NoOverwriteUpload: true`(`meta.go:35-40`) |

⇒ **TV 端只有读能力**。这意味着「完全对齐百度/115」(刮削缓存、追剧、重命名、删除、
上传)在 TV 端**做不到**。可选的取舍:

1. **第一版只读对齐**:浏览 + 播放 + 刮削/追剧/续播/弹幕(这些都是客户端侧能力,不依赖服务端写)
   —— ✅ **已采用**。实现上体现为三处:
   - `FileSource.supportsDeletingFiles` = `false`(界面只给「隐藏」,不给「同时删除网盘文件」);
   - `FileSource.supportsRenamingSeries` = `false`(没有按 TMDB 重命名整部剧);
   - 绕过界面直接调 `FileSourceViewModel.delete(alsoDeleteRemotely: true)` 会抛
     `QuarkError.invalidRequest`,并且**一个请求都不发**。
   UI 里必须写明这是只读来源(来源设置页与扫码屏都有,§10 的合规提示同处)。
2. 要写操作就必须再接一套**网页 Cookie 接口** —— 但那会重新引入限速(§0),
   且两套凭据/两套端点混在一个来源里,复杂度高;⛔ 本阶段不做,登记在 `KNOWN_ISSUES.md`。

## 10. 频控、风控与合规

- 频控:两份参考实现都没有退避逻辑;本项目仍按「串行 + ≥500ms 间隔」保守处理(§5)。
- **第三方明文 HTTP**:换 token 走 `http://api.extscreen.com/quarkdrive` —— 这是
  **第三方服务**,不是夸克官方域名,而且是明文。意味着:
  - 登录态要经过一个中间服务;⛔ 不要把它当成可信通道;
  - UI 必须明确告知用户这一点(与 `PAN115_API.md §8` 的「非官方接口、风险自负」同类)。
- 合规:夸克没有面向个人的开放 API,这套是逆向 TV 接口。❗ 用户协议是否禁止
  「非授权客户端 / 接口」尚未逐条核对一手条款,【推断】与 115 类似存在风险。
  ⇒ 添加夸克来源的 UI 必须写明:非官方接口、token 经第三方服务、风险自负。
  ✅ 已落在 `QuarkAuthorizationView` 的警告块里(含「换 token 经过第三方服务」与「只读」两句)。
- ⚠️ 签名常量(`clientID` / `signKey`)来自开源实现的硬编码值,可能随客户端版本更新失效;
  接口整体属于「能用但随时可能变」,⛔ 不当作稳定依赖。

## 11. 待实测清单

> 2026-11-20 的第一轮是**无凭据实测**,它结掉了下面前 3 项里属于「不需要账号」的部分。
> 带账号的那几项**一项都没验**(手里没有夸克账号),所以下面标 ❌ 的仍然必须实机验证。

| # | 项 | 状态 |
|---|---|---|
| 1 | `appVer` / `channel` 哪套可用 | ✅ 实测:**两者都不参与校验**(`9.9.9/FOO` 与 `1.8.2.2/GENERAL` 结果一致)。固定用 OpenList 那套 |
| 2 | 扫码轮询里哪些 `error_info` 表示「继续等」 | ✅ 实测:`errno 11003 用户未确认授权` 就是等待态;`11002` 才是过期 |
| 3 | 换 token 主机能不能走 https | ✅ 实测:能,响应与 http 完全一致。本项目用 https |
| 4 | `10001` vs `11001` 的语义 | ✅ 实测:`10001` = 签名 / 公参被拒,`11001` = token 失效(§3 已纠正 OpenList 的推断) |
| 5 | `download_url` 不带任何请求头能否 Range 播放 | ❌ 要真账号 + 真文件 |
| 6 | `duration` 的单位(秒 / 毫秒) | ❌ 未验。所以本项目**不用它**(不写进时长,显示由内核探) |
| 7 | `created_at` / `updated_at` 是否确为毫秒 | ⚠️ 只有【源码】(`types.go:59-67` 的 `time.Unix(0, v*1e6)`);解码按毫秒实现 |
| 8 | `streaming` 的 `trans_status` / 回退 download | ❌ 未验,且本项目**不实现** streaming(§6.2) |
| 9 | 直链有效期、token / `query_token` 有效期 | ❌ 未验。token 走「失败触发刷新」,`query_token` 用本项目自定的 180 秒 |
| 10 | 刷新是否轮换 `refresh_token` | ⚠️ 参考实现都按「轮换」处理并且落盘;响应字段形状已实测(`data.refresh_token`),**轮换本身**未验 |
| 11 | 实际频控阈值 | ❌ 未验。本项目按「串行 + ≥500ms」保守处理(§5) |
| 12 | 目录不存在回什么码 | ❌ 无样本。所以本项目不猜码,只在按路径解析失败时报 `directoryNotFound`(§8) |

实测方式:用真实夸克账号,只读、低频、单次;结果回填到本文件对应小节。
