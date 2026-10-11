# Erika 对接

> Erika 内核集成的事实来源。改 `Core/Erika/`、`Core/Playback/Engine/` 或 `PlayerViewModel` 的播放控制前先读。
> **章节编号稳定**,代码注释按编号引用(如「ERIKA_INTEGRATION.md §6.1」)。
> 内核比较新、会频繁变更 —— 这份文档和分层的**目标是让内核升级只改 `Core/Erika/`**。

## 0. 来源

- [ErikaSwift](https://github.com/AimesSoft/ErikaSwift)(product `Erika`),文档 <https://erika.aimes-soft.com/docs/guide/swift.html>。
  本机参照版本 **0.2.1**。标记规则同 `API_CONTRACT.md`(✅ / 🔶 / ⚠️)。
- ⛔ 旧内核 libmpv 的一切(`vo=libmpv`、`gpu-next`、`http-header-fields`、`track-list`、`MPV_EVENT_*`)都已作废,别照抄。

### 0.1 接入:SwiftPM 静态链接

- `project.pbxproj` 里的 `XCRemoteSwiftPackageReference`(`ErikaSwift`,`upToNextMinorVersion` 0.2.1)→ product `Erika`,
  **只挂 App target**:测试 target 不链接 Erika,靠归一化类型与假引擎测(`EofDetector` 是纯结构,可直接单测)。
- 没有 dylib 要拷、没有 module map、没有 `OTHER_LDFLAGS`。
- `Package.resolved`(`project.xcworkspace/xcshareddata/swiftpm/`)**入库**,当前 `0.2.1` / `08682d8`。
- ⚠️ 解析包要联网(首次 / 换机 `xcodebuild -resolvePackageDependencies` 会去 GitHub 拉 xcframework.zip)。
  报 TLS 错先 `curl -I` 直连那个 URL 确认是本机网络 / 沙箱问题。

### 0.2 升级步骤

**0.2.x 补丁 / 升 minor**:改 pbxproj 里那一处 `minimumVersion` → `xcodebuild -resolvePackageDependencies -scheme LumaPlayer`
→ 零 warning build + test。

**可能改 API 的升级**:

1. 先读上游 changelog,对照 §4–§13 用到的 API;
2. 改动**收敛在** `Core/Erika/`(唯一 import Erika 的目录)与 `PlaybackEngineFactory`;
   上层若被迫改,说明归一化层漏了东西,先补归一化类型;
3. 重新核对 `KNOWN_ISSUES.md` E 节的待真机核实项;
4. 更新 §0 的参照版本,在 `PITFALLS.md` 第 2 节「Erika」记一笔(版本 + 改了什么 + 踩到的坑)。

## 1. 已定决策

| 决策 | 结论 |
|---|---|
| 内核 | Erika(替换 libmpv) |
| 分层 | 归一化引擎层(`Core/Playback/Engine/`)+ Erika 适配器(`Core/Erika/`) |
| 渲染 | SDK 的 `ErikaVideoView`(Metal)自驱,宿主不碰渲染循环 |
| 事件 | **pull / poll**:宿主轮询 `pollEvent()`,`PlaybackEventPump` 定节奏 |
| 线程 | `ErikaPlayer` 是 `@MainActor`,适配器全程主线程,**零并发逃逸** |
| ⛔ 移除的旧能力 | 字幕延迟、缓冲 / 缓存 / 网速统计与进度条已缓冲段、字幕垂直位置 / 底框不透明度 / 阴影色、强制字幕模式 —— Erika 没有 |

```text
PlayerViewModel (@MainActor,只认归一化类型) → PlaybackSessionCoordinator
  → PlaybackEngine 协议(Core/Playback/Engine/) → ErikaPlaybackEngine(Core/Erika/,唯一 import Erika)
  → ErikaPlayer / ErikaVideoView
```

## 2. 分层

| 目录 | 内容 | import Erika |
|---|---|---|
| `Core/Playback/Engine/` | `PlaybackEngine` 协议、归一化值类型、`PlaybackEventPump` | ⛔ |
| `Core/Erika/` | `ErikaPlaybackEngine`、`EofDetector`、`PlaybackEngineFactory`、`ErikaSubtitleMapping` | ✅(唯一) |
| `Features/Player/` | `PlayerViewModel`、`PlayerSurfaceView`、控制栏 | ⛔ |

`PlaybackEngineFactory.make(upscaler:)` 是 `Core/Erika/` 之外**唯一提到具体内核类型名**的地方(由 `AppContainer.makePlaybackEngine` 调)。

## 3. 归一化类型

`PlaybackEngine`(`open/play/pause/stop/close/seek/setRate/setVolume/setUpscaler/tracks/selectAudioTrack/selectSubtitleTrack/setSubtitleStyle/makeVideoSurface/pollEvent/stats`)、
`PlayerPhase`(`idle / loading / playing / paused / stopped / failed / closed`)、`PlayerTrack`(`id: Int64`、kind、source、selected、title、language、codec;无 forced)、
`PlayerEvent`(`phaseChanged / position / duration / paused / buffering / ended / tracksChanged / trackSelectionChanged / surfaceAttached / error`)、
`PlayerEndReason`(`eof / stopped / error`)、`PlayerError`、`PlayerStats`、`PlayerUpscaler`(`off / artCNN`)、`PlayerSubtitleStyle`。

⛔ 刻意不进归一化事件:倍速 / 音量**读回**(内核没有)、视频参数 / 解码器 / 音频输出变化(只在适配器里缓存给 `stats()`)。

## 4. 状态 / 事件映射(`ErikaPlaybackEngine.translate`)

| Erika 状态 | 归一化 | 备注 |
|---|---|---|
| `idle` | `idle` | |
| `opening` / `ready` | `loading` | `open()` 同步探测,返回即 ready |
| `playing` / `paused` | 同名 | |
| `stopped` | `stopped` | 自然播完与外部停止都落这里,靠 `EofDetector` 区分(§5) |
| `closed` | `closed` | 终态,`close()` 后不可复用 |
| `error` | `failed` | 同时补 `.error` + `.ended(.error)` |

| Erika 事件 | 归一化 |
|---|---|
| `stateChanged` | `.phaseChanged`(+ 可能 `.ended`) |
| `positionChanged` / `durationChanged` | `.position` / `.duration`(微秒 → 秒,同时喂 `EofDetector`) |
| `bufferingChanged` | `.buffering` |
| `tracksChanged` | `.tracksChanged`(重新取 `tracks()` 快照) |
| `trackSelectionChanged` | `.trackSelectionChanged`(取 `trackSelection()` 的权威选中 id) |
| `surfaceAttached` | `.surfaceAttached`(计时线 `surfaceReady`) |
| `error` | `.error` + `.ended(.error)` |
| `surfaceDetached` / `videoParamsChanged` / `videoDecoderChanged` / `audioOutputChanged` | 不上推(后两组只缓存给 `stats()`) |

一个内核事件可翻译成多条,适配器用内部 `pending` 队列逐条吐出。

## 5. EOF 判定(`EofDetector`)

Erika **没有 EOF 事件,也没有「已结束」状态**。推断:位置到过 `duration - eofPositionEpsilon` 记 `reachedEnd`;
收到 `stopped` / `closed` 时,本地主动停的(`stop()` / `close()` 前调 `markLocalStop()`)→ `.ended(.stopped)`,
否则 `reachedEnd ? .eof : .stopped`;**只报一次**。上层 `.eof` → 收尾上报 + 释放休眠断言 + 下一集倒计时。
⚠️ 待真机核实(Q43),核实后只改这个文件。

## 6. 播放控制

| 能力 | API | 说明 |
|---|---|---|
| 起播 | `open(url:headers:)` → `play()` | `headers` 是结构化字典,无转义问题 |
| 停止 / 关闭 | `stop()` / `close()` | 先 `markLocalStop()`,避免被判成 EOF |
| 跳转 | `seek(to:)` | 只用于 DirectStream;Transcode 是停流 + `StartTimeTicks` 重新起流 |
| 倍速 | `setRate` | 0.25–4× |
| 音量 | `setVolume` | **0.0–1.0**(上层对外仍是 0–100) |
| 超分 | `setUpscaler` | 起播建引擎时按偏好定;运行期能否改待核实(Q49) |

内核**没有静音、没有音量 / 倍速读回**:静音在 `PlayerViewModel` 实现(`isMuted` 为真时向引擎写 0,`volume` 本身不变,取消静音即还原);
音量 / 倍速是乐观更新。⛔ 别写「从内核读回音量 / 倍速」。

⚠️ `open()` **同步探测**流(HEAD + 首段 Range,MP4 还要取尾部 moov),在主线程上会卡住整个 App(Q54)。

### 6.1 HTTP 缓存

`ErikaPlayer.open` 时传(常量在 `ErikaPlaybackEngine`):`httpReadAheadBytes` **128 MiB**(默认 2 MiB)、`httpBackBufferBytes` **64 MiB**(默认 16 MiB)。
默认值下内核按码率涓流拉取、暂停时不攒缓冲;放大后满带宽持续缓冲,`open` 耗时不变(本机限速服务器实测,未在真实服务器验证)。
回看窗口从**下载头**往回算。未按码率标定(M2)。

## 7. 轨道

列表 `tracks()`;选择 `selectAudioTrack(id:)` / `selectSubtitleTrack(id:)`(`nil` = 关);变化后以 `trackSelection()` 为准,
⛔ 不假设设置即生效。上报 Emby 流索引只按「同类型内嵌轨的出现顺序」(`StreamIndexMapper`,`PITFALLS.md` Q21),不用内核 id。
⚠️ `tracks()` 是否填 `selected`、id 与 `trackSelection()` 是否一致待核实(Q47)。外挂字幕未实现(M4)。

## 8. 字幕

`SubtitleStyle`(UserDefaults)→ `engineStyle` → `PlayerSubtitleStyle` → `ErikaSubtitleStyle`。

| 设置 | Erika |
|---|---|
| 字号 | `setSubtitleScale(scale)` |
| 颜色 / 粗体 / 描边粗细 | `primaryColorRgba`(`0xRRGGBBAA`)/ `bold` / `outlineWidth`(底框模式为 0) |
| 效果:描边 / 描边+阴影 / 底框(三选一) | `borderStyle` 1 / 1 / 3 + `shadowDepth` 0 / 2 / 0 + `outlineColorRgba` |
| 对 ASS 也套用 | `overrides = .all`,默认 `[]`(没改过 = 什么都不改) |

默认值 = `ErikaSubtitleStyle()` 的初值。起播默认轨:`SubtitlePreference`(简体 → 繁体 → 未标变体的中文 → 不动内核默认)。
⚠️ scale 与 style 的叠加关系、默认值是否一致待核实(Q46)。

## 9. 统计(`PlayerStats`)

各内核统计的**归一化并集**,给不了的字段是 `nil`、整行不显示,⛔ 不填「未知 / 0」占位。

| 字段 | 来源 |
|---|---|
| 分辨率 / 编码 / 帧率 / 码率 | `tracks()` 视频轨 + `videoParamsChanged` 缓存 |
| 色彩 primaries / transfer | `videoParamsChanged`(枚举码 → 人读名,未知码原样显示) |
| 解码器 / 是否硬解 | `videoDecoderChanged` + `presenterStats()` |
| 音频 | `tracks()` 音频轨 |
| 已渲染 / 丢帧 | `presenterStats()`(丢帧取**背压丢帧**,非显示端丢帧) |
| 输出模式 / EDR headroom | `outputStatus()` |
| 显存 | `resourceStatus()`(渲染器跟踪的,非整机) |

近似语义待核实(Q48、Q50)。

## 10. 视频表面

`makeVideoSurface()` 返回 SDK 的 `ErikaVideoView`(引擎持有,每次同一个);`PlayerSurfaceView`(`NSViewRepresentable`)交给 SwiftUI,
视图层不 import 内核。渲染由 SDK 自驱,宿主不等「渲染上下文挂好」。当前**先上屏再 `open`**(顺序待核实,Q44)。
拆卸:`PlayerSurfaceView` 只移出层级,不关引擎;收尾统一由 `PlayerViewModel.stop()`(最终上报 + `close()`)负责。

## 11. 事件泵(`PlaybackEventPump`)

每 33 ms 排空 `pollEvent()` 直到 nil;位置事件节流到每 0.2 s 最多一次(内核约 100 ms 一次),其余不节流;
全程 `@MainActor`,循环对引擎逐轮弱引用获取,引擎释放后自行退出;`stop()` 可重入。主线程掉帧风险待核实(Q52)。

## 12. 线程

`ErikaPlayer` 是 `@MainActor` → 适配器全程主线程。⛔ 全项目没有 `@unchecked Sendable` / `nonisolated(unsafe)` / `@preconcurrency`
的例外目录。表面 `onError` 回调的类型没标 `@MainActor`:先取出字符串再 `Task { @MainActor in … }` 落账。

## 13. 错误

`ErikaError` → 取 `message` 包成 `PlayerError`;其它错误 → `String(describing:)`。事件里的 `error` → 相位 `failed` + `.error` + `.ended(.error)`。
播放失败后记 `NetworkDiagnostics.recordPlaybackFailure(...)`,并无条件跑一次 `PlaybackFailureProbe`。
⛔ 错误消息不含完整播放 URL,经 `SecretRedactor`。`ErikaError.statusCode` 未使用(Q53)。

## 14. 待真机核实

集中登记在 `KNOWN_ISSUES.md` E 节(Q43–Q55),`ErikaPlaybackEngine.swift` 与 `EofDetector.swift` 顶部注释有同一份清单。
核实后只改 `Core/Erika/`,并回填那里与这里。
