import Foundation

/// 一个来源能提供的**内容**能力(列库 / 列条目)。
///
/// ## 为什么播放不走这里
///
/// 取播放会话那条路走 `PlaybackSessionPreparing`:它要按来源装配,
/// 并随 `PlaybackRequest` 一起进播放页,生命周期与「浏览」不同。
/// 硬塞进同一个协议会让「谁在什么时候被调」变得说不清。
///
/// ## 为什么是 `Actor` 而不是值类型
///
/// 实现要复用 `ServerConnection` / `BaiduPanConnection` 的状态
/// (token 不共享,`CLAUDE.md`「架构主线」),那两个都是 actor。
protocol SourceProvider: Actor {
    /// 来源身份(路由与图片缓存 key 用)
    nonisolated var sourceID: UUID { get }
    /// 库入口
    func libraries() async throws -> [SourceLibrary]
    /// 列一个库 / 目录下的条目
    func items(in library: SourceLibraryRef) async throws -> [SourceItem]
}
