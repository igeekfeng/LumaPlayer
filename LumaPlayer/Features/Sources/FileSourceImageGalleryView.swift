import SwiftUI

/// 图片墙里点开的「看哪一层」:剧级 / 某一季 / 某一集。
/// ⚠️ 分集是**每集一次**请求(§12),只有用户点开这一集时才发,⛔ 不为整季批量拉。
struct FileSourceImageRequest: Identifiable, Sendable {
    let title: String
    let season: Int?
    let episode: Int?

    var id: String {
        "\(season.map(String.init) ?? "s")|\(episode.map(String.init) ?? "e")|\(title)"
    }
}

/// TMDB 图片墙:背景图 / 海报 / Logo / 剧照分类横向浏览。
/// 数据在 `task` 里按需拉一次,失败明示,⛔ 不用空数组冒充「没有图」(`CLAUDE.md` 硬规则 4)。
struct FileSourceImageGalleryView: View {
    let request: FileSourceImageRequest
    let sourceID: UUID
    let store: PosterImageStore
    let load: @MainActor (FileSourceImageRequest) async throws -> TMDBImageSet

    @Environment(\.dismiss) private var dismiss
    @State private var imageSet: TMDBImageSet?
    @State private var isLoading = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingL) {
            HStack {
                VStack(alignment: .leading, spacing: Metrics.spacingXXS) {
                    Text("图片").font(.title2.bold())
                    Text(request.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if isLoading {
                ProgressView("正在读取图片…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure {
                VStack(alignment: .leading, spacing: Metrics.spacingM) {
                    OnboardingNotice(text: failure, style: .error)
                    Button("重试") { Task { await fetch() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let imageSet, !imageSet.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.spacingXL) {
                        if !imageSet.backdrops.isEmpty {
                            section("背景图", assets: imageSet.backdrops, size: TMDBImage.backdropSize, landscape: true)
                        }
                        if !imageSet.posters.isEmpty {
                            section("海报", assets: imageSet.posters, size: TMDBImage.galleryPosterSize, landscape: false)
                        }
                        if !imageSet.logos.isEmpty {
                            section("Logo", assets: imageSet.logos, size: TMDBImage.logoSize, landscape: true)
                        }
                        if !imageSet.stills.isEmpty {
                            section("剧照", assets: imageSet.stills, size: TMDBImage.stillSize, landscape: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("TMDB 还没有这一层的图片。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(Metrics.spacingXL)
        .frame(minWidth: 640, minHeight: 460)
        .task(id: request.id) { await fetch() }
    }

    @ViewBuilder
    private func section(
        _ title: String, assets: [TMDBImageAsset], size: String, landscape: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingS) {
            Text("\(title) · \(assets.count)")
                .font(.headline)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Metrics.spacingM) {
                    ForEach(assets) { asset in
                        PosterImage(
                            descriptor: descriptor(for: asset, size: size),
                            store: store,
                            placeholderSystemImage: "photo"
                        )
                        .aspectRatio(landscape ? Metrics.landscapeAspectRatio : Metrics.heroAspectRatio,
                                     contentMode: .fit)
                        .frame(height: landscape ? 150 : 210)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    }
                }
                .padding(.vertical, Metrics.spacingXS)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func descriptor(for asset: TMDBImageAsset, size: String) -> ImageDescriptor? {
        BaiduPanMetadataScraper.imageDescriptor(
            path: asset.filePath, size: size, sourceID: sourceID)
    }

    private func fetch() async {
        isLoading = true
        failure = nil
        defer { isLoading = false }
        do {
            imageSet = try await load(request)
        } catch let error as TMDBError {
            failure = error.userMessage
        } catch is CancellationError {
            // 关掉 sheet:不算失败
        } catch {
            failure = "读取图片失败:\(error)"
        }
    }
}
