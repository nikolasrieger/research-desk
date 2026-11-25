import SwiftUI
import AppKit

enum ImageZoom {
    static func clamped(_ value: CGFloat) -> CGFloat { min(16, max(0.05, value)) }
    static func fit(image: CGSize, viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        return min(max(1, viewport.width - 32) / image.width, max(1, viewport.height - 32) / image.height)
    }
}

struct DeskZoomableImage: View {
    let image: NSImage
    var animated = false
    @State private var scale: CGFloat?
    @GestureState private var pinch: CGFloat = 1
    var body: some View {
        GeometryReader { geometry in
            let viewport = CGSize(width: geometry.size.width, height: max(1, geometry.size.height - 40))
            let fit = ImageZoom.fit(image: image.size, viewport: viewport)
            let base = scale ?? fit
            let current = max(0.01, base * pinch)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { scale = ImageZoom.clamped(base / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                        .help("Zoom out").accessibilityLabel("Zoom out")
                    Text("\(Int(current * 100))%")
                        .font(.system(size: 11, design: .monospaced)).monospacedDigit().frame(minWidth: 45)
                    Button { scale = ImageZoom.clamped(base * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                        .help("Zoom in").accessibilityLabel("Zoom in")
                    Spacer()
                    Button("Fit") { scale = nil }
                    Button("100%") { scale = 1 }
                }.buttonStyle(DeskButtonStyle(compact: true)).padding(.horizontal, 10).frame(height: 40)
                    .foregroundStyle(DeskStyle.accent).background(DeskStyle.sidebar)
                ScrollView([.horizontal, .vertical]) {
                    Group {
                        if animated { DeskAnimatedImage(image: image) }
                        else { Image(nsImage: image).resizable().interpolation(.high) }
                    }
                    .frame(width: max(1, image.size.width * current), height: max(1, image.size.height * current))
                    .padding(16)
                    .frame(minWidth: viewport.width, minHeight: viewport.height)
                }
                .gesture(MagnificationGesture()
                    .updating($pinch) { value, state, _ in state = value }
                    .onEnded { value in scale = ImageZoom.clamped(base * value) })
            }
        }
    }
}
