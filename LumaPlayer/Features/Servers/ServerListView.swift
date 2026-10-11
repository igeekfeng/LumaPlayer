import SwiftUI

/// 播放来源管理:增 / 改 / 删 / 切换 / 登录。
/// 点击行切换当前来源;行尾按钮与右键菜单提供编辑、删除、登录。
///
/// 「来源」是 Emby 与百度网盘**平等共存**的一层(`docs/SOURCE_ABSTRACTION_PLAN.md` §0):
/// 同一个列表装两种来源,可切换、可删除、可标记最近使用。
///
/// 作为设置窗口「来源」标签页的内容(`AppSettingsView`):这里不再自带
/// `NavigationStack` 与工具栏 —— 设置窗口的标签页就是它的外壳。
struct ServerListView: View {
    let container: AppContainer

    @State private var sources: [SourceProfile] = []
    /// 已能免输入进入的 Emby 服务器(百度来源的授权状态由它自己那一页判断)
    @State private var loggedInServerIDs: Set<UUID> = []
    @State private var showsAddSheet = false
    @State private var editingServer: ServerProfile?
    @State private var sourcePendingDeletion: SourceProfile?
    @State private var serverToLogin: ServerProfile?
    @State private var actionErrorMessage: String?

    var body: some View {
        Group {
            if sources.isEmpty {
                ContentUnavailableView {
                    Label("没有播放来源", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("添加一个 Emby 服务器或百度网盘开始使用。")
                } actions: {
                    Button("添加来源…") { showsAddSheet = true }
                }
            } else {
                sourceList
            }
        }
        .task {
            await reload()
        }
        .sheet(isPresented: $showsAddSheet, onDismiss: {
            Task { await reload() }
        }) {
            AddSourceView(container: container, showsCancelButton: true)
        }
        .sheet(item: $editingServer, onDismiss: {
            Task { await reload() }
        }) { server in
            ServerSettingsView(container: container, server: server)
        }
        .sheet(item: $serverToLogin, onDismiss: {
            Task { await reload() }
        }) { server in
            LoginView(container: container, server: server)
        }
        .confirmationDialog(
            "删除来源",
            isPresented: Binding(
                get: { sourcePendingDeletion != nil },
                set: { if !$0 { sourcePendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: sourcePendingDeletion
        ) { source in
            Button("删除", role: .destructive) {
                Task { await remove(source) }
            }
            Button("取消", role: .cancel) {}
        } message: { source in
            Text(deleteMessage(for: source))
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { actionErrorMessage != nil },
                set: { if !$0 { actionErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionErrorMessage ?? "")
        }
    }

    private var sourceList: some View {
        List {
            Section {
                ForEach(sources) { source in
                    SourceRow(
                        source: source,
                        isCurrent: container.state.currentSource?.id == source.id,
                        isLoggedIn: loggedInServerIDs.contains(source.id),
                        onSelect: { Task { await select(source) } },
                        onLogin: { if case .emby(let server) = source { serverToLogin = server } },
                        onEdit: { if case .emby(let server) = source { editingServer = server } },
                        onDelete: { sourcePendingDeletion = source }
                    )
                }
            } footer: {
                Text("单击切换当前来源,主窗口会跟着切到它。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button {
                    showsAddSheet = true
                } label: {
                    Label("添加来源…", systemImage: "plus")
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.inset)
    }

    // MARK: - 动作

    private func reload() async {
        sources = await container.sources()
        do {
            var ids: Set<UUID> = []
            for server in sources.compactMap(\.embyServer) {
                if try await container.canResumeSession(for: server) {
                    ids.insert(server.id)
                }
            }
            loggedInServerIDs = ids
        } catch {
            // 读不到登录状态就如实报错,不假装「都没登录」
            actionErrorMessage = "读取登录状态失败:\(error.localizedDescription)"
        }
    }

    private func select(_ source: SourceProfile) async {
        guard container.state.currentSource?.id != source.id else { return }
        do {
            try await container.switchCurrent(to: source)
            // 切换改了库内 lastUsedAt,同步刷新本地快照,
            // 避免把过期副本带进编辑表单
            await reload()
        } catch {
            actionErrorMessage = "切换来源失败,请重试。"
        }
    }

    private func remove(_ source: SourceProfile) async {
        do {
            try await container.removeSource(id: source.id)
            await reload()
        } catch {
            actionErrorMessage = "删除来源失败,请重试。"
        }
    }

    private func deleteMessage(for source: SourceProfile) -> String {
        switch source {
        case .emby(let server):
            return "将删除「\(server.displayName)」及其保存在本地的访问令牌,该操作不可撤销。"
        case .baiduPan:
            return "将删除「\(source.displayName)」及其保存在本地的授权与密钥,该操作不可撤销。"
        }
    }
}

/// 来源列表的一行:图标 + 名称 + 类型相关明细 + 登录状态 + 更多操作。
private struct SourceRow: View {
    let source: SourceProfile
    let isCurrent: Bool
    let isLoggedIn: Bool
    let onSelect: () -> Void
    let onLogin: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Metrics.spacingM) {
            icon
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                HStack(spacing: Metrics.spacingS) {
                    Text(source.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(source.kindDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Metrics.spacingS)
                        .padding(.vertical, Metrics.spacingXXS)
                        .background(.quaternary, in: Capsule())
                    if isCurrent {
                        Text("当前")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, Metrics.spacingS)
                            .padding(.vertical, Metrics.spacingXXS)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                detailLine
            }
            Spacer(minLength: Metrics.spacingM)
            status
            moreMenu
        }
        .padding(.vertical, Metrics.spacingS)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu { menuItems }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    private var icon: some View {
        Image(systemName: symbolName)
            .font(.title3)
            .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: Metrics.serverRowIconSize, height: Metrics.serverRowIconSize)
            .background(
                isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: Radius.card)
            )
    }

    private var symbolName: String {
        switch source {
        case .emby: return "server.rack"
        case .baiduPan: return "cloud.fill"
        }
    }

    /// 明细行。字段缺失就不显示,不填占位(API_CONTRACT.md 8.1 同一立场)。
    private var detailLine: some View {
        HStack(spacing: Metrics.spacingXS) {
            if case .emby(let server) = source, server.baseURL.scheme == "http" {
                Image(systemName: "lock.open.fill")
                    .foregroundStyle(.orange)
                    .help("未加密连接(HTTP)")
            }
            Text(detailText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var detailText: String {
        switch source {
        case .emby(let server):
            var parts = [hostText(for: server)]
            if let username = server.username { parts.append(username) }
            if let version = server.serverVersion { parts.append("Emby \(version)") }
            return parts.joined(separator: " · ")
        case .baiduPan(let baidu):
            // 应用目录名是这一行唯一有信息量的字段:它决定了能访问网盘里的什么
            return "/apps/\(baidu.folderName)"
        }
    }

    private func hostText(for server: ServerProfile) -> String {
        guard let host = server.baseURL.host() else { return server.baseURL.absoluteString }
        if let port = server.baseURL.port { return "\(host):\(port)" }
        return host
    }

    /// 登录状态只有 Emby 有;百度来源不给「登录」入口(它的授权在来源页里)。
    @ViewBuilder
    private var status: some View {
        if case .emby = source {
            if isLoggedIn {
                HStack(spacing: Metrics.spacingXS) {
                    Image(systemName: "circle.fill")
                        .imageScale(.small)
                        .foregroundStyle(.green)
                    Text("已登录")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            } else {
                Button("登录", action: onLogin)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        } else {
            Text("已连接")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var moreMenu: some View {
        Menu {
            menuItems
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作")
    }

    @ViewBuilder
    private var menuItems: some View {
        // 编辑 / 登录只对 Emby 开放:百度来源的配置在它自己那一页里改
        if case .emby = source {
            if !isLoggedIn {
                Button("登录…", systemImage: "person.crop.circle", action: onLogin)
            }
            Button("编辑…", systemImage: "pencil", action: onEdit)
            Divider()
        }
        Button("删除…", systemImage: "trash", role: .destructive, action: onDelete)
    }
}
