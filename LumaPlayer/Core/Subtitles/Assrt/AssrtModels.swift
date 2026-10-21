import Foundation

// MARK: - 归一形态(UI 与业务层只认这些,不认 JSON 字段名)

/// 一条搜索结果。
struct AssrtSearchResult: Sendable, Equatable, Identifiable {
    /// assrt 的字幕 id(6 位数字)
    let id: Int
    /// 作品名 / 原生标题
    let title: String
    /// 字幕对应的视频文件名(有就显示,能帮用户判断是不是这一版)
    let videoName: String?
    /// 字幕格式(`Subrip(srt)` / `ASS` / `VobSub` …)
    let format: String?
    /// 语言描述(assrt 的 `lang.desc`,如「简 双语」)
    let language: String?
    let uploadTime: String?
    let releaseSite: String?
    let voteScore: Int
}

/// 详情里的一个文件(通常是压缩包内的一条,或整包)。
struct AssrtSubtitleFile: Sendable, Equatable {
    let fileName: String
    let url: URL
}

/// 一条字幕的详情。
struct AssrtSubtitleDetail: Sendable, Equatable {
    let id: Int
    /// `filelist` 里的**单文件直链**。assrt 常常直接给 `.srt`,能省掉解压。
    let files: [AssrtSubtitleFile]
    /// 整包(压缩包)地址 —— 只有 `filelist` 为空时才有意义。
    let archiveFileName: String?
    let archiveURL: URL?

    /// 有没有任何可下载的地址。
    var hasAnyDownload: Bool {
        !files.isEmpty || archiveURL != nil
    }
}

// MARK: - DTO

/// `GET /v1/sub/search` 的响应。
///
/// `status != 0` 是业务错误(HTTP 仍是 200),⛔ 别只看 HTTP 状态。
struct AssrtSearchEnvelope: Decodable {
    let status: Int
    let message: String?
    let sub: AssrtSearchPayload?
}

struct AssrtSearchPayload: Decodable {
    let subs: [AssrtSubtitleDTO]?
}

struct AssrtSubtitleDTO: Decodable {
    let id: Int
    let nativeName: String?
    let videoName: String?
    let subtype: String?
    let uploadTime: String?
    let voteScore: Int?
    let releaseSite: String?
    let language: AssrtLanguageDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case nativeName = "native_name"
        case videoName = "videoname"
        case subtype
        case uploadTime = "upload_time"
        case voteScore = "vote_score"
        case releaseSite = "release_site"
        case language = "lang"
    }
}

struct AssrtLanguageDTO: Decodable {
    /// 语言描述(`"简 双语"` / `"韩 双语"`),可能为空
    let desc: String?
}

/// `GET /v1/sub/detail` 的响应。
struct AssrtDetailEnvelope: Decodable {
    let status: Int
    let message: String?
    let sub: AssrtDetailPayload?
}

struct AssrtDetailPayload: Decodable {
    let subs: [AssrtDetailDTO]?
}

struct AssrtDetailDTO: Decodable {
    let id: Int
    let nativeName: String?
    let title: String?
    let filename: String?
    let subtype: String?
    /// 整包地址(压缩包)。⚠️ **一次性链接**,文档明确要求不要保存。
    let url: String?
    let filelist: [AssrtFileDTO]?

    enum CodingKeys: String, CodingKey {
        case id
        case nativeName = "native_name"
        case title
        case filename
        case subtype
        case url
        case filelist
    }
}

struct AssrtFileDTO: Decodable {
    /// 文件名(`f`)
    let fileName: String?
    /// 文件大小(`s`,如 `"52KB"`)
    let size: String?
    /// 单文件下载地址
    let url: String?

    enum CodingKeys: String, CodingKey {
        case fileName = "f"
        case size = "s"
        case url
    }
}

// MARK: - DTO → 归一

extension AssrtSubtitleDTO {
    var result: AssrtSearchResult {
        AssrtSearchResult(
            id: id,
            title: nativeName?.nilIfEmpty ?? "字幕 \(id)",
            videoName: videoName?.nilIfEmpty,
            format: subtype?.nilIfEmpty,
            language: language?.desc?.nilIfEmpty,
            uploadTime: uploadTime?.nilIfEmpty,
            releaseSite: releaseSite?.nilIfEmpty,
            voteScore: voteScore ?? 0)
    }
}

extension AssrtDetailDTO {
    /// 归一成详情。地址解析不出来就丢掉 —— 半个 URL 交给播放器只会失败得更晚。
    var detail: AssrtSubtitleDetail {
        let files = (filelist ?? []).compactMap { entry -> AssrtSubtitleFile? in
            guard let name = entry.fileName?.nilIfEmpty,
                  let raw = entry.url?.nilIfEmpty,
                  let url = URL(string: raw) else { return nil }
            return AssrtSubtitleFile(fileName: name, url: url)
        }
        return AssrtSubtitleDetail(
            id: id,
            files: files,
            archiveFileName: filename?.nilIfEmpty,
            archiveURL: url.flatMap { URL(string: $0) })
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
