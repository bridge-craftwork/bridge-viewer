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
            .fileImporter(isPresented: $model.isImporting, allowedContentTypes: UTType.pbnFiles) { result in
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
        if !model.boards.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button("Boards", systemImage: "list.number") { model.isShowingBoards = true }
                    .help("Go to a board")
                    .popover(isPresented: $model.isShowingBoards) {
                        BoardIndex()
                            .frame(minWidth: 240, idealHeight: 420)
                            .presentationDetents([.medium, .large])
                    }
            }
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

/// Every board in the PDF, in reading order, from the click map the renderer
/// embeds (Contract 5). Choosing one goes to it where the page draws it.
private struct BoardIndex: View {
    @Environment(DocumentModel.self) private var model

    var body: some View {
        List(model.boards) { figure in
            Button { model.show(figure) } label: {
                HStack {
                    Text("Board \(figure.label)")
                    Spacer()
                    Text("Page \(figure.page + 1)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

    /// Most people use one layout nearly always, so the strip of every
    /// layout stays folded away behind the bar until asked for.
    @AppStorage("layoutStripExpanded") private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            LayoutBar(expanded: $expanded)
            if expanded {
                LayoutStrip {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded = false }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Divider()
            ZStack(alignment: .bottom) {
                // Stays alive under the grid, so leaving the grid without
                // choosing a page returns to the same place.
                PDFKitView(
                    document: model.pdf,
                    request: model.pageRequest,
                    search: (model.searchResults, model.searchIndex, model.searchGeneration),
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
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugCollapseStrip)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { expanded = false }
        }
        #endif
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

/// A row of first-page thumbnails, one per layout. Tapping one chooses it
/// and folds the strip away.
private struct LayoutStrip: View {
    @Environment(DocumentModel.self) private var model
    let onPick: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(PageLayout.all) { layout in
                    Button {
                        model.layout = layout
                        onPick()
                    } label: {
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

/// One slim row: the current layout, which opens the strip of all of them,
/// and the circling toggles when the layout draws cards.
private struct LayoutBar: View {
    @Environment(DocumentModel.self) private var model
    @Binding var expanded: Bool
    /// The bar's own width, measured, to decide whether one row fits.
    @State private var width: CGFloat = 0

    /// Stack the circling toggles under the rest when one row won't hold
    /// everything: the layout name, search (wide while open), the toggles.
    private var stacked: Bool {
        guard model.layout.usesCardArt else { return false }
        let needed: CGFloat = model.isSearching ? 1080 : 780
        return width > 0 && width < needed
    }

    var body: some View {
        @Bindable var model = model
        // Side by side where there's room, stacked where there isn't.
        // Not ViewThatFits: it keeps hidden copies of these buttons, and with
        // those in the hierarchy PDFView's next document swap sent UIKit's
        // first-responder promotion into an endless loop -- the app hung on
        // every re-render.
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 16) {
                        layoutButton
                        SearchControl()
                    }
                    if model.layout.usesCardArt { CirclingToggles(options: $model.options) }
                }
            } else {
                HStack(spacing: 16) {
                    layoutButton
                    SearchControl()
                    Spacer(minLength: 0)
                    if model.layout.usesCardArt { CirclingToggles(options: $model.options) }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(.bar)
    }

    private var layoutButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                if let image = model.previews[model.layout] {
                    Image(page: image, scale: 2).resizable().scaledToFit()
                        .frame(height: 30)
                        .background(.white)
                        .clipShape(.rect(cornerRadius: 2))
                        .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(.secondary.opacity(0.3)) }
                }
                Text(model.layout.label).fontWeight(.medium)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(expanded ? "Hide the layouts" : "Choose another layout")
        .accessibilityLabel("Layout: \(model.layout.label)")
        .accessibilityHint(expanded ? "Hides the layouts" : "Shows every layout")
    }
}

/// A magnifying glass that opens into a search field, the match count
/// ("3 of 12"), and previous/next. Return goes to the next match.
private struct SearchControl: View {
    @Environment(DocumentModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        if model.isSearching {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 160)
                    .focused($focused)
                    .onSubmit { model.nextMatch(); focused = true }
                    .onKeyPress(.escape) { model.endSearch(); return .handled }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                if !model.searchText.isEmpty {
                    Text(countLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Button("Previous", systemImage: "chevron.up", action: model.previousMatch)
                    .disabled(model.searchResults.isEmpty)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Next", systemImage: "chevron.down", action: model.nextMatch)
                    .disabled(model.searchResults.isEmpty)
                    .keyboardShortcut("g", modifiers: .command)
                Button("Done", systemImage: "xmark.circle.fill", action: model.endSearch)
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.fill.tertiary, in: .capsule)
            .fixedSize()
            .onAppear { focused = true }
        } else {
            Button("Search", systemImage: "magnifyingglass") { model.isSearching = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Find text in the PDF")
        }
    }

    private var countLabel: String {
        model.searchResults.isEmpty
            ? "Not found"
            : "\(model.searchIndex + 1) of \(model.searchResults.count)"
    }
}

private struct CirclingToggles: View {
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
        .fixedSize()
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
