import CoreFoundation
import Foundation

/// 外挂字幕文本的编码归一(纯函数,无文件 IO、无网络)。
///
/// ## 为什么客户端要自己转
///
/// 中文字幕大量是 GBK / GB18030 / BIG5 —— 直接丢给 mpv 也不是完全不行(libmpv 编了
/// uchardet,`--sub-codepage` 默认 `auto`),但嗅探对**短文件**经常失败:一集只有几十行
/// 时 uchardet 的置信度不够,回落到 `UTF-8-BROKEN`,中文全变乱码。
/// 与其在播放器里调 `sub-codepage`,不如落盘前统一成 UTF-8:
/// 转换只做一次,之后 mpv、`sub-delay`、字幕外观、导出都按同一份文本走。
///
/// ## 顺序(每一步都是「先确定再猜」)
///
/// 1. UTF-8 BOM → 去掉 BOM 后按 UTF-8(不重新编码);
/// 2. 本身就是合法 UTF-8 → 原样返回;
/// 3. UTF-16:BOM 优先;没有 BOM 时只在**一半字节为 0**这种强特征下才认
///    (纯中文的 UTF-16 没有 0 字节,硬猜会把 GBK 认成 UTF-16 乱码);
/// 4. GB18030(兼容 GBK / GB2312)→ BIG5;
/// 5. 都不成立 → **原样保留**,标 `unrecognized`,交给 mpv 的 uchardet 兜底。
///    ⛔ 不因为编码认不出就拒绝加载:能播总比报错强,但要把结论如实带出去。
enum SubtitleTextDecoder {

    enum Outcome: Equatable {
        /// 本来就是 UTF-8(含只有 BOM 差异的情况)
        case alreadyUTF8
        /// 从别的编码转成了 UTF-8,值是编码名(只用于日志)
        case converted(String)
        /// 认不出编码,字节原样保留
        case unrecognized
    }

    struct Result: Equatable {
        let data: Data
        let outcome: Outcome
    }

    static func normalize(_ data: Data) -> Result {
        guard !data.isEmpty else { return Result(data: data, outcome: .unrecognized) }

        // 1. UTF-8 BOM:只去掉三个字节,不重编码(重编码会让行尾 / 特殊空白走样)
        if data.starts(with: utf8BOM) {
            return Result(data: Data(data.dropFirst(utf8BOM.count)), outcome: .alreadyUTF8)
        }

        // 2. 合法 UTF-8
        if String(data: data, encoding: .utf8) != nil {
            return Result(data: data, outcome: .alreadyUTF8)
        }

        // 3. UTF-16(BOM 或强特征)
        if let encoding = utf16Encoding(of: data),
           let text = String(data: data, encoding: encoding),
           looksLikeText(text),
           let converted = text.data(using: .utf8) {
            return Result(data: converted, outcome: .converted(encoding == .utf16LittleEndian ? "UTF-16LE" : "UTF-16BE"))
        }

        // 4. 中文老编码:GB18030 覆盖 GBK / GB2312,先试它;再试繁体常见的 BIG5
        for (encoding, name) in legacyEncodings {
            guard let text = String(data: data, encoding: encoding),
                  looksLikeText(text),
                  let converted = text.data(using: .utf8) else { continue }
            return Result(data: converted, outcome: .converted(name))
        }

        // 5. 认不出:原样交给 mpv
        return Result(data: data, outcome: .unrecognized)
    }

    // MARK: - 细节

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    private static let legacyEncodings: [(String.Encoding, String)] = [
        (gb18030, "GB18030"),
        (big5, "BIG5"),
    ]

    /// GB18030:GBK 的超集,简体中文最可能的来源。
    private static var gb18030: String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    }

    /// BIG5:繁体中文(台 / 港)最常见的旧编码。
    private static var big5: String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue)))
    }

    /// 解出来的东西像不像字幕文本。
    ///
    /// 老编码的解码器是**宽容**的:GB18030 会把孤立的 `0x80` 解成 `€`,
    /// 二进制文件也能「成功」解出一串字符。这里做最后一道常识判断:
    /// NUL / 替换字符 / 超过 5% 的控制字符 —— 字幕里都不该有。
    ///
    /// ⚠️ 这不是完备的判别(纯 `0x80` 的字节仍会被当成 `€`),但足以挡住
    /// 「把压缩包 / 图片改名成 .srt」这类误操作。判不准时宁可退回 `unrecognized`,
    /// 让 mpv 的 uchardet 再试一次。
    private static func looksLikeText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var suspicious = 0
        var total = 0
        for scalar in text.unicodeScalars {
            total += 1
            if scalar == "\u{FFFD}" || scalar.value == 0 { return false }
            if scalar.value < 0x20,
               scalar != "\n", scalar != "\r", scalar != "\t" {
                suspicious += 1
            }
        }
        return suspicious * 20 <= total
    }

    /// UTF-16 的判定:BOM 是硬证据;没有 BOM 时只认「一半字节是 0」——
    /// 那是 ASCII 文本在 UTF-16 下的形状。⛔ 不无条件试 UTF-16:
    /// 任意字节串都能被解成某个 UTF-16 码位,猜错了就是满屏乱码。
    private static func utf16Encoding(of data: Data) -> String.Encoding? {
        if data.count >= 2 {
            if data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xFE {
                return .utf16LittleEndian
            }
            if data[data.startIndex] == 0xFE, data[data.startIndex + 1] == 0xFF {
                return .utf16BigEndian
            }
        }
        guard data.count >= 4 else { return nil }
        let sample = data.prefix(512)
        var evenNUL = 0
        var oddNUL = 0
        for (offset, byte) in sample.enumerated() where byte == 0 {
            if offset.isMultiple(of: 2) { evenNUL += 1 } else { oddNUL += 1 }
        }
        let pairs = sample.count / 2
        guard pairs > 0 else { return nil }
        // 小端:低字节在前,ASCII 的高字节落在奇数位 → 奇数位全 0
        if oddNUL > pairs / 3, evenNUL == 0 { return .utf16LittleEndian }
        if evenNUL > pairs / 3, oddNUL == 0 { return .utf16BigEndian }
        return nil
    }
}
