# libmpv 对接

> libmpv 集成的事实来源。改 `Core/MPV/` 或 `PlayerViewModel` 的播放控制前先读。
> **章节编号稳定**,代码注释按编号引用(如「MPV_INTEGRATION.md §8」)。
> 官方依据:mpv 仓库 `DOCS/man/`(options.rst / input.rst / libmpv.rst)与 `include/mpv/client.h`、`render.h`、`render_gl.h`。
> 踩过的坑在 `PITFALLS.md` 第 2 节,这里不重复。

## 0. 来源与构建

- 头文件是 `#include <mpv/client.h>` / `render.h` / `render_gl.h`,⛔ 不是 `<libmpv/...>`;API 版本 2.5。
- **运行的是自编 libmpv**:`Scripts/build-libmpv.sh` 钉死上游 draft PR mpv-player/mpv#16818 的一个 commit
  (带 `MPV_RENDER_PARAM_BACKEND`,Homebrew 的 0.41.0 没有),meson 只编库,装到 `Vendor/mpv/prefix/`(gitignore)。
  ffmpeg / libplacebo / libass 等依赖复用 Homebrew。`Vendor/mpv/module.modulemap` 与 `OTHER_LDFLAGS` 指向那里。
  ⛔ 不覆盖 Homebrew 的 mpv(要留作参照,且 `brew upgrade` 会回退)。
- 本地补丁在 `Vendor/mpv/patches/`,脚本按文件名顺序 `git apply`:
  `0001` gpu-next 读 `FLIP_Y` + 默认渲染参数 + `frame_mixer = NULL`;`0002` `ao_coreaudio` 初始化失败时注销热插拔监听;
  `0003` gpu-next 注册 VideoToolbox 设备恢复零拷贝。
- 打包:`Scripts/bundle-libmpv.sh` 把 libmpv 与依赖拷进 `Frameworks/`、改写 install name、删 Homebrew `LC_RPATH`。只对 Release 产物跑。
- **上游合并 #16818 之后**:改回官方仓库与 sha;核对 `MPV_RENDER_PARAM_BACKEND` 的编号与语义(Swift 侧一起改);能删的补丁删掉。

## 1. 已定决策

| 决策 | 结论 |
|---|---|
| 渲染 | **Render API**(`render.h`),`MPV_RENDER_API_TYPE_OPENGL` + `CAOpenGLLayer`。⛔ 不用 opengl-cb(0.33 起失效)、`--wid` |
| 后端 | 默认按片源:DV 用 `gpu-next`,其余 legacy `gpu`;偏好可固定成任一个(§3.3) |
| 封装 | 薄 `MPVPlayer`,业务代码不直接调 C API |
| 实例 | 一个 `MPVPlayer` 只播一个 URL,换台 = 销毁重建(§8) |

```text
PlayerViewModel (@MainActor) → PlaybackSessionCoordinator → MPVPlayer (Core/MPV/) → libmpv → CAOpenGLLayer / NSView
```

## 2. 渲染路径

`MPVView`(`NSViewRepresentable`)承载 `MPVLayerView`,后者 `makeBackingLayer` 返回 `CAOpenGLLayer`。每次 draw:
`mpv_render_context_update()` + **无条件** `render()`;FBO 取当前绑定(`GL_DRAW_FRAMEBUFFER_BINDING`),不写死 0;
传 `FLIP_Y = 1`;渲染尺寸取 GL viewport。

## 3. 选项(`mpv_initialize()` 之前,`MPVPlayer` 里的表)

`config=no`、`load-scripts=no`、`terminal=no`(libmpv 默认即如此,防御性显式设置)、`msg-level`、`vo=libmpv`、
`hwdec=auto`、`cache=yes`、`demuxer-max-bytes=128MiB`(未按码率标定,M2)。
任何 `mpv_set_option_string` 失败都当致命。⛔ 不设 `tls-verify=no` 及任何跳过证书校验的选项。

### 3.1 hwdec

options.rst 原文:零拷贝 `videotoolbox` 在 macOS 上只标注支持 `vo=gpu/gpu-next`,`vo=libmpv` 只标了 iOS;
`videotoolbox-copy` 无 VO 限制。所以用 `hwdec=auto` 让 mpv 自己选,实际解码器看 `hwdec-current`(统计面板「解码」)。

### 3.2 显示器休眠

`--stop-screensaver` 在 `vo=libmpv` 下不生效(`vo_libmpv.c` 不处理 `VOCTRL_KILL_SCREENSAVER`)→
宿主自己持 `DisplaySleepAssertion`(`PITFALLS.md` Q34)。

### 3.3 渲染后端

策略 `MPVRenderBackendPolicy`(设置 →「播放 → 色彩」,起播读一次),默认 `automatic`:`attachGLContext` 先建 legacy;
`on_preloaded` hook(轨道已加入、选轨与 VO 之前)读 `track-list/N/dolby-vision-profile`,有 DV 就 free 掉重建为
`MPV_RENDER_PARAM_BACKEND = "gpu-next"` —— VO 还没建,不重开流、不多上报。HDR10 / HLG 不切(legacy 能正确色调映射)。
hook 任何路径都必须 `mpv_hook_continue`,否则核心永远卡住。gpu-next **create 真失败**才回退 legacy(不黑屏),
实际后端记进统计 `renderBackend`。⚠️ 未知后端名会**静默**回退且返回成功;确证看 `Using gpu-next backend.`
(打在 render context create 时,VO 建起是之后的 `VO: [libmpv]`)。测试用 `Tools/dv-fixture/` 合成的只有 `dvcC` 的片源。
gpu-next 专属选项若要加,只能 post-create 用 `mpv_set_property_string` 非致命设置。

## 4. Swift 桥接

- C 函数返回值 < 0 即失败,**必须检查**,用 `mpv_error_string` 转消息;⛔ 不得忽略错误码。
- 启动时 `mpv_client_api_version()` 打一次日志。

## 5. 认证头

### 5.1 `http-header-fields`

`Authorization` 值自带逗号,⛔ 不能拼成一个字符串用 `mpv_set_option_string` 赋值(会被按逗号拆开)。
做法:`MPV_FORMAT_NODE` 的字符串数组,每条一个 header,**`mpv_initialize()` 之后、`loadfile` 之前**用 `mpv_set_property` 设。
实测两个 HTTP 连接都原样携带。退路(`api_key`)见 `API_CONTRACT.md` 6.2。

## 6. 事件

### 6.1 观察的属性

`time-pos`、`duration`、`pause`、`volume`、`mute`、`speed`、`paused-for-cache`、`track-list`、`aid` / `sid`、
`hwdec-current`、`sub-delay` 等(列表在 `MPVPlayer`)。统计与缓冲进度这类高频变化值**不 observe**,
由调用方低频轮询 `stringProperties(_:)`;读不到的属性结果里就没有这个键,不填占位。

### 6.2 事件类型

`PROPERTY_CHANGE`、`START_FILE`、`FILE_LOADED`、`END_FILE`(`reason == ERROR(4)` → `loadFailed`)、
`SEEK`、`PLAYBACK_RESTART`、`LOG_MESSAGE`、`SHUTDOWN`(核心退出 → `endFile(.error)`)。
队列满会静默丢事件:等帧 / 等结束的循环(测试、探针)要持续排空。

### 6.3 线程模型(强制)

- 独立事件线程循环 `mpv_wait_event()`,退出条件是独立的 `isStopping` 标志;线程体每轮从 weak 提供者取一次强引用。
- 事件经 `MPVEventBridge` 投递到 MainActor;`time-pos` 在桥里节流后再投递。
- 两把锁,锁序恒为 `renderMutex` → `mutex`;整帧 render 不放进 `mutex`。
- `Core/MPV/` 是全项目**唯一**允许 `@unchecked Sendable` 的目录(包裹 C 指针),每个类型都要注释论证线程安全。

## 7. 轨道

`track-list/N/*`:`id`(设 `aid` / `sid` 用)、`type`、`src-id`(容器内轨道号,从 1 起,⛔ 不是 Emby 的 `Index`)、
`selected`、`title` / `lang`(菜单显示名 title → lang →「轨道 N」)、`default` / `forced`、`codec`、`external`。

- 选轨:设 `aid` / `sid` = id;关字幕 `sid = no`。设了不存在的轨会读回 `no` → 要读回验证。
- `track-list` 事件里的 `mpv_node` 归 mpv,⛔ 不 `mpv_free_node_contents()`,同步解析完。
- 与 Emby 流索引的对应:只按「同类型内嵌轨的出现顺序」,见 `StreamIndexMapper`(`PITFALLS.md` Q21)。
- 外挂字幕(`sub-add` 带认证头)未实现(M4)。

### 7.1 字幕延迟与外观

- 延迟:`sub-delay`(秒,正 = 字幕晚出现,RW,读回值驱动屏显);只作用于 mpv 渲染的轨,转码烧录的字幕调不动。不上报服务端(Q39)。
- 外观:`SubtitleStyle.mpvProperties`(纯函数)生成一组 `sub-*` 属性,`MPVPlayer.setSubtitleProperties` 只放行 `sub-` 前缀。

| 设置 | mpv 属性 |
|---|---|
| 字号 | `sub-scale` |
| 颜色 / 粗体 | `sub-color` / `sub-bold` |
| 描边粗细 | `sub-outline-size` |
| 效果:描边 / 描边+阴影 / 底框 | `sub-border-style`、`sub-back-color`、`sub-shadow-offset`(共用属性,所以三选一互斥) |
| 垂直位置 | `sub-pos`(⛔ 不开放 > 100,libass 会裁掉文字) |
| 对 ASS 也套用 | `sub-ass-override=force`(默认关:手册原话会把特效字幕渲染坏) |

默认值与 mpv 自身默认一致:没改过 = 什么都不改。起播默认轨见 `SubtitlePreference`(`slang` 挑不出简体中文)。

## 8. 生命周期

```text
idle ──load()──▶ loading ──首帧──▶ playing ⇄ paused
                    │                 └──stop()/shutdown()──▶ tearingDown ──▶ destroyed
                    └──失败──▶ failed
```

- `shutdown()` 可重入;`destroyed` 之后任何调用抛 `MPVError.instanceDestroyed`,不静默。
- 拆卸顺序不可换:先 `mpv_wakeup` 停事件循环 → `mpv_render_context_free` → `mpv_destroy`。
- 一实例一 URL,不复用(复用会沿用上一轮的 `http-header-fields`,跨服务器即串台);播完是 `endFile(.eof)` 事件不是状态。

## 9. 错误映射

```swift
enum MPVError: Error, Equatable, Sendable {
    case instanceDestroyed
    case commandFailed(code: Int32, message: String)
    case renderContextFailed(String)
    case loadFailed(reason: String)
}
```

C API 返回 < 0 → `commandFailed`;`END_FILE` reason=error → `loadFailed`。⛔ 错误消息不得含完整播放 URL,经 `SecretRedactor`。

## 10. 未解决

见 `KNOWN_ISSUES.md`:M2(缓冲大小)、M4(外挂字幕)、Q18(hardened runtime)、Q29(无 Homebrew 机器)、Q42(DV / gpu-next 验证)。
