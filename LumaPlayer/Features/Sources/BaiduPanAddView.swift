import SwiftUI

/// 添加百度网盘来源的流程:填密钥 → 扫码 → 授权成功后落库。
///
/// 复用了来源页那套 `BaiduPanSourceViewModel` 与 `BaiduPanAuthorizationView` ——
/// 「保存配置 → 立刻走扫码」本来就是同一条连续流程,不必在添加流程里再写一遍。
/// 差别只在**收尾**:这里授权成功后要把来源写进注册表并切换过去。
struct BaiduPanAddView: View {
    let container: AppContainer
    let onBack: () -> Void
    let onDone: () -> Void

    @State private var viewModel: BaiduPanSourceViewModel
    @State private var isFinishing = false
    @State private var errorMessage: String?

    @MainActor
    init(container: AppContainer, onBack: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.container = container
        self.onBack = onBack
        self.onDone = onDone
        self._viewModel = State(
            initialValue: BaiduPanSourceViewModel(
                container: container,
                // 添加流程里来源还没落库,这里的 `id` 是临时的;
                // 真正定下来是 `registerBaiduSource` 那一刻。
                // ⛔ 传 `loadsDirectory: false` 就是为了让临时的 id 永远用不上
                // (一旦列了目录就会用临时 id 去取封面 —— 白烧一次配额)。
                source: BaiduPanSource(folderName: ""),
                loadsDirectory: false
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            backBar
            Divider()
            content
        }
        .task { await viewModel.reload() }
        // 授权成功 → 落库。⛔ 没有这一步,扫码白扫:凭据在,但来源列表里没有它。
        .onChange(of: viewModel.authorization) { _, newValue in
            guard case .authorized = newValue else { return }
            finish()
        }
        .alert(
            "保存失败",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var backBar: some View {
        HStack {
            Button {
                onBack()
            } label: {
                Label("选择其它来源", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(isFinishing)
            Spacer()
        }
        .padding(.horizontal, Metrics.spacingL)
        .padding(.vertical, Metrics.spacingS)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.authorization {
        case .unconfigured, .needsAuthorization:
            BaiduPanAuthorizationView(viewModel: viewModel)
        case .authorized:
            VStack(spacing: Metrics.spacingS) {
                ProgressView()
                Text("正在保存来源…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case nil:
            if let failure = viewModel.loadFailure {
                failurePane(failure)
            } else {
                ProgressView("正在读取授权状态…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func failurePane(_ failure: LoadFailure) -> some View {
        VStack(spacing: Metrics.spacingL) {
            OnboardingFormHeader(
                systemImage: "exclamationmark.triangle.fill",
                title: "打不开百度网盘",
                subtitle: failure.message
            )
            Button("重试") { Task { await viewModel.reload() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(Metrics.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        Task {
            do {
                try await container.registerBaiduSource()
                onDone()
            } catch {
                errorMessage = "保存来源失败:\(error.localizedDescription)"
                isFinishing = false
            }
        }
    }
}
