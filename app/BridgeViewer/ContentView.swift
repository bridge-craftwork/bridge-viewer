import PbnToPdfKit
import SwiftUI

struct ContentView: View {
    @Environment(DocumentModel.self) private var model
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Group {
                if let file = model.file {
                    DocumentView(file: file)
                } else {
                    EmptyState(importing: $importing)
                }
            }
            .navigationTitle(model.file?.name ?? "Bridge Viewer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Open", systemImage: "folder") { importing = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let url = model.shareURL {
                        ShareLink(item: url)
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pbn, .plainText]) { result in
                switch result {
                case .success(let url): model.open(url: url)
                case .failure(let error): model.openError = error.localizedDescription
                }
            }
            .alert(
                "Couldn't open that file",
                isPresented: Binding(
                    get: { model.openError != nil },
                    set: { if !$0 { model.openError = nil } }
                ),
                actions: {},
                message: { Text(model.openError ?? "") }
            )
        }
    }
}

private struct EmptyState: View {
    @Environment(DocumentModel.self) private var model
    @Binding var importing: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Open a PBN file", systemImage: "doc.text")
        } description: {
            Text("Choose a layout and get a printable PDF: declarer's plans, bidding sheets, hand records and more.")
        } actions: {
            Button("Open a File…") { importing = true }
                .buttonStyle(.borderedProminent)
            if let sample = PBNFile.sample() {
                Button("Try a Sample") { model.load(sample) }
            }
        }
    }
}

private struct DocumentView: View {
    @Environment(DocumentModel.self) private var model
    let file: PBNFile

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            LayoutStrip()
            if model.layout.usesCardArt {
                CirclingOptions(options: $model.options)
            }
            Divider()
            ZStack {
                PDFKitView(document: model.pdf)
                if let error = model.error {
                    ContentUnavailableView(
                        "Couldn't render this layout",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    .background(.background)
                } else if model.isRendering && model.pdf == nil {
                    ProgressView()
                }
            }
        }
    }
}

/// A row of first-page thumbnails, one per layout. Tapping one chooses it.
private struct LayoutStrip: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(PageLayout.all) { layout in
                    Button { model.layout = layout } label: {
                        LayoutCard(
                            layout: layout,
                            image: model.previews[layout],
                            selected: model.layout == layout
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.layout == layout ? .isSelected : [])
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}

private struct LayoutCard: View {
    let layout: PageLayout
    let image: UIImage?
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Color.white.overlay(ProgressView())
                }
            }
            .frame(width: 92, height: 119)
            .background(.white)
            .clipShape(.rect(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selected ? Color.accentColor : .secondary.opacity(0.3),
                                  lineWidth: selected ? 3 : 1)
            }
            Text(layout.label)
                .font(.caption)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
                .frame(width: 100)
                .foregroundStyle(selected ? Color.accentColor : .primary)
        }
    }
}

private struct CirclingOptions: View {
    @Binding var options: RenderOptions

    var body: some View {
        HStack(spacing: 8) {
            Text("Circle winners").font(.subheadline).foregroundStyle(.secondary)
            Toggle("Sure", isOn: $options.circleSureWinners).tint(.red)
            Toggle("Promotable", isOn: $options.circlePromotableWinners).tint(.green)
            Toggle("Length", isOn: $options.circleLengthWinners).tint(.blue)
        }
        .toggleStyle(.button)
        .font(.subheadline)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
