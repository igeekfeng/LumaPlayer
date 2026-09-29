# 本地 Emby 开发实例

日常开发与手工验收用的自建 Emby,用来**代替访问别人的真实服务器**。
服务器都不是自己的,滥用会被封禁。

一句话:**它是一台真实的 Emby,不是 mock。** 所以「关转码」「造 401」「配反代子路径」
这类在别人的服务器上做不到的事,在这里都能做。

## 边界(重要,别越界)

| 能做 | 不能做 |
|---|---|
| 压测、循环刷列表、构造异常请求 | 用它声称「已兼容真实服务器」 |
| 关转码、多版本、多实例、反代子路径 | 用它勾掉那些依赖**别人家部署**才能做的验收项 |
| 稳定地反复跑同一场景 | 把它产生的响应当作「接口事实来源」——它只代表这一个版本 |

版本刻意固定在 **4.9.5.0**,对齐原先假设的环境;已实测的线上服务器是
**4.7.11.0**。版本不同这件事本身要记住。

## 快速开始

```bash
# macOS 上 Docker Desktop 的 CLI 常常不在 PATH,先补上
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"
cd Tools/emby-dev

./gen-media.sh              # 生成测试素材(约 1.5 分钟,约 360 MB)
docker compose up -d        # 启动(全新 config 要等 10~20 秒初始化数据库)
./setup-instance.sh         # 首次配置:走向导 + 建两个媒体库 + 建普通用户 + 调续播门槛
curl -s localhost:8096/emby/System/Info/Public   # 冒烟:应返回含 Version 的 JSON
```

LumaPlayer 里添加服务器填 **`127.0.0.1:8096`** 即可。不写 scheme 时会先试 https,
探测失败后按 `ServerConnection.httpFallbackURL` 回退到 http
(localhost 在 `isLocalOrPrivateHost` 白名单内);也可以直接写 `http://127.0.0.1:8096`。

`setup-instance.sh` **幂等**,可重复跑。它也是「重建 config」的全部步骤 ——
`config/` 已删除时,上面三条命令跑完就有一台可用实例,不需要手点网页向导。

### 凭据

| 用户名 | 密码 | 角色 |
|---|---|---|
| `luma` | `lumadev` | 管理员(向导创建) |
| `viewer` | `viewerdev` | **普通用户**(`setup-instance.sh` 创建) |

都是本地开发实例的凭据,与任何真实环境无关。Emby 面板里可随时改。

## 非管理员用户(`viewer`)

建它是为了测「同一台服务器、两个账号」:换个账号登录后,续播位置是否按 `UserId`
隔离;一台服务器上能否独立切换身份。它**默认可见全部媒体库**
(`EnableAllFolders=true`),权限差异不会影响浏览。

### 实测:禁用用户走的是 403,不是 401

把 `viewer` 临时禁用(`POST /Users/{Id}/Policy` 置 `IsDisabled=true`)后,
`POST /Users/AuthenticateByName` 返回的是:

| 情形 | 状态码 | 响应体 |
|---|---|---|
| 密码错 | `401` | `用户名或密码无效。请重试。` |
| **账户被禁用** | **`403`** | `您的账户已被禁用。请联系您的服务器管理员以获取更多信息。` |

也就是说禁用走的是 **`.api(.forbidden)`** 分支,不是 `.invalidCredentials`。
客户端 `ServerLoginError.api` → `EmbyAPIError.forbidden.userMessage`,最终显示:

> 没有访问权限,请检查该服务器上的用户权限。

⚠️ **这条文案与真实原因不符** —— 账户被禁用的人去「检查用户权限」是解决不了的,
而服务端其实给了准确原因(「您的账户已被禁用」),客户端没有透出。
是否要为它单开一种文案,待定;本实例只是
**第一次让这个分支可复现**(真服务器上不敢随便禁用别人的账号)。

复现步骤如下,用完记得恢复 `IsDisabled=false`:

```bash
# VID 为 viewer 的 Id(GET /emby/Users 取)
curl -s -H "X-Emby-Token: $TOKEN" "$B/Users/$VID" > /tmp/pol.json
# 把 /tmp/pol.json 里 Policy.IsDisabled 改成 true 后 POST 回 /Users/$VID/Policy
```

### 附:非管理员能读到的东西

| 端点 | 非管理员结果 |
|---|---|
| `GET /Users` | **403**(管理员专属) |
| `GET /Library/VirtualFolders` | 200,且**返回服务端物理路径**(`/mnt/media/Movies`) |
| `GET /Sessions` | 200,但**只含自己的会话**,不含别人的 |

LumaPlayer 用的 17 个端点全是非管理员可访问的,所以正常流程不会撞上 403 ——
唯一能造出 403 的场景就是上面的「禁用用户再登录」。

## 测试素材

由 `gen-media.sh` 生成(素材不入库,脚本入库)。分两类,对应两个媒体库:

### 电影 —— 媒体库「本地测试库」→ 容器内 `/mnt/media/Movies`

| 文件 | 期望路径 | 用途 |
|---|---|---|
| `01-direct-h264-aac.mp4` | DirectStream | 基线;另配同名 `.zh.srt` 验外挂字幕关联 |
| `02-multi-track.mkv` | DirectStream | 2 音轨(eng/chi)+ 2 内嵌字幕 → 轨选择 |
| `03-transcode-hevc.mkv` | 期望转码(见下方「已知结论」) | HEVC 10bit 1080p;也是测转码 seek 的素材 |
| `演示长片 (2024)/` | DirectStream | **30 分钟**:进度条拖动、`RunTimeTicks` 换算、断点续播、10 秒定时上报 |

### 剧集 —— 媒体库「本地剧集库」→ 容器内 `/mnt/media/TV`

`演示剧集 (2024)`,2 季 + 特辑季,共 6 集。目录结构按 Emby 官方 TV 命名规则
(`Series (year)/Season NN/Series SxxExx - Name.ext`),否则扫不出来:

| 集 | 时长 | 用途 |
|---|---|---|
| S01E01 首播集 | 12 分钟 | 剧中最长;另配 `.zh.srt` 验**剧集**的外挂字幕关联 |
| S01E02 / S01E03 | 各 4 分钟 | 同一季内的集切换 |
| S02E01 / S02E02 | 各 4 分钟 | 跨季切换(验证 `SeasonId` 变化) |
| S00E01 幕后特辑 | 2 分钟 | 放在 `Season 00/` → Emby 认成「特别篇」季 |

这条覆盖 `EmbyEndpoint` 里 `.seasons` / `.episodes` 两个端点,以及
`SeriesId` / `SeasonId` / `SeriesName` / `SeasonName` 字段。

### 素材怎么「自证身份」

手工验收最容易出的错是**点开 E03、实际播的是 E01**,而纯 `testsrc2` 的画面里
根本看不出这一点,截图也无法举证。所以每条新增素材都做了三件事:

1. 画面底部烧一条标签:**剧名 + 季集号 + 时长**(`make-label.py` + Pillow 生成)
2. 色相 `hue` 按集号错开
3. 音轨频率按集号错开

标签 PNG 放在 `.labels/`(刻意在 `media/` 之外——Emby 会把媒体目录里的图片当海报收走)。
没有 Pillow 时脚本降级为不烧标签,素材照样出。

`testsrc2` 左上角**自带时间码与帧号**,那才是判断 seek 是否生效的依据,所以标签只放底部。

时长与分辨率可用环境变量覆盖,例如 `LONG_DUR=7200 ./gen-media.sh`(长片改 2 小时)、
`WIDTH=1280 HEIGHT=720 ./gen-media.sh`。

## 已实测(2026-09-23,Emby 4.9.5.0 / arm64 容器)

| 端点 | 结果 |
|---|---|
| `GET /emby/System/Info/Public` | 200,免认证 |
| `POST /emby/Users/AuthenticateByName` | 200,体用 `{"Username":..,"Pw":..}` —— 与 3.1 一致 |
| `GET /emby/Users/{id}/Views` | 200,两个库(`movies` / `tvshows`) |
| `GET /emby/Users/{id}/Items?IncludeItemTypes=Movie` | 4 条,**不含剧集**(库路径已收窄) |
| `GET /emby/Users/{id}/Items?IncludeItemTypes=Series` | 1 条 |
| `GET /emby/Shows/{id}/Seasons` | 3 季,含 `IndexNumber=0` 的「特别篇」 |
| `GET /emby/Shows/{id}/Episodes` | 6 集,`SeasonId` / `ParentIndexNumber` / `RunTimeTicks` 均正确 |
| `POST /emby/Items/{id}/PlaybackInfo` | 200,含 `PlaySessionId`、`MediaSources` |
| `GET /emby/Videos/{id}/stream.{c}?static=true` | **206 + Range 生效**(mpv 拉流前提);不带 token 为 401 |
| `POST /emby/Users/New` | 200;建出的用户默认 `IsAdministrator=false`,不用再补 Policy |
| `POST /emby/Users/{id}/Password` | 204;改**别人**的密码时 `CurrentPw` 传空串即可 |
| `POST /emby/Users/AuthenticateByName`(非管理员) | 200,`viewer` 可见 10 条(4 电影 + 6 集),拉流同样 206 |

分集侧另外确认:外挂字幕在**剧集**上同样会被关联(`MediaStreams` 里
`IsExternal=true`、`Language=zh`)—— 外挂字幕的关联规则不是只对电影成立。

另外记一笔:`/emby/swagger-ui/index.html` 等常见 Swagger 路径在 4.9 上全部 **404**,
内置 Swagger 已不可用。要核实接口请回到官方 OpenAPI,**不要靠猜端点**。

## 已知结论:不发 DeviceProfile 时转码路径不会触发

对 `03-transcode-hevc.mkv`(HEVC 10bit 1080p)调 `PlaybackInfo`,无论怎么组合
`EnableDirectPlay` / `EnableDirectStream` / `EnableTranscoding`,Emby 4.9.5.0 都返回:

```
SupportsDirectStream: True    TranscodingUrl: (无)
```

连 `EnableDirectStream: false` + `EnableTranscoding: true` 也不给转码地址。

原因:客户端刻意**不发 `DeviceProfile`**(`Models/EmbyPlaybackInfo.swift` 顶部注释),
服务端因此无从判断客户端能力,只能保守地认定「源可直连」。

**推论(待定案,不要直接当结论用):**
- 要让 `.transcode` 分支在本地真正跑起来,得先补 `DeviceProfile` —— 而补它需要先实测服务端默认行为,
  ⛔ 不能凭想象写一个几百行的 profile。
- 在那之前,关于转码的验收(转码 seek、转码上报)在本地也**无法覆盖**,
  与本实例无关,是同一个原因。

## 已知结论:续播门槛必须调成 0

媒体库选项 `MinResumeDurationSeconds` 默认 **120**(另有 `MinResumePct` 2、
`MaxResumePct` 90)。素材短于该值时,服务端收到中途 `Stopped` 也只会标记已看、
`PlaybackPositionTicks` 存 0 —— 看起来像客户端没上报进度,其实是服务端规则。

两个媒体的该值都已由 `setup-instance.sh` 设为 **0**;`config/` 重建后它会重设一遍,
不需要手工改面板。

## Emby 4.9 上几个反直觉的 API 行为

这些都是实测撞出来的,`setup-instance.sh` 依赖它们。别按常识推断:

| 行为 | 说明 |
|---|---|
| 向导状态没有现成字段 | `/System/Info/Public` **不返回** `StartupWizardCompleted`;要判断只能看**匿名** `GET /Startup/Configuration` → `401`=已完成、`200`=未完成 |
| 向导完成会踢掉 token | `POST /Startup/Complete` 之后,先前拿到的 token 一律失效,必须重新登录 |
| 库路径 API 只认 `Id` | `POST`/`DELETE /Library/VirtualFolders/Paths` 传 `Name` 会得到 `Unrecognized Guid format`;`Id` 是那个**整数** `ItemId`(如 `3`) |
| 报 500 但实际生效 | `POST /Library/VirtualFolders/Paths` 会返回 500 却成功加上路径 —— **只看状态码会被骗,必须 GET 回读** |
| 删库端点不生效 | `DELETE /Library/VirtualFolders?Name=..` 返回 500 且库还在 |
| LibraryOptions 要包装 | body 必须是 `{"Id":..,"LibraryOptions":{..}}`;提交裸的 `LibraryOptions` 报 `Object reference not set to an instance of an object` |
| 新用户默认就是非管理员 | `POST /Users/New` 建出来即为 `IsAdministrator=false`,不需要再补一次 Policy |
| 改别人的密码不用旧密码 | `POST /Users/{Id}/Password` 里 `CurrentPw` 传空串即可(只有改自己才必须填);Emby 不回显明文,幂等判断只能看 `HasPassword` |
| 禁用用户登录返 403 | 禁用后登录是 `403`(不是 `401`),见上面「非管理员用户」一节 |

## 常见问题

**容器起不来,日志报 network 相关错误**
检查是否照抄了 Emby 官方文档里的 `network_mode: host` —— macOS 的 Docker Desktop
不支持它,必须用 `ports` 映射。

**`docker: command not found`**
Docker Desktop 已在运行但 CLI 不在 PATH,见上面 `export PATH=...`。

**媒体库是空的 / 剧集没扫出来**
先确认 `gen-media.sh` 跑过。剧集不出现通常是命名或目录层级不符合官方规则
(`Series (year)/Season NN/Series SxxExx.ext`),改完重新扫描:
`docker compose restart` 或面板里点「扫描媒体库」。

**媒体库配置乱了**
`./setup-instance.sh` 会把两个库的存在性、路径与续播门槛都校正回预期值,重复跑无害。

**想再要一台(多服务器隔离验收)**
复制 `docker-compose.yml` 改 `container_name`、`ports`(如 8097)与 volumes 路径,
再对第二个实例的 `BASE_URL` 跑一次 `setup-instance.sh`。两台不同版本还能顺带观察跨版本差异。

**重建 config 之后 App 里那台服务器还能用吗**
不能。`config/` 一删,Server Id 与用户 Id 都会变,旧 token 全部失效 ——
App 里需要重新添加 `127.0.0.1:8096` 并登录。
