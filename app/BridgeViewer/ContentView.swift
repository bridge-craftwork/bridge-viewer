import PbnToPdfKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if model.file != nil {
                    DocumentView()
                } else {
                    EmptyState()
                }
            }
            .navigationTitle(model.file?.name ?? "Bridge Viewer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { Toolbar() }
            .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.pbn, .plainText]) { result in
                switch result {
                case .success(let url): model.open(url: url)
                case .failure(let error): model.openError = error.localizedDescription
                }
            }
            .fileExporter(
                isPresented: $model.isExporting,
                document: model.pdfData.map(PDFFile.init),
                contentType: .pdf,
                defaultFilename: model.suggestedFileName
            ) { _ in }
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
        // A .pbn dragged onto the window: from Finder, or from Files in
        // iPad split view.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url: url)
            return true
        }
    }
}

private struct Toolbar: ToolbarContent {
    @Environment(DocumentModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .navigation) {
            Button("Open", systemImage: "folder") { model.isImporting = true }
        }
        if model.pdf != nil {
            ToolbarItem(placement: .primaryAction) {
                Picker("View", selection: $model.viewMode) {
                    Label("Pages", systemImage: "doc.text").tag(DocumentModel.ViewMode.pages)
                    Label("Grid", systemImage: "square.grid.3x3").tag(DocumentModel.ViewMode.grid)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Show one page at a time, or every page as a grid")
            }
        }
        #if os(macOS)
        if model.pdfData != nil {
            ToolbarItem(placement: .primaryAction) {
                Button("Save PDF…", systemImage: "square.and.arrow.down") { model.isExporting = true }
            }
        }
        #endif
        if let url = model.shareURL {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: url)
            }
        }
    }
}

private struct EmptyState: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Open a PBN file", systemImage: "doc.text")
        } description: {
            Text("Choose a layout and get a printable PDF: declarer's plans, bidding sheets, hand records and more.")
        } actions: {
            Button("Open a File…") { model.isImporting = true }
                .buttonStyle(.borderedProminent)
            if let sample = PBNFile.sample() {
                Button("Try a Sample") { model.load(sample) }
            }
        }
    }
}

private struct DocumentView: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            LayoutStrip()
            if model.layout.usesCardArt {
                CirclingOptions(options: $model.options)
            }
            Divider()
            ZStack(alignment: .bottom) {
                // Stays alive under the grid, so leaving the grid without
                // choosing a page returns to the same place.
                PDFKitView(
                    document: model.pdf,
                    request: model.pageRequest,
                    onPageChange: { model.currentPage = $0 },
                    onPinchOut: { withAnimation(.easeInOut(duration: 0.2)) { model.viewMode = .grid } }
                )
                if model.viewMode == .grid, let loader = model.thumbnails {
                    PageGrid(loader: loader)
                        .transition(.opacity.combined(with: .scale(scale: 1.04)))
                }
                if let error = model.error {
                    ContentUnavailableView(
                        "Couldn't render this layout",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                    .background(.background)
                } else if model.isRendering && model.pdf == nil {
                    ProgressView().frame(maxHeight: .infinity)
                } else if model.pageCount > 0 {
                    PageIndicator()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.viewMode)
        }
    }
}

/// "Page 12 of 120". Tapping it opens the grid, which is the fast way to go
/// somewhere else.
private struct PageIndicator: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        Button {
            model.viewMode = model.viewMode == .grid ? .pages : .grid
        } label: {
            Group {
                if model.viewMode == .grid {
                    Text("\(model.pageCount) pages")
                } else {
                    Text("Page \(model.currentPage + 1) of \(model.pageCount)")
                }
            }
            .font(.callout.monospacedDigit())
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: .capsule)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 16)
        .help("Show every page")
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
    let image: CGImage?
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image {
                    Image(page: image, scale: 2).resizable().scaledToFit()
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

/// The rendered bytes, for `fileExporter`.
struct PDFFile: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    let data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
