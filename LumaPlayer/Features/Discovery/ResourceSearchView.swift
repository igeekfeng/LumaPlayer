import SwiftUI

/// 「找资源」页:关键词 → 多个网盘搜索源 → 归一化结果 → 转存进网盘。
///
/// 与主窗口的搜索框分工:那个搜的是**当前来源里已有的内容**;这一页搜的是**网盘上别人分享的资源**,
/// 搜到之后再转存。所以它有自己的输入框(不占用 `⌘F`),也不进 `NavigationStack` 的搜索路由。
struct ResourceSearchView: View {
    let container: AppContainer
    /// 从「看什么」点进来时带的关键词:进页面就搜一次
    let initialKeyword: String?
    var onOpenSettings: () -> Void

    @State private var viewModel: ResourceSearchViewModel
    @State private var keyword: String
    /// 待转存的链接(弹 sheet 选目标网盘)
    @State private var pendingTransfer: PanResourceLink?
    @State private var toast: String?

    @MainActor
    init(
        container: AppContainer,
        initialKeyword: String? = nil,
        onOpenSettings: @escaping () -> Void
    ) {
        self.container = container
        self.initialKeyword = initialKeyword
        self.onOpenSettings = onOpenSettings
        self._viewModel = State(initialValue: ResourceSearchViewModel(container: container))
        self._keyword = State(initialValue: initialKeyword ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "找资源")
            searchBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("找资源")
        .task {
            await viewModel.loadSources()
            // 带着关键词进来(从「看什么」点卡片):源还没加载完就别搜,等这一轮读完再提交
            if let initialKeyword, !initialKeyword.isEmpty, viewModel.submittedKeyword.isEmpty {
                viewModel.search(initialKeyword)
            }
        }
        .sheet(item: $pendingTransfer) { link in
            PanTransferSheet(
                container: container,
                link: link,
                onDone: { message in toast = message })
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.callout)
                    .padding(Metrics.spacingM)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, Metrics.spacingXL)
                    .transition(.opacity)
                    .task(id: toast) {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { self.toast = nil }
                    }
            }
        }
        .reportsPageLoading(viewModel.isLoading, page: .resourceSearch, to: container.state)
    }

    // MARK: - 输入

    private var searchBar: some View {
        HStack(spacing: Metrics.spacingS) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("片名 / 剧名", text: $keyword, prompt: Text("片名 / 剧名"))
                .textFieldStyle(.plain)
                .onSubmit { viewModel.search(keyword) }
            if viewModel.isLoading {
                ProgressView().controlSize(.small)
            }
            Button("搜索") { viewModel.search(keyword) }
                .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, Metrics.spacingM)
        .padding(.vertical, Metrics.spacingS)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.card))
        .padding(.horizontal, Metrics.spacingXL)
        .padding(.bottom, Metrics.spacingM)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if let failure = viewModel.sourcesLoadFailure {
            ErrorStateView(
                failure: LoadFailure(message: failure),
                retry: { Task { await viewModel.loadSources() } },
                login: nil)
        } else if viewModel.hasNoSources {
            ContentUnavailableView {
                Label("没有搜索源", systemImage: "antenna.radiowaves.left.and.right")
            } actions: {
                Button("配置搜索源…") { onOpenSettings() }
                    .buttonStyle(.borderedProminent)
            }
        } else if viewModel.submittedKeyword.isEmpty {
            ContentUnavailableView(
                "搜网盘资源",
                systemImage: "shippingbox")
        } else {
            results
        }
    }

    @ViewBuilder
    private var results: some View {
        switch viewModel.state {
        case .none, .some(.idle):
            Color.clear
        case .some(.loading):
            ProgressView("正在搜索 \(viewModel.submittedKeyword)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .some(.failed(let failure)):
            ErrorStateView(failure: failure, retry: { viewModel.retry() }, login: nil)
        case .some(.loaded):
            loadedResults
        }
    }

    @ViewBuilder
    private var loadedResults: some View {
        let resources = viewModel.visibleResources
        VStack(spacing: 0) {
            filterBar
            if resources.isEmpty {
                ContentUnavailableView("没有匹配的资源", systemImage: "magnifyingglass")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: Metrics.spacingM) {
                        ForEach(resources) { resource in
                            ResourceRow(
                                resource: resource,
                                sourceName: sourceName(for: resource.sourceID),
                                onCopy: copy,
                                onOpen: open,
                                onTransfer: { pendingTransfer = $0 })
                        }
                    }
                    .padding(.horizontal, Metrics.spacingXL)
                    .padding(.vertical, Metrics.spacingM)
                }
            }
            if !viewModel.failures.isEmpty {
                failureBar
            }
        }
    }

    /// 网盘类型筛选。只列这次结果里真出现过的类型,⛔ 不列一堆点了没结果的选项。
    private var filterBar: some View {
        HStack(spacing: Metrics.spacingS) {
            Text("\(viewModel.visibleResources.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Picker("网盘", selection: Binding(
                get: { viewModel.cloudTypeFilter },
                set: { viewModel.cloudTypeFilter = $0 })) {
                Text("全部网盘").tag(PanCloudType?.none)
                ForEach(viewModel.availableCloudTypes, id: \.self) { type in
                    Text(type.displayName).tag(PanCloudType?.some(type))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, Metrics.spacingXL)
        .padding(.bottom, Metrics.spacingS)
    }

    /// 失败的源。放在底部一条:它不该盖住已经搜到的结果,但必须能看见。
    private var failureBar: some View {
        HStack(spacing: Metrics.spacingS) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(viewModel.failures.map { $0.displayName }.joined(separator: "、") + " 没返回结果")
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("详情") {
                toast = viewModel.failures.map { "\($0.displayName):\($0.message)" }
                    .joined(separator: "\n")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, Metrics.spacingXL)
        .padding(.vertical, Metrics.spacingS)
        .background(.background.secondary)
    }

    private func sourceName(for id: String) -> String {
        viewModel.sources.first { $0.id == id }?.displayName ?? id
    }

    // MARK: - 动作

    private func copy(_ link: PanResourceLink) {
        var text = link.url
        if let password = link.password, !password.isEmpty {
            text += "\n提取码:\(password)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast = "已复制"
    }

    private func open(_ link: PanResourceLink) {
        guard let url = URL(string: link.url) else { return }
        NSWorkspace.shared.open(url)
    }
}
