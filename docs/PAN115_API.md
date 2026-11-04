# 115 网盘(网页 Cookie 版)接口(本项目用到的部分)

> 本文件是 **115 网盘接口的唯一事实来源**,与 `API_CONTRACT.md`(Emby)、`BAIDU_PAN_API.md`(百度)平行。
> 硬规则同 CLAUDE.md 1:**禁止发明接口**,只用本文件列出的端点 / 参数 / 字段。
>
> 标注规则:
> - **【源码】** 开源实现里读到的原话(附 `仓库 路径:行号`),这是本项目最主要的事实来源 ——
>   115 这套接口**没有官方文档**,开放平台那套是另一回事(见 §1)。
> - **【实测】** 本次亲手发请求看到的响应(2026-11-02,无凭据、只读、单次)。
> - **【推断】** 无一手证据的判断,⛔ 不据此写代码。
>
> 取证仓库(全部 `git clone --depth 1`):
> - `SheltonZhu/115driver`(Go,OpenList 的 115 Cloud 驱动依赖它)
> - `OpenListTeam/OpenList`(`drivers/115`)
> - `ChenyangGao/p115client`(Python,docstring 就是接口字典,最详细)
> - `OpenListTeam/115-sdk-go`(Go,官方**开放平台** SDK —— 与本文的 Cookie 接口无关,仅用于对比)

## 0. 两套接口,不要混

| | 开放平台 | 网页 Cookie(**本项目用这套**) |
|---|---|---|
| 认证 | OAuth2(PKCE 设备码 / 授权码),`Authorization: Bearer <access_token>` | Cookie 四件套 `UID/CID/SEID/KID` |
| 主机 | `proapi.115.com/open/*` | `webapi.115.com` / `proapi.115.com/app/*` / `passportapi.115.com` |
| 文档 | 官方 42 篇(语雀 `115yun/open`) | **无官方文档**,靠逆向 |
| 现状 | 2026-08-09 起「服务调整优化」,新 AppID 自 2026-04 停止审核 | 未受影响,消费级播放器全部走它 |
| 本项目 | ⛔ 不用 | ✅ 用 |

⚠️ **开放平台的端点一个都不要用**。`open.115.com` 与 `proapi.115.com/open/*` 是另一套协议,
混用会得到 `40140123 access_token 格式错误`。

## 1. 主机分工

| 主机 | 用途 |
|---|---|
| `webapi.115.com` | 列目录、文件详情、搜索、移动/复制/改名/删除、`files/video`(视频信息 + 转码状态) |
| `aps.115.com` | 自然排序列表 `natsort/files.php` |
| `proapi.115.com` | 取下载直链 `/app/chrome/downurl`;App 版 `/2.0/ufile/download` |
| `passportapi.115.com` | 扫码登录换 Cookie、登录态校验 |
| `qrcodeapi.115.com` | 二维码 token 与状态轮询 |
| `appversion.115.com` | 取 115Browser 版本号(拼 UA 用) |
| `my.115.com` | Cookie 有效性检查、用户信息 |
| `115.com` | 网页版 m3u8、`?ct=download&ac=video` 302 |
| `*.115cdn.net` | 最终 CDN 直链(不自己拼,只从响应里取) |

**没有 WebDAV**:`dav.115.com` / `webdav.115.com` 的 DNS 不解析【实测】。

## 2. 认证:Cookie 四件套

```swift
struct Pan115Credential {  // 顺序与拼装方式见 §2.1
    let uid: String
    let cid: String
    let seid: String
    let kid: String?
}
```

`115driver pkg/driver/login.go:86-91`【源码】:
```go
type Credential struct {
    UID  string `json:"UID"`
    CID  string `json:"CID"`
    SEID string `json:"SEID"`
    KID  string `json:"KID"`
}
```
`:94-119` `FromCookie` 按 `;` 切分、key 转大写,**UID/CID/SEID 缺一即 `ErrBadCookie`**;
源码注释「// No need to verify the KID for those old cookies」⇒ KID 可缺。
`:122-124` 拼回 `UID=%s;CID=%s;SEID=%s;KID=%s`。domain 是 `.115.com`(`consts.go` `CookieDomain115`)。

### 2.1 `UID` 不是纯数字

它是 `user_id_ssoent_timestamp` 三段拼接,中间的 `ssoent` 决定 115 把你当成哪个客户端。
`p115client p115client/type.py:39-48` `class P115UID` 按 `uid.split("_")` 拆三段;
`p115client/const.py:49-75` `APP_TO_SSOENT` 全表【源码】:

| app | ssoent | app | ssoent |
|---|---|---|---|
| `web` / `desktop` | `A1` | `os_windows` | `P1` |
| `android` | `F1` | `os_mac` | `P2` |
| `115android` | `F3` | `os_linux` | `P3` |
| `ios` | `D1` | `wechatmini` | `R1` |
| `ipad` | `H1` | `alipaymini` | `R2` |
| `tv` | `I1` | `harmony` | `S1` |
| `apple_tv` | `I2` | `qandroid` | `M1` |
| `qios` | `N1` | | |

⚠️ 本项目**只用 `web`(A1)**。`os_windows` / `os_mac` / `os_linux` 的 Cookie 走的是另一套加密(§4.2),
而且 **115 已下架 Windows/Mac/Linux 三端客户端**,用这三端 Cookie 会返回
`{"state":0,"error":"登录失败，系统已下架！…"}`【源码:OpenList `drivers/115` 文档】。

### 2.2 扫码登录(四步)

```
1. GET  https://qrcodeapi.115.com/api/1.0/{app}/1.0/token
        → {"state":1,"code":0,"data":{"uid":"…","time":<unix>,"sign":"…","qrcode":"https://115.com/scan/…"}}

2. GET  https://qrcodeapi.115.com/api/1.0/mac/1.0/qrcode?uid=<uid>
        → 二维码 PNG 字节

3. GET  https://qrcodeapi.115.com/get/status/?uid=<uid>&time=<time>&sign=<sign>&_=<ms>
        → status: 0 待扫 / 1 已扫待确认 / 2 确认可换 Cookie / -1 过期 / -2 取消

4. POST https://passportapi.115.com/app/1.0/{app}/1.0/login/qrcode
        form: account=<uid>&app=<app>
        → {"state":1,"data":{"cookie":{"UID":"…","CID":"…","SEID":"…","KID":"…"}}}
```

出处【源码】:`115driver pkg/driver/qrcode.go:32-43`(token)、`:85-109`(status 语义)、
`:68-83`(login)、`:120-137`;`pkg/driver/api.go:55-59`;四件套解包在 `response.go:315-338`。

⚠️ **第 4 步的 `account` 用的是第 1 步 token 响应里的 `uid`,不是 Cookie 里的 UID。** 两者不同。
⚠️ 第 1、2、4 步的 `{app}` 必须一致;`web` / `android` / `ios` / `tv` / `alipaymini` / `wechatmini` / `qandroid` 可用,
`mac` / `windows` / `linux` 在源码里被注释掉(disabled)。本项目用 `web`。
⚠️ 第 2 步路径里的 `mac` 是**写死的**,与 `{app}` 无关(`115driver` 就是这样,`api.go:59`)。

【实测】2026-11-02 第 1 步(无凭据)返回:
```json
{"state":1,"code":0,"data":{"uid":"…","time":1793603418,"sign":"…","qrcode":"https://115.com/scan/dg-…"}}
```
⇒ 接口活着。第 3 步用伪造参数返回 `{"state":0,"code":40199002,"message":"key invalid"}`。

### 2.3 踢设备 —— ⛔ 两种探活都不能用

两个参考实现各有一个「检查登录态」的函数,区别只在会不会踢人:

| 函数 | 端点 | 会踢掉其它设备吗 |
|---|---|---|
| `CookieCheck()` | `GET https://my.115.com/?ct=guide&ac=status&_=<ms>` | **不会**。只读 `{"state":bool}` |
| `LoginCheck()` | `GET https://passportapi.115.com/app/1.0/web/1.0/check/sso` | **会** |

`115driver pkg/driver/login.go:13-25`(CookieCheck)、`:28-39`(LoginCheck)【源码】。

`p115client client.py:20560-20562` 的 `check/sso` docstring【源码】:
> 检查当前 cookies 的登录状态信息,**并且自最近一次登录的 60 秒后,使当前设备下除最近一次登录外的所有 cookies 失效**

⇒ **踢设备是「检查」这个动作触发的**。OpenList 的坑就在 `drivers/115/util.go:59` ——
登录最后调的是 `LoginCheck()`,所以它会踢掉用户浏览器里的会话。
**本项目⛔ 两个都不调**:Cookie 失效会在第一次真正读盘时暴露(`webapi.115.com/files` 回
`errno 990001` / `40101035`),那时浏览页直接切到扫码屏即可。少一次请求就少一分风控面(§6),
而「主动探活」换不来任何用户可见的收益。错误码 `40101035` 文案:`you have been kicked out by multi-device login management`。

登录态唯一的请求是 `GET https://my.115.com/?ct=ajax&ac=nav&_=<ms>`(扫码成功后取一次昵称 / VIP,
`115driver pkg/driver/login.go:126-133`、`response.go:235-254`)【源码】。

## 3. 列目录

```
GET https://webapi.115.com/files
    ?aid=1&cid=<目录ID>&o=&asc=&offset=<n>&show_dir=1&limit=<n>
    &snap=0&natsort=0&record_open_time=1&format=json&fc_mix=0
```

参数表出处【源码】:`115driver pkg/driver/dir.go:120-133`。

- **`limit` 上限 1150**,三处独立证据:`dir.go:35` `MaxDirPageLimit = 1150`;
  `OpenList drivers/115_open/driver.go:58-65` 硬截 1150;p115client docstring「目前最大值是 1,150」。
- **根目录 cid 是 `0`**(不是网页 URL 里那个长数字 —— 那个是某个具体目录)。
- 响应字段(`115driver pkg/driver/response.go:90-109` + `p115client tool/attr.py`【源码】):

| 字段 | 含义 |
|---|---|
| `cid` | 目录 ID(文件条目上是它所在目录) |
| `fid` | 文件 ID。**空 = 这是目录** |
| `n` | 名字 |
| `s` | 大小(字节,字符串) |
| `pc` | **pick_code**,取直链就靠它 |
| `sha` | sha1 |
| `te` | **修改时间,unix 秒整数**。⛔ 不是日期字符串 —— `p115client tool/attr.py:245-246` 直接 `int(info["te"])`;`115driver` 的 `FileInfo` 里没有这个字段,以 p115client 为准。日期字符串那个是 `t`(创建时间) |
| `iv`(web)/ `isv`(app) | 是否视频,`1`/`0` |
| `ispl` | 是否统计目录下视频时长 |

⚠️ `show_thumb` / `type` / `star` **在 `115driver` 里不存在**(grep 零命中),别照 p115client 的 docstring 编。

【实测】无 Cookie:`https://webapi.115.com/files?cid=0&limit=3` 返回阿里云 WAF 405 错误页;
`https://aps.115.com/natsort/files.php?aid=1&cid=0&limit=3` 返回
`{"state":false,"error":"请先登录","request":"/natsort/files.php?aid=1&cid=0&limit=3"}`。

### 3.1 `count` 是目录总条目数(不是本页条数)

响应外层还有 `count` / `offset` / `limit` 三个回显字段(`115driver` 的 `FileListResp`、
`115-sdk-go` 的 `GetFilesResp` 都有)。**`count` 的语义是「该目录的总条目数」**,四路独立证据:

1. **官方开放平台 Go SDK** `115-sdk-go` `fs.go:86-91` 带官方中文注释:
   ```go
   Count int64 `json:"count"`     // 当前目录文件数量
   ```
2. `115driver pkg/driver/dir.go` `ListWithLimit()` 用 `result.Count` 当终止条件:
   `offset = int64(result.Offset) + limit; if offset >= int64(result.Count) { break }`
3. `OpenList drivers/115_open/driver.go:103-131`:`if len(res) >= int(resp.Count) { break }`
4. `p115client tool/attr.py` `get_file_count()` —— 专门取目录内文件总数:
   用 `page_size=1` **只取一条**却从 `count` 读出总数。⇒ `count` 不可能是「本次返回条数」。

⇒ **本项目用 `count` 精确判断「还有没有下一页」**,⛔ 不必靠「不满页」猜。
⚠️ 与百度的关键差别:百度的 `method=list` **没有**任何总数字段(`BAIDU_PAN_API.md` §7.2)。

⚠️ 两条边界:
- `count` 是**当前查询条件下**的总数。`show_dir` / `nf` / `type` / `suffix` 等过滤参数
  会改变它(`get_file_count` 用 `{"nf":1,"show_dir":0}` 取到的是**纯文件数**,不含子目录)
  ⇒ 翻页时必须与总数那次用**完全相同**的查询参数。
- `count` 在翻页期间**会变**(目录内容变了)。p115client 为此专门加了
  `raise_for_changed_count` 参数,变化时默认只 warn。

### 3.2 `offset` 要用服务端回显的,不能自行累加

服务端会回显 `offset`(它认的位置)。`p115client` 的终止条件里有一条
`offset != resp["offset"]` —— 服务端给的位置与自己请求的不一致就停。

⚠️ **offset 越界会静默回绕**:p115client 对 **aps** 接口的 caution 原文
「当 `offset >= 1200 + n`,则相当于 `offset=0&fc_mix=1`,即从头开始」——
服务端**不报错**,只是悄悄从头数 ⇒ 自行累加步长会陷入死循环。
⚠️ 这段原文的主语是 aps 接口,web 端 `files` 是否有同样行为**查不到确凿证据**,
但两者是同一个 `files` 协议族(都返回 `count` / `offset`),风险不能排除。

⇒ 本项目:用服务端回显的 `offset` 推进;**回显了但与请求不符时停止**
(`Pan115DirectoryPage.isOffsetHonored`)。
⚠️ **服务端没回显 `offset` 时不算异常** —— 「没回显」是「无法证伪」而不是「证伪」,
当成异常会让浏览页永远停在第一页(目录明明有 3000 条,界面只显示 1000 条,⛔ 还不报错)。
⇒ 回绕的兜底是**内容重复**那道闸:累计时按 `fs_id` 去重,同一页被反复取时不会堆出重复条目。

⚠️ **下一页的起点是 `offset + limit`(服务端口径),⛔ 不是 `offset + 本页条数`**:
响应里可能有缺 `cid` 的条目(解码时丢掉),那些条目**服务端照样推进了页**,用本页条数推进会漏项。
「还有没有下一页」也按这个口径算(`offset + limit < count`),⛔ 不用解码后的条数 —— 两处必须一致。

## 4. 取播放地址

### 4.1 路径 A:chrome downurl(原文件 302 直链)—— 本项目用这条

```
POST https://proapi.115.com/app/chrome/downurl?t=<unix秒>
Content-Type: application/x-www-form-urlencoded
body: data=<urlencode(m115 加密后的 JSON)>

明文请求: {"pickcode": "<pick_code>"}     (支持逗号分隔多个;仅 aid=1)
```

响应 `{"state":1,"data":"<m115 加密串>"}`,解开后是:
```json
{"<file_id>": {"file_name":"…","file_size":123,"pick_code":"…","sha1":"…","url":{"url":"https://…"}}}
```

出处【源码】:`115driver pkg/driver/download.go:69-108` `DownloadWithUA(pickCode, ua)`:
`key := crypto.GenerateKey()` → `data := crypto.Encode(json.Marshal({"pickcode": pickCode}), key)`
→ POST → `crypto.Decode(result.EncodedData, key)`。加密算法见 §5。

⚠️ **取链时发的 `User-Agent` 会被写进直链的校验**(§4.3),所以取链的 UA 与播放的 UA **必须一致**。
本项目取链与播放都用同一个 `Pan115UserAgent.value`。

⚠️ p115client docstring【源码】:「尽量不要尝试对已经删除的文件获取下载链接,不仅会失败,还容易触发风控」。

### 4.2 路径 B / C(本项目不做,记录备查)

| 路径 | 端点 | 为什么不做 |
|---|---|---|
| App 版下载 | `POST https://proapi.115.com/2.0/ufile/download` | payload key 是 `pick_code`(下划线),响应是扁平 `{"url":…}` 没有文件名/大小;且属于「非网页端」行为,风控更重 |
| `os_mac` 版 | `POST https://proapi.115.com/2.0/ufile/downurl` | 要 **ECDH P-224 + AES-CBC**,而 CryptoKit 只有 P-256/384/521,**没有 P-224**;且 115 已下架 mac 客户端 |
| 网页 302 | `GET https://115.com/?ct=download&ac=video&pickcode=` | **最大 200 MB**,只能兜底 |
| 网页 m3u8 | `GET https://115.com/api/video/m3u8/{pickcode}.m3u8?definition=<n>` | 要 web Cookie、m3u8 内层也绑 UA、消耗 115 转码资源。见 §7 待办 |

### 4.3 直链的 `f` 参数决定要不要带 UA / Cookie

真实形态(`OpenList` issue #2502 的 403 现场原样)【源码】:
```
https://cdnfhnfile.115cdn.net/<hash>/<filename>.mp4
  ?t=<过期时间戳>&u=<uid>&s=<size>&d=<vip节点>&c=2&f=3&k=<key>&us=<size>&uc=10&v=1
```

`p115client client.py:8718-8730` 的 `download_url()` docstring【源码】:
- `t` = 过期时间戳
- `u` = user id
- `c` = 允许同时打开次数(0 = 无限)
- **`f` = 要求携带的请求头:空 = 无要求 / `1` = 需 UA(且与取链时一致)/ `3` = 需 UA + Cookie(取链响应返回的 `Set-Cookie`)**

⇒ **不是「115 一律绑 UA」,是服务端签发时决定,客户端读 `f` 判断。**
本项目按 `f` 分档:
- `f` 空 → 只发 URL
- `f=1` → 带 `User-Agent`(与取链同一个)
- `f=3` → 带 `User-Agent` + 取链响应里的 `Set-Cookie`

⚠️ 有效期只有 `t`,**没有固定 TTL**。本项目读 `t` 提前 5 分钟判定过期(`p115dav app.py:1174` 同做法)。
⚠️ UA 不一致的后果:`403` + `{"status":403,"message":"no cookie value"}`【源码 OpenList #2502 实测】。
⚠️ **未见 Referer 校验**,本项目不发 Referer。
⚠️ Range:直链能直接发 Range(p115client `client.py:797-833` `open()` 直接对直链发)。

## 5. m115 加密

`p115cipher` 0.0.6(作者 ChenyangGao,GPLv3)是事实来源。**本项目是它的独立 Swift 实现**,见
`LumaPlayer/Core/Sources/Pan115/Pan115Crypto.swift`。

要点(⛔ 改之前先想清楚):
- 1024-bit RSA,**分片 117 字节**(`block_size - 11`),PKCS#1 v1.5 填充但**填充是确定性的**(`0x00 0x02…0x00 msg`,没有随机字节)。
- **「解密」也是用公钥做指数运算**(`pow(c, e, n)`),不是私钥解密。⇒ `SecKeyCreateDecryptedData` 用不了,必须自己写模幂。
- 指数固定 `0x10001`,可特化成「16 次平方 + 1 次乘」。
- 三段 XOR/反转:`xor(data, RSA_KEY)` → 反转 → `xor(_, G_key_l)`,前面拼 16 字节 `rand_key`。
- `rsa_gen_key(rand_key, sk_len)` 用 160 字节 `G_kts` 表派生 key,注意 `length` 每轮减 `sk_len`。

### 5.1 `encode` 与 `decode` **不是互逆的**

两侧都对 RSA 用**公钥指数**(`e = 65537`):
- 请求:`xor` → 反转 → `xor` → 拼 16 字节 `rand_key` → PKCS#1 填充 → `pow(·, e, n)`;
- 响应:`pow(·, e, n)` → 剥填充 → 取前 16 字节当 `rand_key` → `rsa_gen_key(rand_key, 12)` → 反转 → `xor`。

没有私钥参与,所以「自己加密再自己解密」拿不回原文 —— 这是协议形状,不是实现 bug。
单测因此分三段验(派生/XOR、加密、解链后处理),⛔ 不要写「自加密自解」的往返断言。

### 5.2 与参考实现比对的方法

`/tmp/p115venv/bin/pip install p115cipher` 后:
```python
from p115cipher import rsa_encrypt, RSA_KEY, G_key_l
from p115cipher.util import rsa_gen_key, xor, rsa_decrypt_with_pubkey
```
- 加密可复现(填充固定 `0x02`),直接比对 `rsa_encrypt(...)` 的 base64。
- 解密不可复现(需要真实服务端密文),所以比对**两段**:
  `rsa_decrypt_with_pubkey(密文)` 的输出(§5.2 的 `rsa_decrypt_pubkey` 向量),
  以及「拿到块之后的 XOR 后处理」(`decode_chain` 向量,`Pan115Crypto.decodeBody(_:key:)`)。
- 向量文件:`~/Documents/LumaPlayer/115调研/报告/115-crypto-vectors.json`
  (调研素材,与四个参考仓库的 clone 放在一起;⛔ 不进仓库)。

## 6. 风控与限速(硬约束)

- 115 官方口径【原文】:`https://community.115.com/115/T952906.html` 2 楼 2026-03-10:
  「你提到的所谓"风控"如果指的是使用时出现"访问已达上限"的提示。一般是进行个别操作比较频繁造成的…稍后重新操作即可」。
- 网易爆米花官方【原文】:「可能触发了115接口风控,会限制账号的请求一段时间…**不会造成封号等影响**」。
- Infuse 员工 james【原文】(2026-09-18):「**目前 115 的设备数量上限为 2 台。**」
- CloudDrive2 FAQ【原文】:「短时间访问太频繁会触发 115 的风控,一般半小时左右自动恢复…**同一个 115 账号尽量只在一台机器上用**」。
- p115client 注释【原文】:「一旦此接口被风控,那么同一域名下,所有路径尾部是 `/files` 的接口都被风控」;
  「多次登录必定不能恢复,即使更换设备」。

**本项目采取的限制**:
- 所有 115 请求**串行**,两次之间至少 500 ms(≈2 req/s,与 OpenList `LimitRate: 2` 同口径)。
- 列目录**按需翻页**:浏览页滚到底才取下一页,一页 100 条
  (`FileSourceViewModel.browsePageSize`,与百度共用)。「必须一次拿整层」的 `list()` 才用
  1000 条一页(硬上限 1150,取 1000 留余量),⛔ 不自动翻超过 5 页。
  ⚠️ 一页大小不取接口上限:115 两次请求至少隔 500 ms,且每页都会对累计整套重跑合成 / 刮削。
- ⛔ 不做后台预取、不做并发批量元信息。
- 403 一律当「直链过期」处理:重取一次;再失败就报错给用户,⛔ 不循环重试。
- 翻页用服务端回显的 `offset` 推进,⛔ 不自行累加(防越界静默回绕,§3.2)。

## 7. 未核实 / 待办

- ❗ **网页 m3u8 路线未在真实账号验证**:`GET https://115.com/api/video/m3u8/{pickcode}.m3u8` 需要真实 web Cookie,
  本项目没有凭据。p115client docstring 说它「只支持 web 的 cookies」且 m3u8 内层链接「会绑定前一次请求时的 user-agent」。
  多音轨(`multitrack_list`)只能靠它。见 `KNOWN_ISSUES.md`。
- ❗ **Cookie 有效期未知**。社区说法从「几天」到「几个月」都有,无一手证据。本项目**不主动探活** ——
  Cookie 失效会在第一次读盘时以 `errno 990001` / `40101035` 暴露,那时浏览页切扫码屏(§2.3)。
- ❗ **因 Cookie 被封号的一手案例未找到**。协议明确禁止(§8),但实际处置案例只有社区转述。
- ❗ 直链 `t` 的具体有效秒数未知(只有「读 `t` 提前 5 分钟」这个做法)。

## 8. 合规(必须在 UI 里告知用户)

`https://115.com/agreement.html`(条款由 `115driver` / `p115client` 作者转述,页面本身多个路径 404,**未直接读到原页**):

- 3.2.3(4)禁止「使用脚本、外挂、插件、爬虫、自动化工具、**非授权客户端或者接口**等方式,持续、批量操作账号或者调用平台资源」;
- 3.2.3(5)禁止规避「访问频率、接口调用、流量管理、安全防护、风险控制」;
- 4.x(11)(12)禁止非授权第三方工具接入、未经书面同意做「插件、外挂、兼容、互联」;
- 5.4 禁止反向工程;
- 3.2.6 / 3.2.7 处罚含「限制部分服务功能、暂停或者终止相关服务、限制或者取消会员权益、**关闭账号**」,
  且「资料、文件、会员权益…**可能无法继续使用、恢复或取回**」。

⚠️ 2026-06-01 官方置顶公告 `https://115.com/115/T967854.html`【原文】:
「严禁利用**未经官方授权的应用、脚本程序、爬虫工具、自动化批量工具**等非法技术手段,恶意刷取流量、批量操作、高频访问」。

⚠️ 115 在**主动识别第三方客户端**:`115driver pkg/driver/download.go:221-224` 注释 ——
旧分享端点自 **2026-09** 起对第三方客户端返回「当前版本过低,请升级到最新版本下载」。

⇒ 添加 115 来源的 UI 必须明说:这是非官方接口,风险自负。
