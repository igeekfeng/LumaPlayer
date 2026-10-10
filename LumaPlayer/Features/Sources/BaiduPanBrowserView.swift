import SwiftUI

/// 百度网盘目录浏览。
///
/// ⚠️ 这一页**没有封面图**:列表接口只有在传 `web=1` 时才给缩略图地址,
/// 而本项目不接缩略图(它们是有时效的、要带 token 才能取的临时地址,
/// 而 `PosterImage` 那条缓存通路是照 Emby 的认证头写的)。
/// 与其留一片占位图,不如老实用文件名列表 —— 列表里要快速区分的是
/// 「目录 / 视频 / 其它」,图标就够了。
struct BaiduPanBrowserView: View {
    let viewModel: BaiduPanSourceViewModel

    /// ⛔ 唤起播放窗口。**写请求与开窗必须成对出现**:`AppState.nowPlaying`
    /// 只是「请播放器播这一项」的请求,窗口不会因为写了请求自己出现 ——
    /// 少了 `openWindow` 就是点了播放毫无动静(Emby 那 4 个调用点同理)。
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            if let notice = viewModel.notice {
                OnboardingNotice(text: notice, style: .warning)
                    .padding(.horizontal, Metrics.spacingL)
                    .padding(.vertical, Metrics.spacingS)
                Divider()
            }
            content
        }
    }

    // MARK: - 路径栏

    private var pathBar: some View {
        HStack(spacing: Metrics.spacingS) {
            Button {
                Task { await viewModel.goUp() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!viewModel.canGoUp)
            .help("返回上一层")

            if let account = viewModel.authorization?.accountName {
                Label(account, systemImage: "person.crop.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            libraryRootMark

            Text(viewModel.relativePath ?? "/")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            libraryRootButton

            Button {
                Task { await viewModel.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(viewModel.isLoadingFiles)
            .help("刷新")

            Button("解除授权") {
                Task { await viewModel.signOut() }
            }
            .help("清除本机保存的百度授权,回到扫码那一屏")
        }
        .padding(.horizontal, Metrics.spacingL)
        .padding(.vertical, Metrics.spacingS)
    }

    // MARK: - 片库根

    /// 当前目录就是片库根时,在路径前面挂一个书签标记。
    @ViewBuilder
    private var libraryRootMark: some View {
        if viewModel.isCurrentDirectoryLibraryRoot {
            Image(systemName: "bookmark.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("这里是片库根:每次打开百度网盘都会先落在这个目录")
        }
    }

    @ViewBuilder
    private var libraryRootButton: some View {
        if viewModel.canSetLibraryRoot {
            Button("设为片库根", systemImage: "bookmark") {
                Task { await viewModel.setLibraryRootToCurrentDirectory() }
            }
            .help("把当前目录设为进入百度网盘时的起点")
        } else if viewModel.isCurrentDirectoryLibraryRoot {
            Button("取消片库根", systemImage: "bookmark.slash") {
                Task { await viewModel.clearLibraryRoot() }
            }
            .help("回到应用目录作为进入时的起点")
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoadingFiles, viewModel.files.isEmpty {
            VStack(spacing: Metrics.spacingS) {
                ProgressView()
                Text("正在读取目录…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure = viewModel.directoryFailure {
            failurePane(failure)
        } else if viewModel.files.isEmpty {
            ContentUnavailableView {
                Label("这里还没有可播的文件", systemImage: "folder")
            } description: {
                Text(emptyHint)
            } actions: {
                Button("刷新") { Task { await viewModel.loadFiles() } }
            }
        } else {
            List(viewModel.files) { file in
                BaiduPanFileRow(
                    file: file,
                    resumeSeconds: viewModel.resumeSeconds(for: file),
                    onOpen: {
                        if file.isDirectory {
                            Task { await viewModel.enter(file) }
                        } else {
                            play(file)
                        }
                    }
                )
            }
            .listStyle(.inset)
        }
    }

    // MARK: - 动作

    /// 点一行里的文件(或「播放」按钮):写请求 + 唤起播放窗口。
    private func play(_ file: BaiduPanFile) {
        viewModel.play(file)
        openWindow(id: PlayerSceneRoot.windowID)
    }

    /// 目录读失败。分两种处置:
    ///
    /// - **应用目录本身读不出来** → 给「核对应用目录名」(改那个名字),
    ///   而不是「重试」。因为这种失败九成是目录名与控制台里的应用名不一致,
    ///   重试多少次都是同一个结果(§2.1:可访问范围完全由那一个值决定)。
    /// - 其余(子目录、网络、token)→ 老实的错误 + 重试。
    private func failurePane(_ failure: BaiduPanDirectoryFailure) -> some View {
        VStack(spacing: Metrics.spacingM) {
            if failure.isApplicationRootUnavailable {
                OnboardingFormHeader(
                    systemImage: "folder.badge.questionmark",
                    title: "读不到应用目录",
                    subtitle: applicationRootHint
                )
                Button("核对应用目录名") {
                    Task { await viewModel.beginConfigurationEdit() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                OnboardingNotice(text: failure.message, style: .error)
            }
            Button("重试") { Task { await viewModel.loadFiles() } }
        }
        .padding(Metrics.spacingXL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 空目录的引导。
    ///
    /// ⚠️ 刻意把「空的」与「还不存在」合在一段里说:对一个**不存在**的目录,
    /// 百度未必返回错误码 —— 也可能就是一个空 `list`(见 **Q45**,未实测)。
    /// ⛔ 不猜它属于哪一种,把两种成因和各自的做法都摆出来。
    ///
    /// 另一件必须讲清的事:**`/apps` 这一层用户建不了**(百度把 `apps` 当保留
    /// 关键字,自建会报「apps 为关键字,无法创建」)。用户能碰的只有
    /// 「我的应用数据」**里面** —— 在那里新建一个与控制台应用名**完全一致**
    /// (含大小写)的文件夹。⛔ 绝不能写成「去网盘里建一个 apps 文件夹」。
    private var emptyHint: String {
        let name = viewModel.folderName ?? "应用目录"
        guard viewModel.relativePath == "/" else {
            return "这一层没有可播的文件。往上一级看看,或者把视频放进这个目录再回来刷新。"
        }
        return "第三方应用只能访问网盘里的「我的应用数据/\(name)」,访问不到其它地方。"
            + "如果网盘里还看不到这个目录:打开百度网盘的「我的应用数据」,新建一个名为"
            + " \(name) 的文件夹(名字要与开放平台控制台里的「应用名称」完全一致,"
            + "包括大小写),再把视频放进去,然后回来刷新。"
            + "也可能它还没生成 —— 网盘通常在应用第一次读取时自动建出这个目录。"
    }

    private var applicationRootHint: String {
        let name = viewModel.folderName ?? "应用目录"
        return "百度没给出 /apps/\(name) 这个目录。请核对开放平台控制台里的「应用名称」"
            + "与本 App 里填的完全一致,并确认网盘里的「我的应用数据/\(name)」确实存在。"
    }
}

/// 一行:图标 + 名字 + 体积/时长/续播。
private struct BaiduPanFileRow: View {
    let file: BaiduPanFile
    let resumeSeconds: Double?
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: Metrics.spacingM) {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(file.isDirectory ? .blue : .secondary)
                .frame(width: Metrics.serverRowIconSize)

            VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                Text(file.name)
                    .lineLimit(2)
                if let detail = detailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if file.isDirectory {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            } else if file.kind.isPlayable {
                Button("播放", systemImage: "play.fill", action: onOpen)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Text("不可播")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, Metrics.spacingXXS)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private var symbolName: String {
        if file.isDirectory { return "folder.fill" }
        switch file.kind {
        case .video: return "film"
        case .audio: return "music.note"
        case .other: return "doc"
        }
    }

    /// ⛔ 缺字段就不显示(不填「未知」),与 `EmbyItem` 的口径一致
    private var detailText: String? {
        var parts: [String] = []
        if let size = file.sizeBytes, !file.isDirectory {
            parts.append(size.formatted(.byteCount(style: .file)))
        }
        if let resume = resumeSeconds, resume > 0 {
            parts.append("已看到 \(PlayerTime.text(resume))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
