import SwiftUI

/// Every page as a thumbnail, for getting around a long document fast.
///
/// Pinch to change how many pages fit across; pinching in at the largest
/// size goes back to reading. Tap a page to read it. Opens scrolled to the
/// page being read.
struct PageGrid: View {
    @Environment(DocumentModel.self) private var model
    let loader: ThumbnailLoader

    /// Thumbnail width in points, persisted so the grid opens as it was left.
    @AppStorage("gridCellWidth") private var cellWidth: Double = 160
    @GestureState private var pinch: CGFloat = 1

    private static let widths: ClosedRange<Double> = 90...420
    private var liveWidth: CGFloat {
        CGFloat(min(max(cellWidth * pinch, Self.widths.lowerBound), Self.widths.upperBound))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: liveWidth, maximum: liveWidth * 1.4), spacing: 16)],
                    spacing: 20
                ) {
                    ForEach(0..<model.pageCount, id: \.self) { index in
                        Button { model.show(page: index) } label: {
                            PageThumbnail(
                                loader: loader, index: index, width: liveWidth,
                                current: index == model.currentPage
                            )
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding()
            }
            .onAppear { proxy.scrollTo(model.currentPage, anchor: .center) }
        }
        .background(.background.secondary)
        .simultaneousGesture(
            MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in
                    let atLargest = cellWidth >= Self.widths.upperBound - 1
                    if atLargest && value.magnification > 1.15 {
                        model.show(page: model.currentPage)
                    } else {
                        cellWidth = min(max(cellWidth * value.magnification, Self.widths.lowerBound),
                                        Self.widths.upperBound)
                    }
                }
        )
    }
}

private struct PageThumbnail: View {
    let loader: ThumbnailLoader
    let index: Int
    let width: CGFloat
    let current: Bool

    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image {
                    Image(page: image, scale: scale).resizable().scaledToFit()
                } else {
                    // Letter proportions until the page arrives, so the grid
                    // doesn't reflow as thumbnails land.
                    Color.white.aspectRatio(8.5 / 11, contentMode: .fit)
                }
            }
            .background(.white)
            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            .overlay {
                if current {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(current ? Color.accentColor : .secondary)
        }
        .frame(maxWidth: .infinity)
        // Bucketed widths in the loader mean a pinch re-requests rarely.
        .task(id: Int(width / 80)) {
            image = await loader.thumbnail(page: index, width: width, scale: scale)
        }
        .accessibilityLabel("Page \(index + 1)")
    }
}
