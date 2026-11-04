import SwiftUI

/// 品牌标记有自带配色,⛔ 再套 tint 会把官方配色盖掉。`size` 为标记宽度。
struct SourceBrandMark: View {
    let brand: SourceBrand
    var size: CGFloat

    var body: some View {
        switch brand {
        case .baiduPan:
            BaiduPanLogoMark(size: size)
        case .pan115:
            Pan115LogoMark(size: size)
        }
    }
}
