import SwiftUI

/// 服务器管理列表:增 / 改 / 删 / 切换 / 登录。
/// 点击行切换当前服务器;行尾按钮与右键菜单提供编辑、删除、登录。
struct ServerListView: View {
    let container: AppContainer

    @State private var servers: [ServerProfile] = []
    @State private var loggedInIDs: Set<UUID> = []
    @State private var showsAddSheet = false
    @State private var editingServer: ServerProfile?
    @State private var serverPendingDeletion: ServerProfile?
    @State private var serverToLogin: ServerProfile?
    @State private var actionErrorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if servers.isEmpty {
                    ContentUnavailableView(
                        "没有服务器",
                        systemImage: "server.rack",
                        description: Text("添加一台 Emby 服务器开始使用。")
                    )
                } else {
                    serverList
                }
            }
            .navigationTitle("服务器")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await openLibrary() }
                    } label: {
                        Label("打开媒体库", systemImage: "rectangle.grid.2x2")
                    }
                    .disabled(servers.isEmpty)
                    .help("浏览当前服务器的媒体库")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsAddSheet = true
                    } label: {
                        Label("添加服务器", systemImage: "plus")
                    }
                }
            }
            .task {
                await reload()
                // 启动时发现当前服务器没有 token → 直接弹登录
                // (ARCHITECTURE.md 7.3:返回登录界面,保留地址与用户名)
                if let needing = container.state.serverNeedingLogin {
                    serverToLogin = needing
                }
            }
            .sheet(isPresented: $showsAddSheet, onDismiss: {
                Task { await reload() }
            }) {
                AddServerView(container: container, showsCancelButton: true)
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
                "删除服务器",
                isPresented: Binding(
                    get: { serverPendingDeletion != nil },
                    set: { if !$0 { serverPendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: serverPendingDeletion
            ) { server in
                Button("删除", role: .destructive) {
                    Task { await remove(server) }
                }
                Button("取消", role: .cancel) {}
            } message: { server in
                Text("将删除「\(server.displayName)」及其保存在本地的访问令牌,该操作不可撤销。")
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
    }

    private var serverList: some View {
        List {
            Section {
                ForEach(servers) { server in
                    ServerRow(
                        server: server,
                        isCurrent: container.state.currentServer?.id == server.id,
                        isLoggedIn: loggedInIDs.contains(server.id),
                        onSelect: { Task { await select(server) } },
                        onOpenLibrary: { Task { await openLibrary(server) } },
                        onLogin: { serverToLogin = server },
                        onEdit: { editingServer = server },
                        onDelete: { serverPendingDeletion = server }
                    )
                }
            } footer: {
                Text("单击切换当前服务器,双击打开媒体库。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
    }

    // MARK: - 动作

    private func reload() async {
        servers = await container.registry.all()
        do {
            var ids: Set<UUID> = []
            for server in servers {
                if try await container.canResumeSession(for: server) {
                    ids.insert(server.id)
                }
            }
            loggedInIDs = ids
        } catch {
            // 读不到登录状态就如实报错,不假装「都没登录」
            actionErrorMessage = "读取登录状态失败:\(error.localizedDescription)"
        }
    }

    private func select(_ server: ServerProfile) async {
        guard container.state.currentServer?.id != server.id else { return }
        do {
            try await container.switchCurrent(to: server)
            // 切换改了库内 lastUsedAt,同步刷新本地快照,
            // 避免把过期副本带进编辑表单
            await reload()
        } catch {
            actionErrorMessage = "切换服务器失败,请重试。"
        }
    }

    /// 双击 / 菜单「打开媒体库」:先切到这台再进入。
    private func openLibrary(_ server: ServerProfile) async {
        await select(server)
        guard container.state.currentServer?.id == server.id else { return }
        container.state.route = .browse
    }

    /// 进入媒体库:没有当前服务器时先切到最近使用的一台。
    private func openLibrary() async {
        do {
            if container.state.currentServer == nil,
               let recent = await container.registry.mostRecentlyUsed() {
                try await container.switchCurrent(to: recent)
            }
            guard container.state.currentServer != nil else {
                actionErrorMessage = "请先选中一台服务器。"
                return
            }
            container.state.route = .browse
        } catch {
            actionErrorMessage = "切换服务器失败,请重试。"
        }
    }

    private func remove(_ server: ServerProfile) async {
        do {
            try await container.removeServer(id: server.id)
            await reload()
        } catch {
            actionErrorMessage = "删除服务器失败,请重试。"
        }
    }
}

/// 服务器列表的一行:图标 + 名称 / 地址 / 账户 / 版本 + 登录状态 + 更多操作。
private struct ServerRow: View {
    let server: ServerProfile
    let isCurrent: Bool
    let isLoggedIn: Bool
    let onSelect: () -> Void
    let onOpenLibrary: () -> Void
    let onLogin: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Metrics.spacingM) {
            icon
            VStack(alignment: .leading, spacing: Metrics.spacingXS) {
                HStack(spacing: Metrics.spacingS) {
                    Text(server.displayName)
                        .font(.headline)
                        .lineLimit(1)
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
        .onTapGesture(count: 2, perform: onOpenLibrary)
        .onTapGesture(perform: onSelect)
        .contextMenu { menuItems }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    private var icon: some View {
        Image(systemName: "server.rack")
            .font(.title3)
            .foregroundStyle(isCurrent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .frame(width: Metrics.serverRowIconSize, height: Metrics.serverRowIconSize)
            .background(
                isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: Radius.card)
            )
    }

    /// 地址 · 用户名 · 版本。字段缺失就不显示,不填占位(API_CONTRACT.md 8.1 同一立场)。
    private var detailLine: some View {
        HStack(spacing: Metrics.spacingXS) {
            if server.baseURL.scheme == "http" {
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
        var parts = [hostText]
        if let username = server.username { parts.append(username) }
        if let version = server.serverVersion { parts.append("Emby \(version)") }
        return parts.joined(separator: " · ")
    }

    private var hostText: String {
        guard let host = server.baseURL.host() else { return server.baseURL.absoluteString }
        if let port = server.baseURL.port { return "\(host):\(port)" }
        return host
    }

    @ViewBuilder
    private var status: some View {
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
        Button("打开媒体库", systemImage: "rectangle.grid.2x2", action: onOpenLibrary)
        if !isLoggedIn {
            Button("登录…", systemImage: "person.crop.circle", action: onLogin)
        }
        Button("编辑…", systemImage: "pencil", action: onEdit)
        Divider()
        Button("删除…", systemImage: "trash", role: .destructive, action: onDelete)
    }
}
