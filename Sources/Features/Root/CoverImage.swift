import AppKit
import SwiftUI

/// 封面加载：内核返回相对路径 `/api/preview-cover/<hash>`（covers.go 里旧版是把
/// 本地封面取回来内联成 data URI，SwiftUI 直连 127.0.0.1 即可，不必内联）。
///
/// `width/height` 为 nil 时不自带尺寸，交给外部的 aspectRatio/frame 决定（详情弹窗的封面就是这种）。
struct CoverImage: View {
    let url: URL?
    var width: CGFloat?
    var height: CGFloat?
    var cornerRadius: CGFloat = 10
    var mode: ContentMode = .fill

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: mode)
            } else {
                ZStack {
                    FMTheme.fill
                    Image(systemName: "book.closed")
                        .font(FMTheme.Font.sectionSmall)
                        .foregroundStyle(FMTheme.textTertiary)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = try? await HttpClient.shared.image(url)
        }
    }
}
