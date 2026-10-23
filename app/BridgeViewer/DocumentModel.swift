import Observation
import PDFKit
import PbnToPdfKit

/// The open file, the chosen layout, and what they render to.
///
/// Rendering runs off the main actor. A change of file, layout or options
/// starts a new render and cancels interest in the old one: each render
/// carries a generation number, and a result that arrives after a newer
/// request has been made is dropped.
@MainActor @Observable
final class DocumentModel {
    private(set) var file: PBNFile?
    // The layout and circling choices carry over between launches: most
    // people settle on one and use it nearly every time.
    var layout: PageLayout = Saved.layout {
        didSet { if layout != oldValue { Saved.layout = layout; render(keepPage: false) } }
    }
    var options = Saved.options {
        didSet { if options != oldValue { Saved.options = options; render(keepPage: true); renderPreviews() } }
    }

    private(set) var pdf: PDFDocument?
    /// The bytes behind `pdf`, for saving.
    private(set) var pdfData: Data?
    /// The rendered PDF written to a temporary file under a readable name,
    /// for the share sheet.
    private(set) var shareURL: URL?
    private(set) var isRendering = false
    /// Why the current layout didn't render; shown in place of the PDF.
    private(set) var error: String?
    /// Why a file didn't open; shown as an alert, over whatever is open.
    var openError: String?

    /// First-page thumbnails, one per layout, so a layout can be recognised
    /// before it is chosen -- the same idea as the web app's gallery.
    private(set) var previews: [PageLayout: CGImage] = [:]

    // MARK: Navigation

    enum ViewMode { case pages, grid }
    var viewMode = ViewMode.pages
    /// The page PDFView is showing (0-based), as it reports it.
    var currentPage = 0
    var pageCount: Int { pdf?.pageCount ?? 0 }
    /// A jump for PDFView to make. A fresh id per request, so asking for the
    /// page it is already on still moves it there.
    struct PageRequest: Equatable { let index: Int; let id = UUID() }
    private(set) var pageRequest: PageRequest?
    private(set) var thumbnails: ThumbnailLoader?

    /// Leave the grid for `index`.
    func show(page index: Int) {
        pageRequest = PageRequest(index: index)
        viewMode = .pages
    }

    // MARK: Search

    var isSearching = false
    var searchText = "" { didSet { if searchText != oldValue { scheduleSearch() } } }
    private var searchTask: Task<Void, Never>?
    /// Every match in the document, in reading order. PDFView highlights them
    /// all and moves to `searchIndex`.
    private(set) var searchResults: [PDFSelection] = []
    private(set) var searchIndex = 0
    /// Bumped on every new result set or move, so PDFView acts on each one.
    private(set) var searchGeneration = 0

    func nextMatch() { step(by: 1) }
    func previousMatch() { step(by: -1) }

    func endSearch() {
        isSearching = false
        searchText = ""
    }

    private func step(by delta: Int) {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + delta + searchResults.count) % searchResults.count
        searchGeneration += 1
        viewMode = .pages
    }

    /// Search once typing pauses: a long lesson is a lot of text to scan per
    /// keystroke.
    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            runSearch()
        }
    }

    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty || pdf == nil {
            searchResults = []
        } else {
            searchResults = pdf?.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive]) ?? []
        }
        // Start from the reader's page rather than the top of the document.
        searchIndex = searchResults.firstIndex { selection in
            selection.pages.first.flatMap { pdf?.index(for: $0) }.map { $0 >= currentPage } ?? false
        } ?? 0
        searchGeneration += 1
        if !searchResults.isEmpty { viewMode = .pages }
    }

    // MARK: Menu and toolbar requests (the Mac menu bar reaches them here)

    var isImporting = false
    var isExporting = false

    private var generation = 0
    private var previewGeneration = 0

    func open(url: URL) {
        do {
            load(try PBNFile.read(url))
        } catch {
            openError = error.localizedDescription
        }
    }

    func load(_ file: PBNFile) {
        error = nil
        self.file = file
        previews = [:]
        viewMode = .pages
        render(keepPage: false)
        renderPreviews()
    }

    /// `keepPage`: the change doesn't move content between pages (circling
    /// options), so stay where the reader is rather than going back to page 1.
    private func render(keepPage: Bool) {
        guard let file else { return }
        generation += 1
        let mine = generation
        let (text, layout, options) = (file.text, layout, options)
        let name = Self.fileName(stem: file.stem, layout: layout)
        isRendering = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try Renderer.render(text, layout: layout, options: options) }
            let url = try? result.get().writeToShareDirectory(named: name)
            await MainActor.run {
                guard mine == self.generation else {
                    url.map(Self.discard)
                    return
                }
                self.isRendering = false
                self.shareURL.map(Self.discard)
                switch result {
                case .success(let data):
                    let page = keepPage ? self.currentPage : 0
                    self.pdf = PDFDocument(data: data)
                    self.pdfData = data
                    self.thumbnails = ThumbnailLoader(data: data)
                    self.shareURL = url
                    self.error = nil
                    self.currentPage = min(page, max(self.pageCount - 1, 0))
                    self.pageRequest = PageRequest(index: self.currentPage)
                    // Matches belong to the old document; find them again.
                    self.runSearch()
                case .failure(let error):
                    self.pdf = nil
                    self.searchResults = []
                    self.pdfData = nil
                    self.thumbnails = nil
                    self.shareURL = nil
                    self.error = error.localizedDescription
                    self.viewMode = .pages
                }
            }
        }
    }

    private func renderPreviews() {
        guard let file else { return }
        previewGeneration += 1
        let mine = previewGeneration
        let (text, options) = (file.text, options)
        Task.detached(priority: .utility) {
            for layout in PageLayout.all {
                guard let data = try? Renderer.preview(text, layout: layout, options: options),
                      let page = PDFDocument(data: data)?.page(at: 0),
                      let image = page.cgThumbnail(fitting: CGSize(width: 120, height: 120), scale: 2)
                else { continue }
                await MainActor.run {
                    if mine == self.previewGeneration { self.previews[layout] = image }
                }
            }
        }
    }

    /// Remove a superseded share file and the directory made for it.
    private static func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    static func fileName(stem: String, layout: PageLayout) -> String {
        let raw = "\(stem) - \(layout.label).pdf"
        return raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    #if DEBUG
    func applyDebugArguments(_ args: [String]) async {
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        if let name = value(after: "-Layout"), let match = PageLayout.all.first(where: { $0.rawValue == name }) {
            layout = match
        }
        if let path = value(after: "-LoadFile") {
            open(url: URL(fileURLWithPath: path))
        } else if args.contains("-LoadSample"), let sample = PBNFile.sample() {
            load(sample)
        }
        while pdf == nil && file != nil { try? await Task.sleep(for: .milliseconds(100)) }
        if args.contains("-ShowGrid") { viewMode = .grid }
        if let query = value(after: "-Search") {
            try? await Task.sleep(for: .seconds(1))
            isSearching = true
            searchText = query
        }
        // Re-render with the search field focused: the case that once hung
        // UIKit in a first-responder loop.
        if args.contains("-ToggleCircling") {
            try? await Task.sleep(for: .seconds(2))
            options.circleSureWinners.toggle()
        }
    }
    #endif

    var suggestedFileName: String {
        file.map { Self.fileName(stem: $0.stem, layout: layout) } ?? "Bridge Viewer.pdf"
    }
}

/// UserDefaults for the choices above. Board selection is per file, so it
/// isn't kept.
private enum Saved {
    private static let defaults = UserDefaults.standard

    static var layout: PageLayout {
        get {
            defaults.string(forKey: "layout")
                .flatMap { name in PageLayout.all.first { $0.rawValue == name } } ?? PageLayout.all[0]
        }
        set { defaults.set(newValue.rawValue, forKey: "layout") }
    }

    static var options: RenderOptions {
        get {
            var o = RenderOptions()
            o.circleSureWinners = defaults.bool(forKey: "circleSureWinners")
            o.circlePromotableWinners = defaults.bool(forKey: "circlePromotableWinners")
            o.circleLengthWinners = defaults.bool(forKey: "circleLengthWinners")
            return o
        }
        set {
            defaults.set(newValue.circleSureWinners, forKey: "circleSureWinners")
            defaults.set(newValue.circlePromotableWinners, forKey: "circlePromotableWinners")
            defaults.set(newValue.circleLengthWinners, forKey: "circleLengthWinners")
        }
    }
}

private extension Data {
    /// Write under `name` in a fresh temporary directory, so two renders with
    /// the same name never collide and the share sheet shows the real name.
    func writeToShareDirectory(named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try write(to: url)
        return url
    }
}
