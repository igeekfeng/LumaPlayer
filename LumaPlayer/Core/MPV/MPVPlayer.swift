import Foundation
import OpenGL
import OpenGL.GL3
import os
import mpv
import Synchronization

/// `MPVPlayer` 的生命周期状态机(MPV_INTEGRATION.md §8)。
///
/// ```text
/// idle ──load()──▶ loading ──FILE_LOADED──▶ playing ⇄ paused
///                    │                        │
///                    └──失败──────────────▶ failed
/// playing/paused/… ──stop()/shutdown()──▶ tearingDown ──▶ destroyed
/// ```
///
/// destroyed 不可复用(一个实例一次只播一个 URL;换台 = 销毁重建)。
enum MPVPlayerPhase: String, Sendable, Equatable {
    case idle
    case loading
    case playing
    case paused
    case failed
    case tearingDown
    case destroyed
}

/// 播放统计(诊断用:渲染帧数、time-pos 原始回调频率、hwdec;开发期渲染 spike 靠它取证)。
struct MPVPlayerStatistics: Sendable, Equatable {
    /// `mpv_render_context_render` 实际执行次数(GL draw 轮询 update flags 置位时)
    var renderedFrames = 0
    /// 节流**之前**的 time-pos 属性变化次数(衡量 M6 原始频率)
    var timePosEvents = 0
    /// 第一次 / 最近一次 time-pos 事件时刻(秒,用于计算平均频率)
    var timePosFirstAt: Double?
    var timePosLastAt: Double?
    /// 最后一次 `hwdec-current`
    var hwdecCurrent: String?
    /// `renderIntoBoundFramebuffer` 的进入次数(S2 诊断:draw 是否在跑)
    var drawCalls = 0
    /// 最近一次 `mpv_render_context_update()` 返回值(0 = 无新帧)
    var lastUpdateFlags: UInt64 = 0
    /// update() 返回值里 MPV_RENDER_UPDATE_FRAME 置位的次数(新帧流动证明)
    var updateFrameFlags = 0
    /// attachGLContext 是否成功创建过 GL 渲染上下文
    var glAttached = false
    /// 当前渲染上下文的后端：`"gpu-next"` / `"gpu"`(legacy 或回退)。
    /// `automatic` 策略下起初是 `"gpu"`,DV 片源会在 `on_preloaded` 时换成 `"gpu-next"`。
    /// ⚠️ 这是**请求并成功建起**的后端名，不等于 mpv 内部一定用了它：
    /// 实测后端名不被识别时 mpv 会静默退回默认 gpu 渲染器而不报错
    /// (见 `createRenderContext` 注释)。要确证得看 mpv 日志里的
    /// `Using gpu-next backend.` 行。
    var renderBackend: String?
}

/// 单个异步属性请求的完成闸。取消可能先于 continuation 注册,结果必须留到注册时交付。
/// 所有可变状态由 Mutex 保护;finish/install 都在锁外 resume,且恰好完成一次。
final class MPVPropertyRequest: Sendable {
    private struct State {
        var continuation: CheckedContinuation<String?, any Error>?
        var result: Result<String?, any Error>?
    }
    let name: String
    private let state = Synchronization.Mutex(State())

    init(name: String) { self.name = name }

    var isFinished: Bool { state.withLock { $0.result != nil } }

    func install(_ continuation: CheckedContinuation<String?, any Error>) {
        let result: Result<String?, any Error>? = state.withLock { state in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil as Result<String?, any Error>?
        }
        if let result { continuation.resume(with: result) }
    }

    func finish(_ result: Result<String?, any Error>) {
        let continuation = state.withLock { state in
            guard state.result == nil else { return nil as CheckedContinuation<String?, any Error>? }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

/// 请求/回复簿,只在 MPVPlayer 的 state mutex 内访问。非零 id 在同一实例内不复用。
struct MPVPropertyRequests {
    private var nextID: UInt64 = 0
    private var pending: [UInt64: MPVPropertyRequest] = [:]

    mutating func insert(_ request: MPVPropertyRequest) throws -> UInt64 {
        guard nextID < UInt64.max else {
            throw MPVError.commandFailed(code: MPV_ERROR_GENERIC.rawValue, message: "属性请求 id 已耗尽")
        }
        nextID += 1
        pending[nextID] = request
        return nextID
    }

    mutating func take(_ id: UInt64) -> MPVPropertyRequest? { pending.removeValue(forKey: id) }

    mutating func remove(_ request: MPVPropertyRequest) {
        if let id = pending.first(where: { $0.value === request })?.key { pending.removeValue(forKey: id) }
    }

    mutating func takeAll() -> [MPVPropertyRequest] {
        let requests = Array(pending.values)
        pending.removeAll()
        return requests
    }
}

/// libmpv 的薄 Swift 封装(业务代码不得直接调 C API,MPV_INTEGRATION.md §1)。
///
/// ## 线程安全论证(`@unchecked Sendable`)
/// - mpv client API 本身全线程安全(client.h「The client API is generally
///   fully thread-safe」);本类的全部可变状态都放在 `state` 锁内;
/// - mpv 句柄一经创建不再更换,只在 `shutdown()` 里销毁并置 nil(锁内);
/// - 调用方(MainActor)、mpv 事件线程、CAOpenGLLayer 渲染线程三方并发,
///   分别经 `state` 锁或 mpv 自身线程安全保证串行;
/// - Core/MPV/ 是全项目唯一允许并发逃逸的目录(CLAUDE.md「并发分层」),
///   已登记 docs/MPV_INTEGRATION.md §6.3。
final class MPVPlayer: @unchecked Sendable {

    // MARK: - 内部状态

    /// C 指针的 Sendable 包装(Core/MPV/ 允许的并发逃逸点)。
    /// 论证:指针只作为「句柄」跨隔离域传递;所有实际调用 C API 的
    /// 解引用都发生在 `state` 锁内;生命周期(teardown/destroy)同样
    /// 在锁内串行。已登记 docs/MPV_INTEGRATION.md §6.3。
    fileprivate struct LockedPointer<Pointee>: @unchecked Sendable {
        let raw: Pointee
        init(_ raw: Pointee) { self.raw = raw }
    }

    private struct MutableState {
        var phase: MPVPlayerPhase = .idle
        var handle: LockedPointer<OpaquePointer>?
        var renderContext: LockedPointer<OpaquePointer>?
        /// 挂接的 CGL context(render.h 66-69:mpv_render* 全部调用都要求
        /// 该 GL context 在调用线程 current;shutdown 里 free 渲染上下文前
        /// 需要它来恢复 current)
        var cglContext: LockedPointer<CGLContextObj>?
        var bridge: MPVEventBridge?
        /// 本片源该用的渲染后端。起初是策略的 `initialBackend`,`on_preloaded`
        /// 按轨道定下来之后改写;layer 重挂 GL context 时按它重建。
        var targetBackend: MPVRenderBackend = .legacy
        var stats = MPVPlayerStatistics()
        /// init 失败的原因(phase == .failed 时有值)
        var initializationFailure: String?
        /// `load()` 是否已调用过。§8「一个实例一次只播一个 URL,换台 =
        /// 销毁重建」是一次性契约,不能只靠 phase 把关:EOF 之后 phase
        /// 不会停在某个「已结束」态(§8 的状态机里根本没有这个态),
        /// 单靠 phase 判断会让同一实例被二次 load。
        var hasLoaded = false
        /// 拆卸信号。事件线程的退出条件**只看它**,不看 phase。
        ///
        /// 为什么不能用 `phase == .tearingDown` 当退出条件:事件线程自己
        /// 会在 START_FILE / FILE_LOADED / END_FILE(error) / SHUTDOWN 里
        /// 无条件改写 phase。关窗时 mpv 往往正好投递一个 END_FILE,
        /// 于是 tearingDown 被覆写成 failed,循环条件失效、线程回到
        /// `mpv_wait_event` 继续阻塞,而 `shutdown()` 是在**主线程**上
        /// 同步等它——整整 5s 超时,UI 冻结。一次性写入的 isStopping
        /// 不会被任何 phase 迁移抹掉。
        var isStopping = false
        /// 已画出过第一帧**真实视频帧**(`firstVideoFrameRendered` 只发一次)
        var hasRenderedVideoFrame = false
        /// 最近的 mpv 日志(已脱敏、按条截断),环形缓冲。
        /// 只用于播放失败时留档:`Unrecognized file format` 之类的错误码本身看不出
        /// 服务端回的是媒体、HTML 还是 JSON 错误页,demuxer / ffmpeg 的日志才有线索。
        var recentLogs: [String] = []
        var propertyRequests = MPVPropertyRequests()
        /// 事件循环已经退出时拒绝新读取,否则不会再有 GET_PROPERTY_REPLY。
        var eventLoopEnded = false
    }

    /// 环形缓冲保留的日志条数 / 单条字符上限
    private static let recentLogLimit = 200
    private static let recentLogLineLimit = 300

    /// 互斥锁(非重入)。为什么不用 `OSAllocatedUnfairLock`:它的
    /// `withLock` 闭包是 `@Sendable` 且要求返回值 `Sendable`,
    /// 与「锁内调用 C API、返回非 Sendable 指针」的本类用法天然冲突
    /// (Core/MPV/ 允许的逃逸场景,论证见类注释)。
    private final class Mutex: Sendable {
        private let lock = NSLock()
        func withLock<R>(_ body: () throws -> R) rethrows -> R {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
    }

    /// 仅在 `mutex` 内访问(字段含 C 指针,无 Sendable 约束)
    private var state = MutableState()
    private let mutex = Mutex()

    /// 「有东西要画」标志:mpv 的 update 回调、layer 尺寸变化置位,draw 取走(`needsRender`)。
    ///
    /// 为什么是原子量而不放进 `state`:update 回调由 mpv 的 VO 线程在**持有 mpv 内部锁**时调用
    /// (vo_libmpv.c `update()`),而 `shutdown()` / 换后端是在持有 `mutex` 时调 `mpv_render_context_free`,
    /// 后者要等 VO 线程退出 —— 回调里抢 `mutex` 就是互等死锁。
    private final class RenderRequest: Sendable {
        /// 初值为真:渲染上下文刚建好时先画一次
        private let pending = Atomic<Bool>(true)
        func set() { pending.store(true, ordering: .releasing) }
        var isSet: Bool { pending.load(ordering: .acquiring) }
        func take() { pending.store(false, ordering: .releasing) }
    }

    /// 生命周期 ≥ 渲染上下文:回调上下文按 unretained 指针交给 mpv,而渲染上下文在 `shutdown()`
    /// (含 deinit 兜底,属性此时尚未释放)里 free,free 返回后 mpv 不再调回调。
    private let renderRequest = RenderRequest()

    /// 渲染上下文专用锁:只在 GL draw 线程的 render、`attachGLContext`
    /// 的 create、`shutdown()` 的 free 三者之间互斥。
    ///
    /// 为什么要和 `mutex` 分开:`mutex` 是 MainActor 侧 `phase` / `pause()` /
    /// `seek()` 也要抢的锁,若整帧渲染都持有它,主线程每次调用都要排队等一次
    /// GPU 提交(§6.3「渲染路径内不得做重活」)。拆开后渲染只与生命周期互斥,
    /// 不再阻塞 MainActor。
    ///
    /// ⚠️ 锁序恒为 `renderMutex` → `mutex`,任何地方都不得反向,否则死锁。
    private let renderMutex = Mutex()

    /// 同时需要「渲染上下文不被换掉」和「state 可写」时的唯一入口。
    /// 把锁序固化在这里,调用点就不可能写反(attach / free 两处都走它)。
    private func withRenderAndStateLock<R>(_ body: () -> R) -> R {
        renderMutex.withLock { mutex.withLock(body) }
    }

    /// 事件线程退出信号(shutdown 等待它,确保销毁时无并发 wait_event)
    private let eventThreadDone = DispatchSemaphore(value: 0)

    /// 运行时打印一次 client API 版本(§4:确认与 3.1.1 版本表一致)
    private static let loggedClientAPIVersion: Int32 = {
        let raw = mpv_client_api_version()
        let major = Int32((raw >> 16) & 0xFFFF)
        let minor = Int32(raw & 0xFFFF)
        FileHandle.standardError.write(
            Data("[MPV] mpv_client_api_version = \(major).\(minor)\n".utf8))
        return Int32(raw)
    }()

    /// OpenGL 框架的 dlopen 句柄,供 `get_proc_address` 解析 GL 符号。
    /// (mpv 不直接链 GL,符号必须由宿主提供,render_gl.h。)
    /// 用实例属性而非 static let:UnsafeMutableRawPointer 非 Sendable,
    /// static 需 Sendable 类型;dlopen 幂等(返回同一句柄),每实例一次零成本。
    private let openGLFramework =
        dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY)

    /// §3 必设选项(全部在 `mpv_initialize` 之前,用 init 前合法的
    /// `mpv_set_option_string` 设置;`config`/`terminal` 是防御性显式设置)。
    private static let startupOptions: [(name: String, value: String)] = [
        ("config", "no"),
        ("load-scripts", "no"),
        ("terminal", "no"),
        // 禁内置 ytdl_hook:它在无 yt-dlp 时每次起播刷 "Subprocess failed" 挤掉真正的失败线索
        // (`load-scripts=no` 只管用户脚本,管不到它)。
        ("ytdl", "no"),
        // 其余保持 warn;仅打开打开流 / 探测格式的几个模块,供 issue #2 类失败取证。
        ("msg-level", "all=warn,stream=v,demux=v,lavf=v,ffmpeg=v"),
        ("vo", "libmpv"),
        ("hwdec", "auto"),
        ("cache", "yes"),
        // 128 MiB 起点(§3:值待 M2 用真实码率流实测后调整)
        ("demuxer-max-bytes", "134217728"),
        // 不提前渲染再等:默认 0.05 时 `mpv_render_context_render` 画完要阻塞到这一帧的上屏时刻,
        // 而 `CAOpenGLLayer` 的 draw 跑在主线程 → 播放时主线程约 78% 时间卡在等待里,
        // 界面与弹幕被压到视频帧率(render.h `MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME`;PITFALLS「渲染阻塞主线程」)
        ("video-timing-offset", "0"),
    ]

    /// §6.1 需要观察的属性(demuxer-cache-state 未使用)。
    private static let observedProperties: [(name: String, format: mpv_format)] = [
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("pause", MPV_FORMAT_FLAG),
        ("eof-reached", MPV_FORMAT_FLAG),
        ("seeking", MPV_FORMAT_FLAG),
        ("paused-for-cache", MPV_FORMAT_FLAG),
        ("volume", MPV_FORMAT_DOUBLE),
        ("speed", MPV_FORMAT_DOUBLE),
        ("hwdec-current", MPV_FORMAT_STRING),
        // 轨道菜单(第 7 节)与静音(PlayerCommands.swift 的 M 键)。
        // track-list 是 NODE:一次拿到全部轨道,比逐个读 track-list/N/* 便宜。
        ("track-list", MPV_FORMAT_NODE),
        ("mute", MPV_FORMAT_FLAG),
        // 字幕延迟(MPV_INTEGRATION.md 7.1):读回值驱动屏显与菜单里的当前值
        ("sub-delay", MPV_FORMAT_DOUBLE),
    ]

    /// GL 符号解析回调(ctx = `openGLFramework` 的 dlopen 句柄)。
    /// 注意第二个参数是 Optional(render_gl.h 的 C 签名允许 NULL)。
    private let getProcAddress: @convention(c) (
        UnsafeMutableRawPointer?, UnsafePointer<CChar>?
    ) -> UnsafeMutableRawPointer? = { frameworkHandle, name in
        guard let frameworkHandle, let name else { return nil }
        return dlsym(frameworkHandle, name)
    }

    /// 渲染后端策略(设置 →「播放 → 色彩」,见 `MPVRenderBackendPolicy`)。
    private let backendPolicy: MPVRenderBackendPolicy

    /// `automatic` 策略注册的 hook 名。loadfile.c 里它在「demuxer 轨道已加入」之后、
    /// 「选轨 / 建解码器与 VO」之前运行 —— 轨道的 DV 配置记录已可读,渲染上下文又还没被 VO 用上,
    /// 换后端不用重开流。
    private static let preloadedHook = "on_preloaded"

    // MARK: - 生命周期

    init(backendPolicy: MPVRenderBackendPolicy = .automatic) {
        self.backendPolicy = backendPolicy
        _ = Self.loggedClientAPIVersion

        guard let handle = mpv_create() else {
            mutex.withLock { state.phase = .failed; state.initializationFailure = "mpv_create 返回 NULL" }
            return
        }

        // 默认 UA 是 `libmpv`,与 Authorization 里的 Client 不一致(issue #2)
        for (name, value) in Self.startupOptions + [("user-agent", ClientUserAgent.value)] {
            let err = mpv_set_option_string(handle, name, value)
            guard err >= 0 else {
                let failure = "选项 \(name)=\(value) 设置失败: "
                    + String(cString: mpv_error_string(err))
                mpv_terminate_destroy(handle)
                mutex.withLock { state.phase = .failed; state.initializationFailure = failure }
                return
            }
        }

        let err = mpv_initialize(handle)
        guard err >= 0 else {
            let failure = "mpv_initialize 失败: " + String(cString: mpv_error_string(err))
            mpv_terminate_destroy(handle)
            mutex.withLock { state.phase = .failed; state.initializationFailure = failure }
            return
        }

        // 失败取证:v 级日志进环形缓冲,只在播放失败时随诊断日志落盘(见 recentLogLines)。
        // 失败不影响播放,但不静默:记一行 stderr。
        let logStatus = mpv_request_log_messages(handle, "v")
        if logStatus < 0 {
            logLine("[MPV] 警告: mpv_request_log_messages 失败: \(String(cString: mpv_error_string(logStatus)))")
        }

        for (name, format) in Self.observedProperties {
            // mpv 的 C enum 无 enum_extensibility 标注,Swift 导入为 struct,
            // 参数直接传常量本身(不是 rawValue)
            _ = mpv_observe_property(handle, 0, name, format)
        }

        // 按片源选后端要在轨道已知、VO 未建时插一脚(见 `handlePreloadedHook`)。
        // 注册失败不致命:退化为一直用 legacy(DV 会发紫发绿),但要留痕。
        if backendPolicy == .automatic {
            let hookStatus = mpv_hook_add(handle, 0, Self.preloadedHook, 0)
            if hookStatus < 0 {
                logLine("[MPV] 警告: mpv_hook_add(\(Self.preloadedHook)) 失败,"
                    + "本次固定用 legacy 渲染器: \(String(cString: mpv_error_string(hookStatus)))")
            }
        }

        mutex.withLock {
            state.handle = LockedPointer(handle)
            state.targetBackend = backendPolicy.initialBackend
        }

        // Thread 闭包是 @Sendable,句柄经 LockedPointer 捕获传递(见其论证)。
        //
        // ⚠️ 这里刻意不写成 `Thread { [weak self] in self?.eventLoop(...) }`:
        // optional chaining 会把 weak 提升成强引用,并持有到 eventLoop 返回为止,
        // 而 eventLoop 只有 shutdown() 把 phase 置成 tearingDown 才会返回。
        // 结果是「调用方丢弃实例但忘了 shutdown」时引用计数永不归零,
        // deinit 里的兜底 shutdown 形同虚设,句柄与线程永久泄漏。
        // 正确做法:强引用逐轮获取、逐轮释放,阻塞在 mpv_wait_event 期间
        // 不持有 self;退出信号用值捕获的信号量,这样即便拥有者已经释放,
        // 仍能唤醒正在 wait 的 shutdown()。
        let boxedHandle = LockedPointer(handle)
        let owner: @Sendable () -> MPVPlayer? = { [weak self] in self }
        let done = eventThreadDone
        let thread = Thread {
            Self.runEventLoop(handle: boxedHandle, owner: owner, done: done)
        }
        thread.name = "mpv-event-loop"
        // 事件线程承载 phase 迁移等 UI 前置状态,且 shutdown 会同步等它退出;
        // Default QoS 会让高 QoS 调用方(MainActor/测试)等低 QoS 线程,
        // XCTest 把它报成优先级反转 warning——按事件驱动的 UI 语义给满 QoS
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    deinit {
        // 安全网:正常路径应已由视图拆卸 / 调用方触发 shutdown;
        // 兜底防止 mpv 句柄泄漏(线程安全,可重入)。
        shutdown()
    }

    /// 有序销毁(§6.3 顺序:wakeup 停事件循环 → render_context_free →
    /// core 销毁,顺序不可换)。可重入:重复调用直接返回,不崩溃(有测试)。
    func shutdown() {
        let teardown = mutex.withLock { () -> (LockedPointer<OpaquePointer>?, [MPVPropertyRequest]) in
            guard !state.isStopping, state.phase != .destroyed,
                  let h = state.handle else {
                return (nil, [])
            }
            state.phase = .tearingDown
            state.isStopping = true
            state.bridge?.submit(.phaseChanged(.tearingDown))
            return (h, state.propertyRequests.takeAll())
        }
        // 在等待事件线程之前、且锁外完成:取消/销毁不依赖核心把属性回复送回来。
        teardown.1.forEach { $0.finish(.failure(MPVError.instanceDestroyed)) }
        guard let handle = teardown.0 else { return }

        // 1. 唤醒阻塞在 mpv_wait_event 里的事件线程
        mpv_wakeup(handle.raw)

        // 2. 等事件线程退出(它看到 tearingDown 后会跳出循环并 signal)
        let joined = eventThreadDone.wait(timeout: .now() + 5)
        if joined != .success {
            logLine("[MPV] 警告: 事件线程 5s 内未退出,继续强制销毁")
        }

        // 3. 释放渲染上下文(必须先于 core 销毁,render.h:119-122)。
        //    锁序 renderMutex → mutex:renderMutex 保证此刻没有 draw 线程
        //    正在 render,mutex 保护 state 字段本身。
        //    render.h 66-69 要求 mpv_render* 调用时 GL context 在调用线程
        //    current——free 也不例外,因此借用挂接的 CGL context 并在结束后
        //    恢复原状(CGLSetCurrentContext(nil) = 解绑,合法)。
        withRenderAndStateLock {
            if let rctx = state.renderContext {
                let previous = CGLGetCurrentContext()
                CGLSetCurrentContext(state.cglContext?.raw)
                mpv_render_context_free(rctx.raw)
                CGLSetCurrentContext(previous)
                state.renderContext = nil
            }
            // 与 attachGLContext 里的 CGLRetainContext 配对:layer 可能
            // 早于本次 shutdown 就把它自己那份引用还掉了,没有这对
            // retain/release,上面那行 CGLSetCurrentContext 就是在用
            // 已释放的 context。
            if let cgl = state.cglContext {
                CGLReleaseContext(cgl.raw)
                state.cglContext = nil
            }
        }

        // 4. 销毁 core(在锁内:阻止并发 API 调用拿到悬垂句柄)
        mutex.withLock {
            mpv_terminate_destroy(handle.raw)
            state.handle = nil
            state.phase = .destroyed
            state.bridge?.submit(.phaseChanged(.destroyed))
        }
    }

    // MARK: - 播放控制(状态机见 MPV_INTEGRATION.md 第 8 节)

    /// 加载并播放。一个实例只播一个 URL(§8:换台 = 销毁重建,不做复用)。
    /// headers 经 `MPV_FORMAT_NODE` 数组按 §5.1 路径 A 设置(结构化传值,
    /// 值内逗号无需转义),时机在 initialize 之后、loadfile 之前——
    /// `http-header-fields` 是运行时可改属性(§5.1)。
    func load(url: URL, headers: [String: String]) throws {
        try withLiveHandle { handle, s in
            // hasLoaded 而不是只看 phase:播放自然结束后 phase 并不会落到
            // 某个「已结束」态(§8 状态机没有这个态),只判 phase 会让同一
            // 实例被二次 load,而 headers / renderContext / 统计计数器全是
            // 上一轮的——跨服务器时甚至会沿用上一台的认证头。
            guard !s.hasLoaded else {
                throw MPVError.commandFailed(
                    code: MPV_ERROR_GENERIC.rawValue,
                    message: "load 只能调用一次(一个实例只播一个 URL,§8:换台 = 销毁重建)")
            }
            guard s.phase == .idle else {
                throw MPVError.commandFailed(
                    code: MPV_ERROR_GENERIC.rawValue,
                    message: "load 只能在 idle 阶段调用一次(一个实例只播一个 URL)")
            }
            try setHTTPHeaderFields(headers, on: handle)
            try mpvCommand(["loadfile", url.absoluteString], on: handle)
            s.hasLoaded = true
            s.phase = .loading
        }
    }

    func pause() throws {
        try setFlagProperty("pause", true)
    }

    func resume() throws {
        try setFlagProperty("pause", false)
    }

    func seek(to seconds: Double) throws {
        try withLiveHandle { handle, _ in
            try mpvCommand(
                ["seek", String(format: "%.3f", seconds), "absolute+exact"],
                on: handle)
        }
    }

    /// 0–100(§6.1 volume 属性)
    func setVolume(_ volume: Double) throws {
        try withLiveHandle { handle, _ in
            var v = max(0, min(100, volume))
            let err = mpv_set_property(handle, "volume", MPV_FORMAT_DOUBLE, &v)
            guard err >= 0 else { throw mpvFailure(err, "设置 volume") }
        }
    }

    /// 播放速率(§6.1 `speed`,RW)。范围收在 0.25–4,超出的值 mpv 虽然接受,
    /// 但音频会严重失真,UI 也不会给出这样的档位。
    func setSpeed(_ speed: Double) throws {
        try withLiveHandle { handle, _ in
            var v = max(0.25, min(4, speed))
            let err = mpv_set_property(handle, "speed", MPV_FORMAT_DOUBLE, &v)
            guard err >= 0 else { throw mpvFailure(err, "设置 speed") }
        }
    }

    /// 静音(§6.1 的 `mute`;PlayerCommands.swift 的 M 键)。
    /// 与 `volume = 0` 不是一回事:静音要能原样恢复音量。
    func setMuted(_ muted: Bool) throws {
        try setFlagProperty("mute", muted)
    }

    // MARK: - 轨道

    /// 选音轨:设 `aid` = track id(MPV_INTEGRATION.md 第 7 节)。
    func selectAudioTrack(id: Int) throws {
        try setStringProperty("aid", String(id))
    }

    /// 选字幕轨:设 `sid` = track id;传 nil 表示关字幕(`sid` = `no`)。
    func selectSubtitleTrack(id: Int?) throws {
        try setStringProperty("sid", id.map(String.init) ?? "no")
    }

    /// 挂一条**外挂字幕**(`sub-add` 命令)。
    ///
    /// ## 为什么需要它
    ///
    /// 网盘里的片源常把字幕单独放成 `.srt` / `.ass`,它们不在视频容器里 ——
    /// 内核自己发现不了,只能由客户端显式加轨。百度没有任何字幕接口,所以这是
    /// 「同目录字幕」唯一能落地的通路(配对在 `BaiduPanSubtitle`,纯本地)。
    ///
    /// ## 两个必须说清的约束
    ///
    /// 1. **必须在文件加载之后调用**:`sub-add` 在 `no file loaded` 时直接失败。
    ///    调用方是 `PlayerViewModel` 的 `.playing` 事件,不是 `load()` 之后立刻。
    /// 2. flags 用 `auto`:没有选中任何字幕时自动选上这条,**已经有用户选过的轨
    ///    就不抢**(与 Plex 的行为一致)。真正的选择仍走 `sid`。
    ///
    /// ⚠️ 地址里的凭据(百度 `access_token`)必须已经带好 —— 这里只负责传地址;
    /// 请求头沿用 `load()` 时设的 `http-header-fields`(字幕与主文件同一个 UA)。
    func addSubtitle(url: URL, title: String?) throws {
        try withLiveHandle { handle, _ in
            var args = ["sub-add", url.absoluteString, "auto"]
            if let title, !title.isEmpty { args.append(title) }
            try mpvCommand(args, on: handle)
        }
    }

    // MARK: - 字幕延迟与外观(MPV_INTEGRATION.md 7.1)

    /// 字幕延迟(秒,`sub-delay`,RW):正值 = 字幕晚于画面出现,负值 = 提前。
    /// 只作用于 mpv 自己渲染的字幕轨;服务端烧录进画面的字幕(转码)调不动。
    func setSubtitleDelay(_ seconds: Double) throws {
        try withLiveHandle { handle, _ in
            var v = seconds
            let err = mpv_set_property(handle, "sub-delay", MPV_FORMAT_DOUBLE, &v)
            guard err >= 0 else { throw mpvFailure(err, "设置 sub-delay") }
        }
    }

    /// 一组字幕外观属性(`sub-scale` / `sub-color` / `sub-border-style` …)。
    /// 值由 `SubtitleStyle.mpvProperties` 生成;全是运行时可改的选项属性,
    /// 播放中改也立即生效。
    ///
    /// 只放行 `sub-` 前缀:这是给字幕外观开的口子,⛔ 不是通用的「随便设个属性」,
    /// 业务代码借它绕过封装去改别的选项会让本类型的状态机失去意义。
    /// 中途某一项被拒即抛错,前面已设上的保持生效(mpv 无批量事务)。
    func setSubtitleProperties(_ properties: [(name: String, value: String)]) throws {
        try withLiveHandle { handle, _ in
            for (name, value) in properties {
                guard name.hasPrefix("sub-") else {
                    throw MPVError.commandFailed(
                        code: MPV_ERROR_INVALID_PARAMETER.rawValue,
                        message: "setSubtitleProperties 只接受 sub-* 属性,收到 \(name)")
                }
                let err = mpv_set_property_string(handle, name, value)
                guard err >= 0 else { throw mpvFailure(err, "设置 \(name)=\(value)") }
            }
        }
    }

    // MARK: - 轮询读取(统计信息 / 缓冲进度)

    /// 一次读出若干属性的字符串形式(`mpv_get_property_string`)。
    ///
    /// 仅为既有同步测试/探针保留。此方法持 state mutex 等待核心,不得用于 MainActor 播放监控;
    /// 生产统计/缓冲轮询改用 stringPropertiesAsync,避免阻塞界面与 render 取状态锁。
    /// 当前不可用的属性(没有视频轨时的 `video-params/w`、未缓冲时的
    /// `cache-buffering-state`)mpv 返回 NULL,结果里就没有这个键 —— 不填占位值。
    /// 为兼容旧测试,实例已销毁 / 初始化失败时仍返回空字典;异步 API 则明确抛错。
    func stringProperties(_ names: [String]) -> [String: String] {
        do {
            return try withLiveHandle { handle, _ in
                var values: [String: String] = [:]
                for name in names {
                    guard let raw = mpv_get_property_string(handle, name) else { continue }
                    values[name] = String(cString: raw)
                    mpv_free(raw)
                }
                return values
            }
        } catch {
            return [:]
        }
    }

    /// 监控专用读取:只在 state mutex 内快速 enqueue `mpv_get_property_async`,
    /// 等核心的工作不持 mutex、不占 MainActor。轮内逐个等待,不同时排满事件队列。
    /// unavailable 是合法的缺项;其它错误明确抛出。同步 stringProperties 仅保留兼容旧测试。
    func stringPropertiesAsync(_ names: [String]) async throws -> [String: String] {
        try Task.checkCancellation()
        // 空轮也遵守生命周期契约,不让 destroyed 看起来读取成功。
        try withLiveHandle { _, state in
            guard !state.isStopping, !state.eventLoopEnded else { throw MPVError.instanceDestroyed }
        }
        var values: [String: String] = [:]
        var seen: Set<String> = []
        for name in names where seen.insert(name).inserted {
            try Task.checkCancellation()
            if let value = try await stringPropertyAsync(name) { values[name] = value }
        }
        try Task.checkCancellation()
        return values
    }

    private func stringPropertyAsync(_ name: String) async throws -> String? {
        let request = MPVPropertyRequest(name: name)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                do {
                    try withLiveHandle { handle, state in
                        guard !state.isStopping, !state.eventLoopEnded else { throw MPVError.instanceDestroyed }
                        // 取消可先于注册;完成闸已记住取消时不要再 enqueue。
                        guard !request.isFinished else { return }
                        let id = try state.propertyRequests.insert(request)
                        let status = mpv_get_property_async(handle, id, name, MPV_FORMAT_STRING)
                        if status < 0 {
                            _ = state.propertyRequests.take(id)
                            throw mpvFailure(status, "请求读取 \(name)")
                        }
                    }
                } catch {
                    request.finish(.failure(error))
                }
            }
        } onCancel: {
            // 属性 API 不支持 abort_async_command。先完成 Swift 等待,再从匹配簿移除。
            // 如注册已持有 mutex,移除会等其快速 enqueue 返回;若尚未注册,isFinished 会挡下它。
            request.finish(.failure(CancellationError()))
            self.mutex.withLock { self.state.propertyRequests.remove(request) }
        }
    }

    private func processPropertyReply(_ event: mpv_event) {
        guard let request = mutex.withLock({ state.propertyRequests.take(event.reply_userdata) }) else { return }
        let result: Result<String?, any Error>
        if event.error == MPV_ERROR_PROPERTY_UNAVAILABLE.rawValue {
            result = .success(nil)
        } else if event.error < 0 {
            result = .failure(mpvFailure(event.error, "读取 \(request.name)"))
        } else if let raw = event.data {
            let property = raw.assumingMemoryBound(to: mpv_event_property.self).pointee
            if let name = property.name, String(cString: name) == request.name,
               property.format == MPV_FORMAT_STRING, let data = property.data,
               let value = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                // 事件内存归 mpv,只活到下一次 wait_event;锁外复制并且不得 mpv_free。
                result = .success(String(cString: value))
            } else {
                result = .failure(mpvFailure(MPV_ERROR_PROPERTY_FORMAT.rawValue, "属性回复格式/名称不匹配"))
            }
        } else {
            result = .failure(mpvFailure(MPV_ERROR_PROPERTY_ERROR.rawValue, "属性回复缺少数据"))
        }
        request.finish(result)
    }

    private func failPropertyRequests(_ error: any Error, eventLoopEnded: Bool = false) {
        let requests = mutex.withLock {
            if eventLoopEnded { state.eventLoopEnded = true }
            return state.propertyRequests.takeAll()
        }
        requests.forEach { $0.finish(.failure(error)) }
    }

    /// 按目标后端建渲染上下文;gpu-next 建不起来就回退 legacy —— 宁可 DV 发紫发绿也不能黑屏。
    /// ⚠️ 后端名不被识别时 mpv 静默退回默认 gpu 且返回成功(实测),
    /// 所以这里的回退只覆盖「create 真失败」,见 `createRenderContext`。
    /// 返回实际建起的后端。调用方必须已持有 `renderMutex` 且该 GL context 在调用线程 current。
    private func buildRenderContext(
        handle: OpaquePointer,
        framework: UnsafeMutableRawPointer,
        target: MPVRenderBackend
    ) -> Result<(context: OpaquePointer, backend: MPVRenderBackend), MPVError> {
        let first = createRenderContext(
            handle: handle, framework: framework,
            backend: target == .gpuNext ? MPVRenderBackend.gpuNext.rawValue : nil)
        let built: Result<(context: OpaquePointer, backend: MPVRenderBackend), MPVError>
        switch first {
        case .success(let context):
            built = .success((context, target))
        case .failure(let error) where target == .gpuNext:
            logLine("[MPV] gpu-next 后端创建失败(\(error)),回退 legacy gpu 渲染器")
            built = createRenderContext(handle: handle, framework: framework, backend: nil)
                .map { ($0, .legacy) }
        case .failure(let error):
            built = .failure(error)
        }
        if case .success(let result) = built {
            registerUpdateCallback(on: result.context)
        }
        return built
    }

    /// mpv 有新帧 / 重绘请求时置位 `renderRequest`,layer 据此决定这一 vsync 画不画(`needsRender`)。
    /// 注册时 mpv 会立即调一次回调(vo_libmpv.c),等于「新上下文先画一帧」。
    ///
    /// 回调约束(render.h「Threading」):任意 mpv 线程、持锁调用,⛔ 不得调 mpv API、不得等锁 —— 只翻原子标志。
    private func registerUpdateCallback(on renderContext: OpaquePointer) {
        mpv_render_context_set_update_callback(
            renderContext,
            { context in
                guard let context else { return }
                Unmanaged<RenderRequest>.fromOpaque(context).takeUnretainedValue().set()
            },
            Unmanaged.passUnretained(renderRequest).toOpaque())
    }

    /// 用指定后端建 mpv 渲染上下文。`backend` 为 nil = 不传该参数,用 mpv 默认。
    ///
    /// ⚠️ 实测(mpv 0.41 + #16818):**后端名不认识时 mpv 不报错**,静默退回默认
    /// gpu 渲染器并返回成功。所以「create 成功」不等于「gpu-next 真的生效」,
    /// 回退逻辑不能只靠返回值判断。要确证得看 mpv 日志的
    /// `Using gpu-next backend.` / `Using default gpu backend.` 行。
    /// 调用方必须已持有 `renderMutex` 且该 GL context 在调用线程 current。
    private func createRenderContext(
        handle: OpaquePointer,
        framework: UnsafeMutableRawPointer,
        backend: String?
    ) -> Result<OpaquePointer, MPVError> {
        var initParams = mpv_opengl_init_params(
            get_proc_address: getProcAddress,
            get_proc_address_ctx: framework)
        var renderContext: OpaquePointer?
        var failure: MPVError?
        withUnsafeMutableBytes(of: &initParams) { paramsPtr in
            // MPV_RENDER_API_TYPE_OPENGL 是 #define 宏(render.h:468),
            // Swift 不可见,值即 "opengl"
            "opengl".withCString { typePtr in
                // backend 的 C 字符串只需在 create 调用期间有效 —— mpv 在
                // create 内即做 strcmp,withCString 的作用域已足够。
                func makeParams(_ backendPtr: UnsafePointer<CChar>?) -> [mpv_render_param] {
                    var params: [mpv_render_param] = [
                        mpv_render_param(
                            type: MPV_RENDER_PARAM_API_TYPE,
                            data: UnsafeMutableRawPointer(mutating: typePtr)),
                        mpv_render_param(
                            type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                            data: paramsPtr.baseAddress),
                    ]
                    if let backendPtr {
                        params.append(mpv_render_param(
                            type: MPV_RENDER_PARAM_BACKEND,
                            data: UnsafeMutableRawPointer(mutating: backendPtr)))
                    }
                    // 参数数组必须以 MPV_RENDER_PARAM_INVALID(=0)收尾
                    params.append(mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil))
                    return params
                }
                let err: Int32
                if let backend {
                    err = backend.withCString { ptr in
                        var params = makeParams(ptr)
                        return mpv_render_context_create(&renderContext, handle, &params)
                    }
                } else {
                    var params = makeParams(nil)
                    err = mpv_render_context_create(&renderContext, handle, &params)
                }
                if err < 0 {
                    failure = mpvFailure(err, "mpv_render_context_create")
                }
            }
        }
        if let failure { return .failure(failure) }
        guard let renderContext else { return .failure(.renderContextFailed("渲染上下文为空")) }
        return .success(renderContext)
    }

    /// 挂载 GL 渲染上下文(由 MPVGLLayer 在拿到自己的 CGL context 后调用)。
    /// 非抛出:失败置 failed 并记日志(layer 的 override 里不能抛)。
    ///
    /// 可重复调用:CAOpenGLLayer 在切显示器 / 切 GPU / 换 pixel format 时会
    /// 重新走一次 copyCGLContext。render.h:117「there can be only 1
    /// mpv_render_context at a time per mpv core」——所以重挂之前必须先把
    /// 旧的 render context free 掉,否则第二次 create 必失败。
    /// 锁序 renderMutex → mutex(与 shutdown、render 一致)。
    func attachGLContext(_ cglContext: CGLContextObj?) {
        let created: Result<OpaquePointer, MPVError> = withRenderAndStateLock {
            guard let handle = state.handle, state.phase != .destroyed, state.phase != .tearingDown else {
                return .failure(.instanceDestroyed)
            }
            guard let framework = openGLFramework else {
                return .failure(.renderContextFailed("dlopen OpenGL.framework 失败"))
            }
            guard let cglContext else {
                return .failure(.renderContextFailed("CGL context 为空"))
            }
            // 同一个 context 重复挂接:layer 只是又问了一次,已挂好即可复用
            if let existing = state.renderContext, state.cglContext?.raw == cglContext {
                return .success(existing.raw)
            }
            // render.h 66-69:mpv_render* 调用要求该 GL context 在调用线程
            // current。copyCGLContext 钩子里 context 尚未 current,这里显式
            // 切换并在结束后恢复(CGLSetCurrentContext(nil) = 解绑,合法)。
            let previous = CGLGetCurrentContext()
            CGLSetCurrentContext(cglContext)
            defer { CGLSetCurrentContext(previous) }

            // 换了一个 context:先拆旧的(用旧 context current 去 free),
            // 再建新的。顺序不可换——render.h 只允许同时存在一个。
            if let stale = state.renderContext {
                CGLSetCurrentContext(state.cglContext?.raw)
                mpv_render_context_free(stale.raw)
                CGLSetCurrentContext(cglContext)
                state.renderContext = nil
            }
            if let staleCGL = state.cglContext {
                CGLReleaseContext(staleCGL.raw)
                state.cglContext = nil
            }

            // 后端按 targetBackend:`automatic` 起初是 legacy,片源是 DV 时
            // `handlePreloadedHook` 会在 VO 建立前换掉(layer 之后重挂也沿用换后的)。
            let renderContext: OpaquePointer
            switch buildRenderContext(handle: handle.raw, framework: framework, target: state.targetBackend) {
            case .success(let built):
                renderContext = built.context
                state.stats.renderBackend = built.backend.rawValue
            case .failure(let error):
                return .failure(error)
            }
            state.renderContext = LockedPointer(renderContext)
            // retain:layer 随时可能通过 releaseCGLContext: 还掉它自己那份
            // 引用(重建上下文、layer dealloc),而 shutdown 还要用它去
            // CGLSetCurrentContext。不 retain 就是 use-after-free。
            // 配对的 release 在 shutdown 与本方法的换 context 分支里。
            state.cglContext = LockedPointer(CGLRetainContext(cglContext))
            return .success(renderContext)
        }

        switch created {
        case .success:
            mutex.withLock { state.stats.glAttached = true }
        case .failure(.instanceDestroyed):
            // §8:destroyed 是终态。实例已销毁之后 layer 仍可能异步回调到
            // 这里,此时**不得**把 phase 改写成 failed——那会让终态复活成
            // 另一个态,观察者先收到 destroyed 事件又读到 failed。
            logLine("[MPV] attachGLContext 忽略: 实例已销毁")
        case .failure(let error):
            mutex.withLock {
                state.phase = .failed
                state.initializationFailure = "\(error)"
            }
            logLine("[MPV] attachGLContext 失败: \(error)")
        }
    }

    /// GL draw 线程调用:把当前帧渲染到 layer 当前绑定的 framebuffer。
    ///
    /// 官方模式(render.h 638-643、687-688;示例 sdl.c 的 on_redraw):
    /// update 回调通知后(`needsRender`,由 layer 的 `canDraw` 把关)调 update() 再**无条件** render()——
    /// render() 自己从内部队列拉帧,无新帧时重画上一帧;update() 在非 ADVANCED_CONTROL 下
    /// 是可选的,返回 flags 不能拿来 gate render()。S2 实测教训:按
    /// flags gate 后 flags 恒 0、一帧都渲不出。
    /// 标志在 render **之前**清:render 期间 VO 送来下一帧,回调会重新置位,不会漏。
    /// 锁:整帧只持有 `renderMutex`(仅与 attach / free 互斥),`mutex` 只在
    /// 取指针和回写统计这两个瞬间短暂持有。之前整帧持有 `mutex` 会让
    /// MainActor 侧的 `phase` / `pause()` / `seek()` 排队等一次 GPU 提交
    /// ——60fps 下每次调用都可能卡到主线程(§6.3「渲染路径内不得做重活」)。
    /// 指针在 renderMutex 内保持有效:free 也要拿同一把锁。
    func renderIntoBoundFramebuffer(width: Int, height: Int) {
        renderMutex.withLock {
            let renderContext: OpaquePointer? = mutex.withLock {
                state.stats.drawCalls += 1
                guard state.handle != nil else { return nil }
                return state.renderContext?.raw
            }
            guard let renderContext else { return }

            renderRequest.take()
            let flags = mpv_render_context_update(renderContext)
            // 这一帧是不是 VO 送来的真实视频帧(第一帧判据,见 `firstVideoFrameRendered`)。
            // ⛔ 不能只看 UPDATE_FRAME:VO 刚建好时的重绘请求同样带它,那一帧还没有画面
            // (vo_libmpv.c:`redraw || !current`),拿它当首帧会提前撤掉定格画面。
            let isFirstVideoFrame = flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
                && !mutex.withLock({ state.hasRenderedVideoFrame })
                && Self.nextFrameIsVideo(renderContext)
            // 不能写死 fbo=0:CAOpenGLLayer 调 draw 时绑定的是 layer 自己的
            // 离屏 FBO,不是默认 framebuffer。画到 0 等于画进空气 —— 解码、
            // 音频、时钟全都正常,画面却永远是黑的(S2 只数了渲染次数没目检,
            // 所以当时没发现)。与 mpv 自家 macOS 后端 cocoa-cb 的做法一致:
            // 每帧查询当前绑定的 draw framebuffer 传给 mpv。
            var boundFramebuffer: GLint = 0
            glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &boundFramebuffer)
            var fbo = mpv_opengl_fbo(
                fbo: Int32(boundFramebuffer), w: Int32(width), h: Int32(height),
                internal_format: 0)
            var flipY: Int32 = 1
            // draw 与弹幕 displayLink 共用主线程:即使 timing-offset 为 0,也不能在这里
            // 等 VO 的 present 通知。保留 video-timing-offset=0 避免提前交帧造成音画偏差,
            // 并显式关闭 render 的等待分支(render.h MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME)。
            var blockForTargetTime: Int32 = 0
            let err: Int32 = withUnsafeMutableBytes(of: &fbo) { fboPtr in
                withUnsafeMutableBytes(of: &flipY) { flipPtr in
                    withUnsafeMutableBytes(of: &blockForTargetTime) { blockPtr in
                        var params: [mpv_render_param] = [
                            mpv_render_param(
                                type: MPV_RENDER_PARAM_OPENGL_FBO,
                                data: fboPtr.baseAddress),
                            mpv_render_param(
                                type: MPV_RENDER_PARAM_FLIP_Y,
                                data: flipPtr.baseAddress),
                            mpv_render_param(
                                type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,
                                data: blockPtr.baseAddress),
                            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                        ]
                        return mpv_render_context_render(renderContext, &params)
                    }
                }
            }
            if err < 0 {
                logLine("[MPV] render 失败: \(mpvFailure(err, "mpv_render_context_render"))")
            }
            mutex.withLock {
                state.stats.lastUpdateFlags = flags
                if flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
                    state.stats.updateFrameFlags += 1
                }
                if err >= 0 { state.stats.renderedFrames += 1 }
                if err >= 0, isFirstVideoFrame { state.hasRenderedVideoFrame = true }
            }
            if err >= 0, isFirstVideoFrame { submitEvent(.firstVideoFrameRendered) }
        }
    }

    /// 待画的下一帧是不是一帧新视频(而不是重绘)。只在渲染线程、`renderMutex` 内调用。
    private static func nextFrameIsVideo(_ renderContext: OpaquePointer) -> Bool {
        var info = mpv_render_frame_info()
        let err: Int32 = withUnsafeMutableBytes(of: &info) { infoPtr in
            mpv_render_context_get_info(
                renderContext,
                mpv_render_param(type: MPV_RENDER_PARAM_NEXT_FRAME_INFO, data: infoPtr.baseAddress))
        }
        guard err >= 0 else { return false }
        let present = info.flags & UInt64(MPV_RENDER_FRAME_INFO_PRESENT.rawValue) != 0
        let redraw = info.flags & UInt64(MPV_RENDER_FRAME_INFO_REDRAW.rawValue) != 0
        return present && !redraw
    }

    /// 事件出口(调用方提供;需在 load 之前挂好)
    func attach(eventBridge: MPVEventBridge) {
        mutex.withLock { state.bridge = eventBridge }
    }

    /// 当前状态快照
    var phase: MPVPlayerPhase {
        mutex.withLock { state.phase }
    }

    /// 是否已进入拆卸(事件线程的退出条件,见 `MutableState.isStopping`)
    private var isStopping: Bool {
        mutex.withLock { state.isStopping }
    }

    /// init 失败原因(仅 .failed 时可能有值)
    var initializationFailure: String? {
        mutex.withLock { state.initializationFailure }
    }

    /// layer 这一 vsync 要不要画(`MPVGLLayer.canDraw`)。
    ///
    /// 没有活的渲染上下文(还没挂 GL / 已拆卸)时为假:layer 跳过这一帧,**保留上一次的画面**
    /// (CAOpenGLLayer 的契约,2026-10-14 用独立探针 + 截图实测,缩放窗口时也只是拉伸)。
    /// 换集 / 转码 seek / 重试时靠这一点把上一个播放器的最后一帧冻在屏上,直到新的出第一帧
    /// (`PlayerViewModel.lingeringPlayer`)。之前没有这道判断时,拆掉后照常走 draw,
    /// 空 render + flush 出来的是黑帧。
    var canRender: Bool {
        mutex.withLock { state.handle != nil && state.renderContext != nil && !state.isStopping }
    }

    /// layer 这一 vsync 要不要画:`canRender` 且自上次 draw 以来 mpv 送来过新帧 / 重绘请求,
    /// 或 layer 尺寸变了(`requestRender()`)。
    ///
    /// 不加这道门时 `CAOpenGLLayer` 按屏幕刷新率每次都 render(120 Hz 屏上 24 fps 片源约 5 次里 4 次
    /// 重画同一帧),而且 draw 跑在主线程(Q49)。暂停时一次都不画,layer 保留上一次的画面。
    var needsRender: Bool {
        renderRequest.isSet && canRender
    }

    /// 要求下一个 vsync 重画:mpv 不知道 layer 的尺寸变化(缩放窗口、全屏、换屏),
    /// 新尺寸只在下一次 render 时传进去(`renderIntoBoundFramebuffer`)。任意线程可调。
    func requestRender() {
        renderRequest.set()
    }

    /// 画出过真实视频帧(拆卸后仍可读)。为假时 layer 上没有值得定格的画面。
    var hasRenderedVideoFrame: Bool {
        mutex.withLock { state.hasRenderedVideoFrame }
    }

    /// 统计快照(诊断用;目前 App 内没有调用方,排查渲染问题时临时读它)
    func statisticsSnapshot() -> MPVPlayerStatistics {
        mutex.withLock { state.stats }
    }

    // MARK: - 事件线程

    /// 单轮事件处理后,事件线程该继续还是收摊
    private enum EventLoopDirective {
        case `continue`
        case stop
    }

    /// 事件线程主体。`static` 是刻意的:只能通过 `owner()` 逐轮取强引用,
    /// 绝不能在阻塞于 `mpv_wait_event` 期间持有 self(论证见 init)。
    private static func runEventLoop(
        handle: LockedPointer<OpaquePointer>,
        owner: @escaping @Sendable () -> MPVPlayer?,
        done: DispatchSemaphore
    ) {
        // 无论从哪条路径退出都要放行 shutdown 的等待——包括拥有者已被
        // 释放、owner() 返回 nil 的那条路径,所以信号量是值捕获的。
        defer {
            owner()?.failPropertyRequests(MPVError.instanceDestroyed, eventLoopEnded: true)
            done.signal()
        }
        while true {
            guard let event = mpv_wait_event(handle.raw, -1) else { break }
            // 强引用的作用域严格限制在本轮迭代内
            guard let player = owner() else { break }
            if player.process(event.pointee) == .stop { break }
            if player.isStopping { break }
        }
    }

    private func process(_ event: mpv_event) -> EventLoopDirective {
        switch event.event_id {
        case MPV_EVENT_SHUTDOWN:
            // client.h:1247-1252:核心已自行退出(quit 命令 / 内部致命错误),
            // 「the client should react to this and quit ... as soon as
            // possible」。§6.2 要求「不得直接强拆」——所以这里不调
            // mpv_terminate_destroy(有序销毁仍归 shutdown()),但必须让
            // 上层知道:否则 phase 永远停在 playing、不发任何事件,
            // UI 显示「正在播放」而画面永久冻结。
            logLine("[MPV] 核心已退出(MPV_EVENT_SHUTDOWN),事件循环收摊")
            failPropertyRequests(MPVError.instanceDestroyed, eventLoopEnded: true)
            setPhase(.failed)
            submitEvent(.endFile(.error("mpv 核心已退出(MPV_EVENT_SHUTDOWN)")))
            // 核心已死,继续 wait_event 只会永久阻塞,没有意义
            return .stop

        case MPV_EVENT_START_FILE:
            setPhase(.loading)

        case MPV_EVENT_FILE_LOADED:
            // §6.2:文件就绪(首帧前),进入 playing
            setPhase(.playing)

        case MPV_EVENT_END_FILE:
            if let data = event.data {
                let endFile = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                switch endFile.reason {
                case MPV_END_FILE_REASON_EOF:
                    // ⛔ 不要在这里 setPhase(.idle):§8 的状态机没有「回到
                    // idle」这条边,而 idle 恰恰是 load() 的准入条件——回退
                    // 到 idle 等于把「一实例一 URL」的门打开了(复用时会沿用
                    // 上一轮的 headers / renderContext)。播完由 endFile(.eof)
                    // 通知上层,实例本身保持不可复用。§8 缺一个「已结束」态,
                    // 已登记 docs/PITFALLS.md Q7。
                    submitEvent(.endFile(.eof))
                case MPV_END_FILE_REASON_STOP:
                    submitEvent(.endFile(.stop))
                case MPV_END_FILE_REASON_ERROR:
                    let message = String(cString: mpv_error_string(endFile.error))
                    setPhase(.failed)
                    submitEvent(.endFile(.error(message)))
                case MPV_END_FILE_REASON_QUIT, MPV_END_FILE_REASON_REDIRECT:
                    // §6.2:QUIT / REDIRECT 记日志即可
                    logLine("[MPV] END_FILE reason=\(endFile.reason.rawValue)(quit/redirect),仅记录")
                default:
                    logLine("[MPV] END_FILE 未知 reason=\(endFile.reason.rawValue)")
                }
            }

        case MPV_EVENT_LOG_MESSAGE:
            if let data = event.data {
                let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                let prefix = message.prefix.map { String(cString: $0) } ?? "?"
                let text = message.text.map { String(cString: $0) } ?? ""
                appendRecentLog("[\(prefix)] \(text)")
            }

        case MPV_EVENT_SEEK:
            submitEvent(.seeking(true))

        case MPV_EVENT_PLAYBACK_RESTART:
            submitEvent(.seeking(false))

        case MPV_EVENT_GET_PROPERTY_REPLY:
            processPropertyReply(event)

        case MPV_EVENT_QUEUE_OVERFLOW:
            // 丢掉的 GET_REPLY 不会重发,必须放行所有等待者而不能挂住监控 worker。
            logLine("[MPV] 事件队列溢出,终止本轮属性读取")
            failPropertyRequests(mpvFailure(MPV_ERROR_EVENT_QUEUE_FULL.rawValue, "属性回复队列溢出"))

        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return .continue }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            processPropertyChange(property)

        case MPV_EVENT_HOOK:
            guard let data = event.data else { return .continue }
            let hook = data.assumingMemoryBound(to: mpv_event_hook.self).pointee
            handlePreloadedHook(id: hook.id, name: hook.name.map { String(cString: $0) })

        default:
            break // §6.2:未知/已废弃事件(TICK 等)忽略,不打日志
        }
        return .continue
    }

    // MARK: - 按片源选渲染后端(automatic 策略)

    /// `on_preloaded`:读轨道 → 按策略定后端 → 需要时换渲染上下文 → 放行播放核心。
    ///
    /// 只有 `automatic` 注册了这个 hook。此刻 VO 还没建(loadfile.c:选轨与
    /// `reinit_video_chain` 都在 hook 之后),换渲染上下文不影响任何已出的画面,
    /// 也不需要重开流 —— 不多发请求、不多一轮播放上报。
    private func handlePreloadedHook(id: UInt64, name: String?) {
        guard let handle = mutex.withLock({ state.handle }) else { return }
        // ⛔ 任何路径都必须 continue:不放行,播放核心就永远停在 hook 里(黑屏无声、无报错)。
        defer { mpv_hook_continue(handle.raw, id) }
        guard name == Self.preloadedHook else { return }

        var node = mpv_node()
        let err = mpv_get_property(handle.raw, "track-list", MPV_FORMAT_NODE, &node)
        guard err >= 0 else {
            // 读不到就不切:保持 legacy,DV 片源会发紫发绿,但能播。留痕,不静默。
            logLine("[MPV] on_preloaded 读 track-list 失败,保持当前渲染器: "
                + String(cString: mpv_error_string(err)))
            return
        }
        let tracks = MPVTrackListParser.parse(&node)
        // 与事件里的节点不同:mpv_get_property 拿到的节点归调用方,必须自己释放(client.h)
        mpv_free_node_contents(&node)

        let target = backendPolicy.backend(for: tracks)
        if target == .gpuNext {
            let profiles = tracks
                .compactMap { $0.dolbyVisionProfile }
                .map(String.init).joined(separator: ",")
            logLine("[MPV] 片源含 Dolby Vision(profile \(profiles)),渲染后端切到 gpu-next")
        }
        switchRenderBackend(to: target)
    }

    /// 把渲染上下文换成目标后端(还没挂 GL 时只记下目标,挂上时按它建)。
    ///
    /// 锁序 CGL context 锁 → `renderMutex` → `mutex`:CAOpenGLLayer 在 draw 线程
    /// 持有 context 时进 `renderIntoBoundFramebuffer`,这里在事件线程借用同一个
    /// context,先锁它才不会与 draw 交叉使用、也不会与之反序死锁。
    private func switchRenderBackend(to target: MPVRenderBackend) {
        let attached: LockedPointer<CGLContextObj>? = mutex.withLock {
            state.targetBackend = target
            guard state.renderContext != nil, state.stats.renderBackend != target.rawValue,
                  let cgl = state.cglContext else { return nil }
            // 换下来之前 layer 或 shutdown 可能还掉 state 里那份引用,这里自己再持一份
            return LockedPointer(CGLRetainContext(cgl.raw))
        }
        guard let attached else { return }
        defer { CGLReleaseContext(attached.raw) }
        CGLLockContext(attached.raw)
        defer { CGLUnlockContext(attached.raw) }

        let result: Result<MPVRenderBackend, MPVError>? = withRenderAndStateLock {
            // 拿锁期间 layer 可能已经重挂了别的 context(它会按 targetBackend 建),或已在拆卸
            guard let handle = state.handle, !state.isStopping,
                  state.cglContext?.raw == attached.raw,
                  let stale = state.renderContext,
                  state.stats.renderBackend != target.rawValue,
                  let framework = openGLFramework else { return nil }
            let previous = CGLGetCurrentContext()
            CGLSetCurrentContext(attached.raw)
            defer { CGLSetCurrentContext(previous) }
            // render.h 只允许同时存在一个渲染上下文:先 free 再建
            mpv_render_context_free(stale.raw)
            state.renderContext = nil
            switch buildRenderContext(handle: handle.raw, framework: framework, target: target) {
            case .success(let built):
                state.renderContext = LockedPointer(built.context)
                state.stats.renderBackend = built.backend.rawValue
                return .success(built.backend)
            case .failure(let error):
                state.stats.renderBackend = nil
                return .failure(error)
            }
        }
        if case .failure(let error) = result {
            // 连 legacy 都建不回来:VO 马上会因为没有渲染上下文而失败,明确报错而不是只出声音
            logLine("[MPV] 切换渲染后端失败: \(error)")
            mutex.withLock { state.initializationFailure = "\(error)" }
            setPhase(.failed)
            submitEvent(.endFile(.error("渲染后端切换失败:\(error)")))
        }
    }

    /// 读取 `MPV_FORMAT_FLAG` 的值。
    ///
    /// client.h 对 FLAG 的定义是「The basic type is int」——4 字节。
    /// ⛔ 不得写成 `assumingMemoryBound(to: Bool.self)`:那是拿 1 字节的
    /// Swift Bool 去解释 4 字节的 C int,只在小端上碰巧成立,且从非 0/1
    /// 字节构造 Bool 在 Swift 里属未定义行为。与写入侧 `setFlagProperty`
    /// 用 Int32 的写法保持一致。
    private static func flagValue(_ data: UnsafeMutableRawPointer) -> Bool {
        data.assumingMemoryBound(to: Int32.self).pointee != 0
    }

    private func processPropertyChange(_ property: mpv_event_property) {
        let name = String(cString: property.name)
        switch (name, property.format) {
        case ("time-pos", MPV_FORMAT_DOUBLE):
            guard let data = property.data else { return }
            let value = data.assumingMemoryBound(to: Double.self).pointee
            let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
            mutex.withLock {
                state.stats.timePosEvents += 1
                state.stats.timePosFirstAt = state.stats.timePosFirstAt ?? now
                state.stats.timePosLastAt = now
            }
            submitEvent(.timePos(value))

        case ("duration", MPV_FORMAT_DOUBLE):
            guard let data = property.data else { return }
            submitEvent(.duration(data.assumingMemoryBound(to: Double.self).pointee))

        case ("pause", MPV_FORMAT_FLAG):
            guard let data = property.data else { return }
            let paused = Self.flagValue(data)
            if paused {
                setPhase(.paused, from: [.playing])
            } else {
                setPhase(.playing, from: [.paused])
            }
            submitEvent(.paused(paused))

        case ("eof-reached", MPV_FORMAT_FLAG):
            guard let data = property.data else { return }
            submitEvent(.eofReached(Self.flagValue(data)))

        case ("seeking", MPV_FORMAT_FLAG):
            guard let data = property.data else { return }
            submitEvent(.seeking(Self.flagValue(data)))

        case ("paused-for-cache", MPV_FORMAT_FLAG):
            guard let data = property.data else { return }
            submitEvent(.buffering(Self.flagValue(data)))

        case ("volume", MPV_FORMAT_DOUBLE):
            guard let data = property.data else { return }
            submitEvent(.volume(data.assumingMemoryBound(to: Double.self).pointee))

        case ("speed", MPV_FORMAT_DOUBLE):
            guard let data = property.data else { return }
            submitEvent(.speed(data.assumingMemoryBound(to: Double.self).pointee))

        case ("sub-delay", MPV_FORMAT_DOUBLE):
            guard let data = property.data else { return }
            submitEvent(.subtitleDelay(data.assumingMemoryBound(to: Double.self).pointee))

        case ("hwdec-current", MPV_FORMAT_STRING):
            guard let data = property.data else { return }
            let value = String(cString: data.assumingMemoryBound(
                to: UnsafePointer<CChar>.self).pointee)
            mutex.withLock { state.stats.hwdecCurrent = value }
            submitEvent(.hwdecChanged(value))

        case ("mute", MPV_FORMAT_FLAG):
            guard let data = property.data else { return }
            submitEvent(.muted(Self.flagValue(data)))

        case ("track-list", MPV_FORMAT_NODE):
            guard let data = property.data else { return }
            // ⛔ 不能在这里 `mpv_free_node_contents`:事件里的节点**归 mpv 所有**,
            // client.h:1712-1714 明确「all memory referenced by it will be
            // automatically released by the API on the next mpv_wait_event()」。
            // 早前版本多调了一次 free,结果在 mpv 自己的 copy_node/free_node 里
            // 触发 talloc 断言(SIGABRT),测试宿主直接崩在启动阶段。
            var node = data.assumingMemoryBound(to: mpv_node.self).pointee
            // 解析必须**同步**完成:节点在下一次 mpv_wait_event 之后即失效。
            submitEvent(.trackList(MPVTrackListParser.parse(&node)))

        default:
            break
        }
    }

    // MARK: - 私有工具

    /// 在锁内执行 mpv 调用:阻止销毁期间的悬垂句柄竞争
    /// (mpv API 本身线程安全,锁只为序列化 handle 的生命周期)。
    /// Mutex 非重入:body 内不得再调 `mutex.withLock`(否则死锁),
    /// 需要读写状态直接用 state。
    private func withLiveHandle<R>(
        _ body: (OpaquePointer, inout MutableState) throws -> R
    ) throws -> R {
        try mutex.withLock {
            guard let handle = state.handle else {
                throw MPVError.instanceDestroyed
            }
            switch state.phase {
            case .destroyed, .tearingDown:
                throw MPVError.instanceDestroyed
            case .failed:
                throw MPVError.commandFailed(
                    code: MPV_ERROR_GENERIC.rawValue,
                    message: state.initializationFailure ?? "初始化失败")
            default:
                return try body(handle.raw, &state)
            }
        }
    }

    private func setFlagProperty(_ name: String, _ value: Bool) throws {
        try withLiveHandle { handle, _ in
            var flag: Int32 = value ? 1 : 0
            let err = mpv_set_property(handle, name, MPV_FORMAT_FLAG, &flag)
            guard err >= 0 else { throw mpvFailure(err, "设置 \(name)") }
        }
    }

    /// `aid` / `sid` 这类接受数字或 `no` 的字符串属性。
    /// ⛔ 不要改成 MPV_FORMAT_INT64:关字幕的唯一写法是 `sid=no`
    /// (MPV_INTEGRATION.md 第 7 节),整数格式表达不了。
    private func setStringProperty(_ name: String, _ value: String) throws {
        try withLiveHandle { handle, _ in
            let err = mpv_set_property_string(handle, name, value)
            guard err >= 0 else { throw mpvFailure(err, "设置 \(name)") }
        }
    }

    private func mpvCommand(_ args: [String], on handle: OpaquePointer) throws {
        // strdup 分配的内存所有权归本函数,mpv_command 调用完释放
        let owned: [UnsafeMutablePointer<CChar>] = try args.map { arg in
            guard let p = strdup(arg) else {
                throw MPVError.commandFailed(
                    code: MPV_ERROR_GENERIC.rawValue,
                    message: "strdup 内存分配失败")
            }
            return p
        }
        defer { owned.forEach { free($0) } }
        var cArgs: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
        cArgs.append(nil) // NULL 终止(client.h:904)
        let err = mpv_command(handle, &cArgs)
        guard err >= 0 else { throw mpvFailure(err, "mpv_command(\(args.first ?? ""))") }
    }

    /// §5.1 路径 A:`MPV_FORMAT_NODE` 数组,每个 header 一个 STRING 节点。
    /// 结构化传值,值内的逗号/引号无需任何转义。
    private func setHTTPHeaderFields(_ headers: [String: String], on handle: OpaquePointer) throws {
        let entries = headers
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }

        // 先把所有 C 字符串分配成功,再填节点——避免中途失败时
        // defer 读到未初始化的节点内存
        let cStrings: [UnsafeMutablePointer<CChar>] = try entries.map { entry in
            guard let p = strdup(entry) else {
                throw MPVError.commandFailed(
                    code: MPV_ERROR_GENERIC.rawValue,
                    message: "strdup 内存分配失败")
            }
            return p
        }

        let count = entries.count
        let nodes = UnsafeMutablePointer<mpv_node>.allocate(capacity: max(count, 1))
        let list = UnsafeMutablePointer<mpv_node_list>.allocate(capacity: 1)
        defer {
            cStrings.forEach { free($0) }
            nodes.deallocate()
            list.deallocate()
        }

        for (i, cString) in cStrings.enumerated() {
            nodes[i] = mpv_node()
            nodes[i].format = MPV_FORMAT_STRING
            nodes[i].u.string = cString
        }
        list.pointee.num = Int32(count)
        list.pointee.values = nodes
        list.pointee.keys = nil

        var root = mpv_node()
        root.format = MPV_FORMAT_NODE_ARRAY
        root.u.list = list

        let err = mpv_set_property(handle, "http-header-fields", MPV_FORMAT_NODE, &root)
        guard err >= 0 else {
            throw mpvFailure(err, "设置 http-header-fields(NODE 数组)")
        }
    }

    /// 最近的 mpv 日志快照(旧 → 新;已脱敏)。播放失败时读它写诊断日志。
    func recentLogLines() -> [String] {
        mutex.withLock { state.recentLogs }
    }

    /// 日志时间戳的起点(实例创建时刻);每条日志前缀 `+{秒}`,起播慢时用来看时间花在哪
    private let logOrigin = ContinuousClock.now

    private func appendRecentLog(_ raw: String) {
        let elapsed = ContinuousClock.now - logOrigin
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        // 播放 URL 可能带 api_key:先脱敏再入缓冲,缓冲里永远不放原文
        var line = String(format: "+%.2f ", seconds)
            + SecretRedactor.redacted(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        if line.count > Self.recentLogLineLimit {
            line = String(line.prefix(Self.recentLogLineLimit)) + "…"
        }
        mutex.withLock {
            state.recentLogs.append(line)
            if state.recentLogs.count > Self.recentLogLimit {
                state.recentLogs.removeFirst(state.recentLogs.count - Self.recentLogLimit)
            }
        }
    }

    private func setPhase(_ newPhase: MPVPlayerPhase, from allowed: [MPVPlayerPhase]? = nil) {
        let changed: Bool = mutex.withLock {
            if let allowed, !allowed.contains(state.phase) { return false }
            guard state.phase != newPhase else { return false }
            state.phase = newPhase
            return true
        }
        if changed {
            submitEvent(.phaseChanged(newPhase))
        }
    }

    private func submitEvent(_ event: MPVPlayerEvent) {
        mutex.withLock { state.bridge }?.submit(event)
    }

    private func logLine(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
