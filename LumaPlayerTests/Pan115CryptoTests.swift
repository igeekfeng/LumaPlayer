import XCTest
@testable import LumaPlayer

/// 115 报文加密与 `p115cipher` 0.0.6 的逐位比对(`docs/PAN115_API.md` §5)。
///
/// 向量怎么来的:`/tmp/p115venv/bin/pip install p115cipher` 后跑
/// ```python
/// from p115cipher import rsa_encrypt
/// from p115cipher.util import rsa_gen_key, xor
/// ```
/// 结果抄进本文件。⛔ 不要用「我们自己的实现再跑一遍」当期望值 —— 那样错了也测不出来。
///
/// ⚠️ **`encode` 与 `decode` 不是互逆的**:两侧都对 RSA 用公钥指数(`e = 65537`),
/// 所以「自己加密再自己解密」拿不回原文。这是 115 的协议形状,不是实现 bug。
/// 因此这里分三段验:派生/XOR、加密(可复现)、解链后处理(喂参考实现生成的中间块)。
final class Pan115CryptoTests: XCTestCase {

    // MARK: - rsa_gen_key

    func testDerivedKeyMatchesReference() {
        XCTAssertEqual(
            Pan115Crypto.rsaGenKey(Data(repeating: 0, count: 16), skLen: 4).hexString,
            "8da5a58d")
        XCTAssertEqual(
            Pan115Crypto.rsaGenKey(Data(0...15), skLen: 4).hexString,
            "8ddaa370")
        XCTAssertEqual(
            Pan115Crypto.rsaGenKey(Data(0...15), skLen: 12).hexString,
            "ac81271bc54352d81c587497")
        XCTAssertEqual(
            Pan115Crypto.rsaGenKey(Data(repeating: 0xff, count: 16), skLen: 12).hexString,
            "b3832017c25959c0172283ab")
    }

    // MARK: - xor

    /// 参考实现的 `xor` 先吃掉 `len & 3` 的零头,再按 key 长度分块 —— 分块边界影响结果,
    /// 所以五种长度都要覆盖(1 / 5 / 7 / 12 / 17)。
    func testXorMatchesReference() {
        let key = Data(hexString: "8da5a58d")
        let cases: [(String, String)] = [
            ("41", "cc"),
            ("6162636465", "ecefc6c1e8"),
            ("61626364656667", "ecc7c6e9c0c3ea"),
            ("6162636465666768696a6b6c", "ecc7c6e9e8c3c2e5e4cfcee1"),
            ("3031323334353637383961626364656667", "bdbc9796b9b89392b5b4c4c7eee9c0c3ea"),
        ]
        for (input, expected) in cases {
            let source = Data(hexString: input)
            XCTAssertEqual(
                Pan115Crypto.xor(source, key).hexString, expected,
                "xor(\(input)) 与参考实现不一致")
        }
    }

    // MARK: - rsa_encrypt

    /// 参考实现的填充是**固定 0x02**(不是标准里的随机非零),所以加密结果可复现。
    /// 六个用例覆盖:空、1 字节、普通 JSON、正好 117(单块满)、118(跨块)、234(两块)。
    func testEncryptMatchesReference() {
        let cases: [(String, String)] = [
            ("", "gss8BiTOuTPZ6/P8OXHFi87fPxOuUVzEr8cek9pV7LavJ3JiXqIcPr6JNVtIMg8wOP89zPrG5/q8cHRufHEnfzVoMYPEAQrHob6eQ5zUOQcV8hurvDYP96LTEimD8tMwAVd2SeCOUShASNSSOz4pb3DpZwJUzuCs7P/zjvlQOiM="),
            ("78", "fiv8Miueixy2HunpCbPHscecZ1qA3s+svglbf0/hVDebxBsvfIyzt8s+rEIwKLKbA/5LZ4uY0dlaQFwbvadVxqAbpbFI4X3TuVtlJCsE9og8e2V+wr0h29Fjcc2VchTQQ2hfPlJ3GFY9iNw4fnnS5UTwI8CkESHWHFOFM5X5/EU="),
            ("7b227069636b636f6465223a22616263227d", "Yh9WU41Eh1K3HugApZGRhPhHYaf1qR/J8G/Lmlz7KXV9OhleWQZMdaIX4MxGZUjJBbHjOxSEzRk3EV8sMREIcin//zKOpbYmn78rkZkT1wwMHR8BQ4v5E5jL7eLMhcO+DpgjQ86V54m0dEi5zZaKV9i2JMsHbvBshK6RhjwQKCQ="),
            (String(repeating: "41", count: 117), "AXDjO2TfjZ/90vq6evm/eu3JTcrkKvjW6zYATLDDIL0ED7VWB80jgeWX8SLAvSydrP4cyq/QMik1x2vA/ESvmHnB2GgC2xZFicDX7Sh9B6k2hx0ApHiFS77FACmta3+r6ulvHB85MZi0qAql8qFQILznPKtwcqs/QVvmBxZswdgZFccTXcrrCKiZ6ZB2QRSpj2HWwCaesDN+HrEjTpcIe1hljbAhVvGpoWea2MskHpqUjgVvoH0+DcXI7mFYABFC2ccFKbP08ZAOdhJKmREGM82BT2+durxqbL6o14o/e+Z8q2TdbGb3N9XVONz86ri1tdiNdxiqGoaOQ6MT8DW0jg=="),
            (String(repeating: "42", count: 118), "W8z7Nvz0yvAXnzSlTzZosupHZ9yeZwrvQCRJe3mdc24okxlPoQxnJmSO9fVBDpn3Q1mdwKwI2s9PGTxb7j1cqq8ti8188pF//ggACR7oRB8xnfH1pmgLgE4+/OhHd7VnmTaCKbMTOU6CN1Bdl1HnfYMyaAdYCqO2x9BS6W47pveF3Q62bQvrBIkoD3c4HDJ4V7HXQ9AqWMcIVVmuvyto6/fDElh/kZNnlLhYtJxc16oLkyghHkC6I5gfzKF/THXOgY1OtCGp2D+s3WT9XkSsRm4Tn5En9ka3JJX3S6mdVm3vxZkCSiksu81zinUl/xsN4yqcgDGLpfw9vff/YRsmsw=="),
            (String(repeating: "43", count: 234), "VXEWjw5IQlLlIOLLDnW96MyYOuSZOdBZX37PUjXh53SVMMXqj2i9GFrsntM3t/PanES/y9hOddHn1ajc84h5CKHFOAdioln4tavdANDbJJ53uIlBlM6V6yceNWH3e55pV+Lmhh3nsHce1AOhsNx/6pWGcof0SSC+Us1OuNySstRi1hNPCmdeaQ2g8V4keyNkAzoo8+X8AHDzdDaQm2UiVMhlnofkLs0BrYsjFiW/6wsj+Y9ttqgoUi9d4bcaoxoxjfCvWlLvQUPGigwVnYbOP2jtpiCQFIl4VNWRfaxtC6ehSIGKbWUW/kLQBouXrAYEJTi1FBQOCe+ceX9RMZCXGHCHjUj0skWIPL7OSg3PwWl35VznfrQ8BAZibqO+F6inMOdIpuHSO0E1vqu7m4TVo5GKOpdXxW8nJWwY67yXb0ZN9EmI47+fRlt88obyx/WDOxq9adcs5qHTFGPorBYWqL93MfxrhYJB9/88PeJXYgF2Cka7RksdY6KCade8FQ+X"),
        ]
        for (input, expected) in cases {
            let plain = Data(hexString: input)
            // 参考实现里 rand_key 取默认值(全 0)时用固定 4 字节 key,对应 `encode` 的
            // `derivedKey` 分支;这里直接调底层,绕开随机 key。
            let xorKey = Pan115Crypto.rsaGenKey(Data(repeating: 0, count: 16), skLen: 4)
            let reversed = Data(Pan115Crypto.xor(plain, xorKey).reversed())
            let gKeyL = Data([0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46])
            let body = Data(repeating: 0, count: 16) + Pan115Crypto.xor(reversed, gKeyL)
            let cipher = Pan115Crypto.rsaEncryptWithPubkey(body).base64EncodedString()
            XCTAssertEqual(cipher, expected, "rsa_encrypt(\(input)) 与参考实现不一致")
        }
    }

    /// 空输入也要出**一块** 128 字节:参考实现的分块循环对 0 长度也跑一次。
    func testEmptyInputStillProducesOneBlock() {
        let cipher = Pan115Crypto.rsaEncryptWithPubkey(Data(repeating: 0, count: 16))
        XCTAssertEqual(cipher.count, 128)
    }

    /// 分块数量:117 字节明文 → 1 块(填充进同一块),118 → 2 块,234 → 2 块。
    /// 这里验的是 `rsaEncryptWithPubkey` 本身,所以输入是 16+117 这种「加完前缀的长度」。
    func testBlockSplitting() {
        XCTAssertEqual(Pan115Crypto.rsaEncryptWithPubkey(Data(repeating: 1, count: 16 + 117)).count, 256)
        XCTAssertEqual(Pan115Crypto.rsaEncryptWithPubkey(Data(repeating: 1, count: 16 + 118)).count, 256)
        XCTAssertEqual(Pan115Crypto.rsaEncryptWithPubkey(Data(repeating: 1, count: 16 + 234)).count, 384)
    }

    // MARK: - decode 的后处理

    /// 拿参考实现生成的中间块(RSA 公钥变换的输出)喂 `decodeBody`,逐字节比对。
    /// 三条向量覆盖不同的 `rand_key`。
    func testDecodeBodyMatchesReference() throws {
        let cases: [(key: String, block: String, plain: String)] = [
            ("2c07aab38a03c4adfabb625fb2452724",
             "921570bb0186c15f4839f19c12d9a8f4ba0545916c73fc81b160efb838ce049193ad1cdbfdf1a59ade09a1f49f55c22a1ef5fe292ae61a564a2c407164bc7e30f5cf54b6763390d84053d24887993e7542a909776ba16340daee448911f548ed5422954aa93568620a18ab5b3e94f6de",
             "b7a787a25a60a10ad00523b723c431c8ec834c113b29f8c42932b2f776c21042c7538f99218340dcd95b8a760439d9eb592faff8708b954ae477f03440afe6822b09ec9f46cc1fc0f3f4e261dad714932369d826d1be732d8037ca6c232813a4"),
            ("808bd983846843d2366764e9955d7781",
             "23696e79434055372215d3eecda53fdebfd912a8dbbd2c92035897f24c8382d05246ef5a4e4567b8b0eb4a9feca0c583975cf3b9adc44497e20fb182985891eb137aa0cd04d21f8863c6f28d42ff40c497555209b199c6067746fd3cea381df295aefad3f8a90b9fb3ed7483c1775fa7",
             "10a06f438687b9c53fe8fc476405b617f7ee6c9c9c1e13c8b13981330ca101e164a3aafd3a0ddee18dec86726d432fac5c6e401a87425b9437a791120e0c44158636f49a3fa9be0f0f985dcc5f1c12247061d6f34568408197dfe9ad08f18c00"),
            ("c6e36cf730f2d07f57444df9ee9dfbc7",
             "001483b24be63817b7254cc9aeac20a1038a9a66f7fe62726dd9713fdaf5b5170dd09d820d65fa177e653af8c14bca590c4802cb58b6635a9dc8fb0bd46b00fc5da4391d12157fdcd827fa93f7d0a88436e549daa1c0f0ab25046d0149d3e8d1cbf0c3b87f6b0cdb18dee884a85d5e6e",
             "70d020e367d04502fa103c57a64d8d8032d048532071530db57ebdea39717e2ca5b487df8d745a933f478e083c25f375e28e169fe8c353877b7fe170d58c3547baf2d0dbd92632560974184661a54b1736a9a2f221ffa426915a65ed4786dd2b"),
        ]
        for item in cases {
            let decoded = try Pan115Crypto.decodeBody(
                Data(hexString: item.block), key: Data(hexString: item.key))
            XCTAssertEqual(decoded.hexString, item.plain, "decodeBody 与参考实现不一致")
        }
    }

    /// 块不足 16 字节时明确抛错(拿不到 rand_key),⛔ 不要硬解。
    func testDecodeBodyRejectsShortBlock() {
        XCTAssertThrowsError(
            try Pan115Crypto.decodeBody(Data(repeating: 1, count: 15), key: Data(repeating: 0, count: 16)))
    }

    // MARK: - RSA 公钥变换

    /// `rsaDecryptWithPubkey` 对参考实现生成的密文逐字节比对。
    ///
    /// ⚠️ 这一对**不是**互逆的:两侧都对 RSA 做公钥指数(`pow(·, 65537, n)`),
    /// 加密只是「填充 + 指数」,解密是「指数 + 剥填充」,没有私钥参与。
    /// 所以这里不能写「自加密自解」,只能用参考实现给的密文当期望值。
    func testRSADecryptMatchesReference() throws {
        let cipherHex = "0707070707070707070707070707070707070707070707070707070707070707"
            + "0707070707070707070707070707070707070707070707070707070707070707"
            + "0707070707070707070707070707070707070707070707070707070707070707"
            + "0707070707070707070707070707070707070707070707070707070707070707"
            + "0707070707070707070707070707070707070707070707070707070707070707"
            + "0707070707070707070707070707070707070707070707070707070707070707"
            + "0707070707070707070707070707070707070707070707070707070707070707"
            + "0707070707070707070707070707070707070707070707070707070707070707"
        let expected = "6f06ddbdb5b3bb6bf14f1e9e5626bd4459fcc951924b455e65b4331ae3ef6c87"
            + "d16b5ab8a362219731f98223d973e0c89bcbd68bbf6c3172d770c9d7628716ef"
            + "7f25baa74fb51469dc1b083223e4d3e6f8266c21914dd11dfa79"
            + "6f06ddbdb5b3bb6bf14f1e9e5626bd4459fcc951924b455e65b4331ae3ef6c87"
            + "d16b5ab8a362219731f98223d973e0c89bcbd68bbf6c3172d770c9d7628716ef"
            + "7f25baa74fb51469dc1b083223e4d3e6f8266c21914dd11dfa79"
        let decoded = try Pan115Crypto.rsaDecryptWithPubkey(Data(hexString: cipherHex))
        XCTAssertEqual(decoded.hexString, expected, "rsaDecryptWithPubkey 与参考实现不一致")
    }

    /// 单块密文也验一条,确认剥填充只作用于块内。
    func testRSADecryptSingleBlock() throws {
        let decoded = try Pan115Crypto.rsaDecryptWithPubkey(Data(repeating: 0x07, count: 128))
        XCTAssertEqual(
            decoded.hexString,
            "6f06ddbdb5b3bb6bf14f1e9e5626bd4459fcc951924b455e65b4331ae3ef6c87"
                + "d16b5ab8a362219731f98223d973e0c89bcbd68bbf6c3172d770c9d7628716ef"
                + "7f25baa74fb51469dc1b083223e4d3e6f8266c21914dd11dfa79")
    }

    /// 密文长度不是 128 的整数倍时明确抛错,⛔ 不要按最长前缀硬解。
    func testTruncatedCipherThrows() {
        let key = Pan115Crypto.generateKey()
        XCTAssertThrowsError(
            try Pan115Crypto.decode(cipherData: Data(repeating: 0x01, count: 100), key: key))
    }

    // MARK: - key

    /// 每次都不一样,且长度 16。
    func testGeneratedKeyIsRandom() {
        let first = Pan115Crypto.generateKey()
        let second = Pan115Crypto.generateKey()
        XCTAssertEqual(first.count, 16)
        XCTAssertEqual(second.count, 16)
        XCTAssertNotEqual(first, second)
    }
}

// MARK: - 测试辅助

extension Data {

    /// `"7b22706963…"` → 字节。只在测试里用,⛔ 不进 App target。
    init(hexString: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex)
                ?? hexString.endIndex
            bytes.append(UInt8(hexString[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
