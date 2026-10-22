import CoreFoundation
import Foundation

/// 外挂字幕文本的编码归一成 UTF-8(纯函数)。
///
/// 落盘前自己转,不靠 mpv 的 uchardet:它对短文件(几十行)置信度不够,会回落成乱码。
///
/// 顺序(先确定再猜):
/// 1. UTF-8 BOM → 去掉 BOM;
/// 2. 合法 UTF-8 → 原样;
/// 3. UTF-16:BOM 优先;无 BOM 只认「一半字节为 0」的强特征(否则会把 GBK 认成 UTF-16);
/// 4. GB18030(兼容 GBK / GB2312)→ BIG5;
/// 5. 都不成立 → 原样保留标 `unrecognized`,交给 mpv 兜底。⛔ 不因认不出编码就拒绝加载。
enum SubtitleTextDecoder {

    enum Outcome: Equatable {
        /// 含只有 BOM 差异的情况
        case alreadyUTF8
        /// 值是源编码名(只用于日志)
        case converted(String)
        /// 字节原样保留
        case unrecognized
    }

    struct Result: Equatable {
        let data: Data
        let outcome: Outcome
    }

    static func normalize(_ data: Data) -> Result {
        guard !data.isEmpty else { return Result(data: data, outcome: .unrecognized) }

        // 只去掉三个字节,不重编码(会让行尾 / 特殊空白走样)
        if data.starts(with: utf8BOM) {
            return Result(data: Data(data.dropFirst(utf8BOM.count)), outcome: .alreadyUTF8)
        }

        if String(data: data, encoding: .utf8) != nil {
            return Result(data: data, outcome: .alreadyUTF8)
        }

        if let encoding = utf16Encoding(of: data),
           let text = String(data: data, encoding: encoding),
           looksLikeText(text),
           let converted = text.data(using: .utf8) {
            return Result(data: converted, outcome: .converted(encoding == .utf16LittleEndian ? "UTF-16LE" : "UTF-16BE"))
        }

        for (encoding, name) in legacyEncodings {
            guard let text = String(data: data, encoding: encoding),
                  looksLikeText(text),
                  let converted = text.data(using: .utf8) else { continue }
            return Result(data: converted, outcome: .converted(name))
        }

        return Result(data: data, outcome: .unrecognized)
    }

    // MARK: - 细节

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    private static let legacyEncodings: [(String.Encoding, String)] = [
        (gb18030, "GB18030"),
        (big5, "BIG5"),
    ]

    private static var gb18030: String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    }

    private static var big5: String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue)))
    }

    /// 老编码解码器很宽容,二进制也能「成功」解出字符。出现 NUL / 替换字符 / 超过 5% 控制字符
    /// 就判不是文本。不完备,但足以挡住「压缩包 / 图片改名成 .srt」。
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

    /// BOM 是硬证据;无 BOM 只认 ASCII 文本在 UTF-16 下的形状(一侧字节全 0)。
    /// ⛔ 不无条件试 UTF-16:任意字节串都能解成 UTF-16 码位。
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
