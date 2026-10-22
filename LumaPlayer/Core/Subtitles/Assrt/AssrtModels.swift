import Foundation

// MARK: - 归一形态(UI 与业务层只认这些,不认 JSON 字段名)

struct AssrtSearchResult: Sendable, Equatable, Identifiable {
    let id: Int
    /// 原生标题
    let title: String
    let videoName: String?
    /// `Subrip(srt)` / `ASS` / `VobSub` …
    let format: String?
    /// `lang.desc`,如「简 双语」
    let language: String?
    let uploadTime: String?
    let releaseSite: String?
    let voteScore: Int
}

struct AssrtSubtitleFile: Sendable, Equatable {
    let fileName: String
    let url: URL
}

struct AssrtSubtitleDetail: Sendable, Equatable {
    let id: Int
    /// `filelist` 里的单文件直链(服务端临时解压)
    let files: [AssrtSubtitleFile]
    /// 整包地址:`filelist` 为空或单文件下载失败时用
    let archiveFileName: String?
    let archiveURL: URL?

    var hasAnyDownload: Bool {
        !files.isEmpty || archiveURL != nil
    }
}

// MARK: - DTO

/// `GET /v1/sub/search`。`status != 0` 是业务错误(HTTP 仍是 200)。
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
    /// `"简 双语"` / `"韩 双语"`,可能为空
    let desc: String?
}

/// `GET /v1/sub/detail`
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
    /// 整包地址。⚠️ 一次性链接,文档要求不要保存
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
    let fileName: String?
    /// 如 `"52KB"`
    let size: String?
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
    /// 地址解析不出来的条目丢掉。
    var detail: AssrtSubtitleDetail {
        let files = (filelist ?? []).compactMap { entry -> AssrtSubtitleFile? in
            guard let name = entry.fileName?.nilIfEmpty,
                  let raw = entry.url?.nilIfEmpty,
                  let url = Self.downloadURL(raw) else { return nil }
            return AssrtSubtitleFile(fileName: name, url: url)
        }
        return AssrtSubtitleDetail(
            id: id,
            files: files,
            archiveFileName: filename?.nilIfEmpty,
            archiveURL: url.flatMap(Self.downloadURL))
    }

    /// assrt 自家主机(`assrt.net` 及子域)的 `http` 升成 `https`:详情给的是明文地址,ATS 会拒,
    /// 而该主机有有效证书,所以升级而不是给 ATS 开例外。⛔ 别的主机原样保留,不替它猜 https。
    static func downloadURL(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw) else { return nil }
        if components.scheme?.lowercased() == "http",
           let host = components.host?.lowercased(),
           host == "assrt.net" || host.hasSuffix(".assrt.net") {
            components.scheme = "https"
        }
        return components.url
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
