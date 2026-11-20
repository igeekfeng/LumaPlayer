import SwiftUI

/// 添加夸克网盘来源:扫码 → 成功后落库。
///
/// 与 `Pan115AddView` 同一个套路:夸克 TV 端没有应用配置要填,登录态全 App 一份,
/// 所以这里只是「扫一次码,然后挂一个来源」。
///
/// ⚠️ 与 115 的一处关键差别:**先扫码、再填片库根**。TV 端能读整个网盘,但只有读能力
/// (`docs/QUARK_API.md` §9),所以加完来源后需要一个目录当起点 —— 那是设置页的事,这里不挡流程。
struct QuarkAddView: View {
    let container: AppContainer
    let onBack: () -> Void
    let onDone: () -> Void

    @State private var viewModel: FileSourceViewModel
    @State private var isFinishing = false
    @State private var errorMessage: String?

    @MainActor
    init(container: AppContainer, onBack: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.container = container
        self.onBack = onBack
        self.onDone = onDone
        self._viewModel = State(
            initialValue: FileSourceViewModel(
                container: container,
                // 来源还没落库,这里的 `id` 是临时的;⛔ 传 `loadsDirectory: false`,
                // 免得用临时 id 去取封面 / 落盘缓存。
                source: QuarkSource(),
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
        // 登录成功 → 落库。⛔ 没有这一步,扫码白扫:凭据在,但来源列表里没有它。
        .onChange(of: viewModel.quarkAuthorization) { _, newValue in
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
        switch viewModel.quarkAuthorization {
        case .needsAuthorization:
            QuarkAuthorizationView(viewModel: viewModel)
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
                ProgressView("正在读取登录状态…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func failurePane(_ failure: LoadFailure) -> some View {
        VStack(spacing: Metrics.spacingL) {
            OnboardingFormHeader(
                systemImage: "exclamationmark.triangle.fill",
                title: "打不开夸克网盘",
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
                try await container.registerQuarkSource()
                onDone()
            } catch {
                errorMessage = "保存来源失败:\(error.localizedDescription)"
                isFinishing = false
            }
        }
    }
}
