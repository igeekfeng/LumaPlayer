import Foundation

/// 115 直链接口的报文加密(`docs/PAN115_API.md` §5)。
///
/// 两条路径都是**对称的 XOR 打底 + RSA 公钥做块变换**,不是标准 TLS 意义上的加密:
/// - 请求体:`{"pickcode": …}` 用一次性 16 字节 key 加密;
/// - 响应 `data`:用**同一个 key** 解开,所以一次请求必须成对完成,key 不能复用。
///
/// ⚠️ 「解密」用的是**公钥指数运算**(`pow(块, e, n)`),不是私钥解密 ⇒ 不能用
/// `SecKeyCreateDecryptedData`,只能自己算 1024-bit 模幂(`BigUInt` 就在本文件里)。
///
/// 本实现与 `p115cipher` 0.0.6 逐位对齐,比对用的向量在
/// `LumaPlayerTests/Pan115CryptoTests.swift`(生成脚本见 `docs/PAN115_API.md` §5.3)。
enum Pan115Crypto {

    // MARK: - 常量(§5.1)

    /// 默认 rand_key:全 0。此时派生出的 XOR key 恒为 `rsaKey`(见 `derivedKey(for:)`)。
    static let defaultRandKey = Data(repeating: 0, count: 16)

    private static let rsaKey = Data([0x8d, 0xa5, 0xa5, 0x8d])
    private static let gKeyL = Data([
        0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46,
    ])

    /// `rsa_gen_key` 用的密钥表,160 字节。
    private static let gKts: [UInt8] = [
        0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a, 0x1a, 0x45, 0xe8, 0xbe,
        0x7d, 0xa6, 0x73, 0xb8, 0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4,
        0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa, 0x38, 0x01, 0x35, 0x9e,
        0x26, 0x69, 0x2c, 0x86, 0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
        0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd, 0x6b, 0x97, 0x8f, 0x4d,
        0x8f, 0x89, 0x13, 0xb7, 0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e,
        0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86, 0x50, 0x95, 0x4f, 0xd1,
        0xeb, 0x83, 0x26, 0x34, 0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
        0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59, 0x34, 0x66, 0x3b, 0xaa,
        0xba, 0x81, 0x60, 0x48, 0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77,
        0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e, 0x36, 0x9f, 0x34, 0x80,
        0x5c, 0x45, 0x2c, 0x9b, 0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5,
    ]

    /// RSA 公钥 (n, e)。1024-bit,`e = 65537`。
    private static let modulus = BigUInt(bigEndian: Data([
        0x86, 0x86, 0x98, 0x0c, 0x0f, 0x5a, 0x24, 0xc4, 0xb9, 0xd4, 0x30, 0x20,
        0xcd, 0x2c, 0x22, 0x70, 0x3f, 0xf3, 0xf4, 0x50, 0x75, 0x65, 0x29, 0x05,
        0x8b, 0x1c, 0xf8, 0x8f, 0x09, 0xb8, 0x60, 0x21, 0x36, 0x47, 0x71, 0x98,
        0xa6, 0xe2, 0x68, 0x31, 0x49, 0x65, 0x9b, 0xd1, 0x22, 0xc3, 0x35, 0x92,
        0xfd, 0xb5, 0xad, 0x47, 0x94, 0x4a, 0xd1, 0xea, 0x4d, 0x36, 0xc6, 0xb1,
        0x72, 0xaa, 0xd6, 0x33, 0x8c, 0x3b, 0xb6, 0xac, 0x62, 0x27, 0x50, 0x2d,
        0x01, 0x09, 0x93, 0xac, 0x96, 0x7d, 0x1a, 0xef, 0x00, 0xf0, 0xc8, 0xe0,
        0x38, 0xde, 0x2e, 0x4d, 0x3b, 0xc2, 0xec, 0x36, 0x8a, 0xf2, 0xe9, 0xf1,
        0x0a, 0x6f, 0x1e, 0xda, 0x4f, 0x72, 0x62, 0xf1, 0x36, 0x42, 0x0c, 0x07,
        0xc3, 0x31, 0xb8, 0x71, 0xbf, 0x13, 0x9f, 0x74, 0xf3, 0x01, 0x0e, 0x3c,
        0x4f, 0xe5, 0x7d, 0xf3, 0xaf, 0xb7, 0x16, 0x83,
    ]))
    private static let exponent: UInt32 = 0x10001

    /// RSA 块大小(字节)。115 用 1024-bit 密钥。
    private static let blockSize = 128
    /// 每块能装多少明文:PKCS#1 v1.5 留 11 字节。
    private static let chunkSize = 117

    // MARK: - 对外

    /// 一次性 16 字节 key。⛔ 不要复用:同一 key 加密两次等于把 XOR 流重复使用。
    static func generateKey() -> Data {
        var generator = SystemRandomNumberGenerator()
        var key = Data(count: 16)
        for index in 0..<16 {
            key[index] = UInt8.random(in: 0...255, using: &generator)
        }
        return key
    }

    /// 加密请求体,返回 base64(直接塞进 form 的 `data=` 字段)。
    static func encode(_ data: Data, key: Data) throws -> String {
        let xorKey = try derivedKey(for: key)
        let reversed = Data(xor(data, xorKey).reversed())
        let body = key + xor(reversed, gKeyL)
        return rsaEncryptWithPubkey(body).base64EncodedString()
    }

    /// 解开响应里的 base64 `data`。
    static func decode(_ base64: String, key: Data) throws -> Data {
        guard let cipher = Data(base64Encoded: base64) else {
            throw Pan115Error.crypto("downurl 响应的 data 不是合法 base64")
        }
        return try decode(cipherData: cipher, key: key)
    }

    /// 同 `decode(_:key:)`,但直接吃二进制。单测比对向量时用。
    static func decode(cipherData: Data, key: Data) throws -> Data {
        let block = try rsaDecryptWithPubkey(cipherData)
        return try decodeBody(block, key: key)
    }

    /// `decode` 的后半段:RSA 公钥变换之后的那层 XOR。
    ///
    /// 拆出来是为了能拿参考实现生成的中间块直接比对(§5.3 的 `decode_chain` 向量)——
    /// 完整的 `decode` 需要一段真实的服务端密文才走得通。
    static func decodeBody(_ block: Data, key: Data) throws -> Data {
        let xorKey = try derivedKey(for: key)
        guard block.count >= 16 else {
            throw Pan115Error.crypto("解开后的块不足 16 字节,拿不到 rand_key")
        }
        let randKey = Data(block.prefix(16))
        let keyL = rsaGenKey(randKey, skLen: 12)
        let reversed = Data(xor(Data(block.dropFirst(16)), keyL).reversed())
        return xor(reversed, xorKey)
    }

    // MARK: - 派生与 XOR

    /// `rand_key` 全 0 时用固定 4 字节 key,否则从 `rand_key` 派生。
    /// 这是 `p115cipher` 的 `if rand_key is RSA_RAND_KEY` 分支 —— 客户端两条路径都用随机 key,
    /// 固定 key 只在历史报文里出现,保留是为了能用官方向量验证实现。
    private static func derivedKey(for randKey: Data) throws -> Data {
        guard randKey.count >= 4 else {
            throw Pan115Error.crypto("rand_key 不足 4 字节")
        }
        return randKey == defaultRandKey ? rsaKey : rsaGenKey(randKey, skLen: 4)
    }

    /// `rsa_gen_key`:从 `rand_key` 前 `skLen` 字节 + `gKts` 派生 XOR key。
    static func rsaGenKey(_ randKey: Data, skLen: Int) -> Data {
        var result = Data(count: skLen)
        var length = skLen * (skLen - 1)
        var index = 0
        for offset in 0..<skLen {
            let x = (Int(randKey[offset]) + Int(gKts[index])) & 0xff
            result[offset] = gKts[length] ^ UInt8(x)
            length -= skLen
            index += skLen
        }
        return result
    }

    /// 逐字节 XOR:先处理 `len(src) & 3` 的零头,之后按 key 长度分块、每块从头用整个 key。
    /// 等价于「`src[j] ^= key[(j - 零头) % key.count]`」,但照抄参考实现的分块顺序,
    /// 免得以后对不上向量。
    static func xor(_ source: Data, _ key: Data) -> Data {
        guard !key.isEmpty else { return source }
        var result = Data(count: source.count)
        let head = source.count & 0b11
        for index in 0..<head {
            result[index] = source[index] ^ key[index]
        }
        var offset = head
        while offset < source.count {
            let length = min(key.count, source.count - offset)
            for index in 0..<length {
                result[offset + index] = source[offset + index] ^ key[index]
            }
            offset += length
        }
        return result
    }

    // MARK: - RSA 公钥变换

    /// 按 117 字节分块做 PKCS#1 v1.5 填充 + 公钥指数运算,输出固定 128 字节/块。
    /// 填充字节是 0x02(不是标准里的随机非零),与参考实现一致。
    static func rsaEncryptWithPubkey(_ data: Data) -> Data {
        var result = Data()
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]
            var block = Data([0x00])
            block.append(Data(repeating: 0x02, count: blockSize - 2 - chunk.count))
            block.append(0x00)
            block.append(contentsOf: chunk)
            let cipher = BigUInt.power(BigUInt(bigEndian: block), exponent, modulus: modulus)
            result.append(cipher.bytes(count: blockSize))
            offset = end
        }
        return result
    }

    /// 按 128 字节分块做公钥指数运算,再剥掉 PKCS#1 填充。
    ///
    /// ⚠️ 剥填充的方式是「最短大端表示里第一个 0 字节之后」—— 依赖填充首字节非零,
    /// 所以 `minimalBytes()` 必须与 Python 的 `to_bytes(p, (p.bit_length()+7)>>3)` 一致。
    static func rsaDecryptWithPubkey(_ data: Data) throws -> Data {
        guard data.count % blockSize == 0 else {
            throw Pan115Error.crypto("密文长度 \(data.count) 不是 \(blockSize) 的整数倍")
        }
        var result = Data()
        var offset = 0
        while offset < data.count {
            let block = data[offset..<(offset + blockSize)]
            let plain = BigUInt.power(BigUInt(bigEndian: Data(block)), exponent, modulus: modulus)
            let bytes = plain.minimalBytes()
            guard let zero = bytes.firstIndex(of: 0x00) else {
                throw Pan115Error.crypto("解出来的块里没有填充分隔符")
            }
            result.append(contentsOf: bytes[(zero + 1)...])
            offset += blockSize
        }
        return result
    }
}

// MARK: - 最小定长大整数

/// 只做 RSA 需要的那几件事:大端字节 ↔ 整数、乘法、取模、模幂。
///
/// 为什么不引 BigInt:项目**零 SPM 依赖**(`CLAUDE.md`「常用命令」旁的硬约束),为 17 次
/// 模乘引一个包不划算。也不走 `SecKey`:那条路只有私钥运算,而 115 要的是**公钥**运算。
private struct BigUInt {

    /// 小端 32 位分组,末尾不留 0。空 = 0。
    private var limbs: [UInt32]

    init() {
        limbs = []
    }

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    init(bigEndian bytes: Data) {
        var limbs: [UInt32] = []
        limbs.reserveCapacity(bytes.count / 4 + 1)
        var accumulator: UInt32 = 0
        var shift: UInt32 = 0
        for byte in bytes.reversed() {
            accumulator |= UInt32(byte) << shift
            shift += 8
            if shift == 32 {
                limbs.append(accumulator)
                accumulator = 0
                shift = 0
            }
        }
        if shift > 0 {
            limbs.append(accumulator)
        }
        self.limbs = limbs
        normalize()
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 {
            limbs.removeLast()
        }
    }

    // MARK: 导出

    /// 固定长度的大端表示,不足补前导 0。
    func bytes(count: Int) -> Data {
        var little: [UInt8] = []
        little.reserveCapacity(limbs.count * 4)
        for limb in limbs {
            little.append(UInt8(truncatingIfNeeded: limb))
            little.append(UInt8(truncatingIfNeeded: limb >> 8))
            little.append(UInt8(truncatingIfNeeded: limb >> 16))
            little.append(UInt8(truncatingIfNeeded: limb >> 24))
        }
        if little.count < count {
            little.append(contentsOf: [UInt8](repeating: 0, count: count - little.count))
        }
        return Data(little.prefix(count).reversed())
    }

    /// 最短大端表示(去掉前导 0)。0 返回空 `Data`。
    func minimalBytes() -> Data {
        guard let last = limbs.last else { return Data() }
        let byteCount = (limbs.count - 1) * 4 + (4 - (last.leadingZeroBitCount / 8))
        return bytes(count: byteCount)
    }

    // MARK: 位

    var bitWidth: Int {
        guard let last = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - last.leadingZeroBitCount)
    }

    func bit(at index: Int) -> Bool {
        let limb = index / 32
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt32(index % 32)) & 1 == 1
    }

    // MARK: 比较与加减

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) {
            if lhs.limbs[index] != rhs.limbs[index] {
                return lhs.limbs[index] < rhs.limbs[index]
            }
        }
        return false
    }

    /// 要求 `lhs >= rhs`。
    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = [UInt32](repeating: 0, count: lhs.limbs.count)
        var borrow: Int64 = 0
        for index in 0..<lhs.limbs.count {
            let subtrahend = index < rhs.limbs.count ? Int64(rhs.limbs[index]) : 0
            var value = Int64(lhs.limbs[index]) - subtrahend - borrow
            if value < 0 {
                value += 1 << 32
                borrow = 1
            } else {
                borrow = 0
            }
            result[index] = UInt32(truncatingIfNeeded: value)
        }
        return BigUInt(limbs: result)
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        guard !lhs.limbs.isEmpty, !rhs.limbs.isEmpty else { return BigUInt() }
        var result = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count + 1)
        for left in 0..<lhs.limbs.count {
            var carry: UInt64 = 0
            let multiplicand = UInt64(lhs.limbs[left])
            for right in 0..<rhs.limbs.count {
                let index = left + right
                let current = UInt64(result[index]) + multiplicand * UInt64(rhs.limbs[right]) + carry
                result[index] = UInt32(truncatingIfNeeded: current)
                carry = current >> 32
            }
            var index = left + rhs.limbs.count
            while carry > 0 {
                let current = UInt64(result[index]) + carry
                result[index] = UInt32(truncatingIfNeeded: current)
                carry = current >> 32
                index += 1
            }
        }
        return BigUInt(limbs: result)
    }

    /// 逐位长除法(移位 + 试减)。位数只有 2048,够快且不会写错。
    static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(!rhs.limbs.isEmpty, "除数为 0")
        if lhs < rhs { return lhs }
        var remainder = BigUInt()
        var index = lhs.bitWidth - 1
        while index >= 0 {
            remainder.shiftLeftOne(inserting: lhs.bit(at: index))
            if !(remainder < rhs) {
                remainder = remainder - rhs
            }
            index -= 1
        }
        return remainder
    }

    private mutating func shiftLeftOne(inserting bit: Bool) {
        var carry: UInt32 = bit ? 1 : 0
        for index in 0..<limbs.count {
            let next = limbs[index] >> 31
            limbs[index] = (limbs[index] << 1) | carry
            carry = next
        }
        if carry != 0 {
            limbs.append(carry)
        }
    }

    // MARK: 模幂

    static func power(_ base: BigUInt, _ exponent: UInt32, modulus: BigUInt) -> BigUInt {
        var result = BigUInt(limbs: [1])
        var factor = base % modulus
        var remaining = exponent
        while remaining > 0 {
            if remaining & 1 == 1 {
                result = (result * factor) % modulus
            }
            remaining >>= 1
            if remaining > 0 {
                factor = (factor * factor) % modulus
            }
        }
        return result
    }
}
