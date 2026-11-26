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

    /// The play-record toggle applies to the analysis layout, and only
    /// matters when the file records some play.
    var offersPlayRecords: Bool { layout.rawValue == "analysis" && file?.hasPlay == true }

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

    /// Where each board sits in `pdf`, from the click map the renderer embeds
    /// in it (Contract 5). Several per board on bidding sheets.
    private(set) var figures: [BoardFigure] = []
    /// One entry per board, at its first appearance: the board index.
    var boards: [BoardFigure] {
        var seen = Set<Int>()
        return figures.filter { seen.insert($0.board).inserted }
    }
    var isShowingBoards = false

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
    /// page it is already on still moves it there. With a `rect`, the view
    /// scrolls to that part of the page rather than its top.
    struct PageRequest: Equatable {
        let index: Int
        var rect: CGRect?
        let id = UUID()
    }
    private(set) var pageRequest: PageRequest?
    private(set) var thumbnails: ThumbnailLoader?

    /// The view showing `pdf`, for the menu commands PDFView already
    /// implements: zoom, page stepping, the selection. Not observed; the
    /// commands only reach through it.
    @ObservationIgnored weak var pdfView: PDFView?
    /// True when the page view is up (not the grid), so page and zoom
    /// commands have something to act on.
    var canNavigate: Bool { pdf != nil && viewMode == .pages }

    func zoomIn() { pdfView?.zoomIn(nil) }
    func zoomOut() { pdfView?.zoomOut(nil) }
    func actualSize() { pdfView?.scaleFactor = 1 }
    /// Back to fit-to-width, refitting as the window resizes (setting
    /// `scaleFactor` turns `autoScales` off; toggling it refits now).
    func zoomToFit() {
        pdfView?.autoScales = false
        pdfView?.autoScales = true
    }
    func nextPage() { pdfView?.goToNextPage(nil) }
    func previousPage() { pdfView?.goToPreviousPage(nil) }
    func firstPage() { pdfView?.goToFirstPage(nil) }
    func lastPage() { pdfView?.goToLastPage(nil) }

    /// Leave the grid for `index`.
    func show(page index: Int) {
        pageRequest = PageRequest(index: index)
        viewMode = .pages
    }

    /// Go to a board where the page draws it.
    func show(_ figure: BoardFigure) {
        pageRequest = PageRequest(index: figure.page, rect: figure.rect)
        viewMode = .pages
        isShowingBoards = false
        sourceRecord = figure.board - 1
    }

    // MARK: View Source

    /// The file as opened, beside the PDF, with the board in view highlighted.
    var isShowingSource = false
    /// The board's record highlighted in the source: an index into
    /// `file.sourceRecords`, which is the board's index in the PDF (the click
    /// map's `board`, less one).
    private(set) var sourceRecord: Int?

    /// A click in the source: go to that board in the PDF.
    func selectSourceRecord(_ index: Int) {
        sourceRecord = index
        if let figure = figures.first(where: { $0.board == index + 1 }) {
            pageRequest = PageRequest(index: figure.page, rect: figure.rect)
            viewMode = .pages
        }
    }

    /// A click on the PDF: highlight the board drawn there, if any. `point`
    /// is in page space, as the figures are.
    func pdfClicked(page: Int, at point: CGPoint) {
        guard isShowingSource,
              let figure = figures.first(where: { $0.page == page && $0.rect.contains(point) })
        else { return }
        sourceRecord = figure.board - 1
    }

    // MARK: Search

    var isSearching = false
    /// Bumped by `beginSearch`; the search field takes the keyboard on each
    /// change, including when it is already open.
    private(set) var searchFocusRequest = 0

    /// Open the search field (or return to it) ready to type: ⌘F.
    func beginSearch() {
        isSearching = true
        searchFocusRequest += 1
    }
    var searchText = "" { didSet { if searchText != oldValue { scheduleSearch() } } }
    private var searchTask: Task<Void, Never>?
    /// Every match in the document, in reading order. PDFView highlights them
    /// all and moves to `searchIndex`.
    private(set) var searchResults: [PDFSelection] = []
    private(set) var searchIndex = 0
    /// Bumped on every new result set or move, so PDFView acts on each one.
    private(set) var searchGeneration = 0
    /// Matches per page (0-based), for the grid's badges. Search leaves the
    /// view as it is: in the grid, the badges show where the matches are,
    /// and next/previous moves through them there.
    private(set) var matchCounts: [Int: Int] = [:]
    /// The page of the match being shown.
    var matchPage: Int? {
        searchResults.indices.contains(searchIndex) ? page(of: searchResults[searchIndex]) : nil
    }

    func nextMatch() { step(by: 1) }
    func previousMatch() { step(by: -1) }

    /// Find the text selected in the PDF (⌘E).
    func useSelectionForFind() {
        guard let text = pdfView?.currentSelection?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return }
        beginSearch()
        searchText = text
    }

    func endSearch() {
        isSearching = false
        searchText = ""
    }

    private func step(by delta: Int) {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + delta + searchResults.count) % searchResults.count
        searchGeneration += 1
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
        var counts: [Int: Int] = [:]
        for match in searchResults {
            if let page = page(of: match) { counts[page, default: 0] += 1 }
        }
        matchCounts = counts
        searchGeneration += 1
    }

    private func page(of match: PDFSelection) -> Int? {
        match.pages.first.flatMap { pdf?.index(for: $0) }
    }

    // MARK: Solve

    /// Where a solve has got, while one runs.
    private(set) var solveProgress: SolveProgress?
    var isSolving: Bool { solveTask != nil }
    /// What the last solve did, or why it stopped: shown in the banner until
    /// dismissed or the file changes.
    private(set) var solveOutcome: SolveOutcome?
    /// The analysis is in the PBN the app shows but not in any file yet, so
    /// Save PBN is worth offering.
    private(set) var hasUnsavedAnalysis = false
    var isExportingPBN = false
    private var solveTask: Task<Void, Never>?
    /// Bumped per solve and when one is dropped, so a solve that ends after
    /// its file was closed or replaced changes nothing.
    private var solveGeneration = 0

    enum SolveOutcome: Equatable {
        case done(SolveReport)
        case failed(String)
    }

    /// Work out each board double dummy, and with `play` what each card
    /// played cost, writing it into the PBN as bridge-solver does. Boards
    /// already solved keep their analysis unless `recalculate`.
    func solve(recalculate: Bool = false) {
        guard let file, solveTask == nil else { return }
        var options = SolveOptions()
        options.play = file.hasPlay
        options.recalculate = recalculate
        solveOutcome = nil
        solveProgress = nil
        let text = file.text
        solveGeneration += 1
        let mine = solveGeneration
        solveTask = Task {
            let result: Result<(pbn: String, report: SolveReport), SolveError>
            do {
                result = .success(try await Solver.solve(text, options: options) { progress in
                    Task { @MainActor in
                        if mine == self.solveGeneration { self.solveProgress = progress }
                    }
                })
            } catch {
                result = .failure(error as? SolveError ?? .failed(error.localizedDescription))
            }
            guard mine == self.solveGeneration else { return }
            self.solveTask = nil
            self.solveProgress = nil
            switch result {
            case .success(let (pbn, report)):
                if report.changedAnything, let solved = try? self.file?.withAnalysis(pbn) {
                    self.file = solved
                    self.hasUnsavedAnalysis = true
                    self.render(keepPage: true)
                    self.renderPreviews()
                }
                self.solveOutcome = .done(report)
            case .failure(.cancelled):
                break
            case .failure(let error):
                self.solveOutcome = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSolve() {
        solveTask?.cancel()
    }

    func dismissSolveOutcome() { solveOutcome = nil }

    /// The PBN as it now stands, for Save PBN.
    var pbnToSave: String? { file?.text }
    var suggestedPBNName: String { "\(file?.stem ?? "Bridge Viewer").pbn" }

    func pbnSaved() { hasUnsavedAnalysis = false }

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
        endSolve()
        error = nil
        sourceRecord = nil
        self.file = file
        previews = [:]
        viewMode = .pages
        render(keepPage: false)
        renderPreviews()
    }

    /// Back to the empty window. Bumping the generations drops any render
    /// still in flight for the closed file.
    func close() {
        endSolve()
        generation += 1
        previewGeneration += 1
        endSearch()
        shareURL.map(Self.discard)
        file = nil
        pdf = nil
        pdfData = nil
        figures = []
        thumbnails = nil
        shareURL = nil
        previews = [:]
        error = nil
        isRendering = false
        isShowingBoards = false
        viewMode = .pages
        currentPage = 0
        sourceRecord = nil
    }

    /// Drop the solve state with the file it was about.
    private func endSolve() {
        solveGeneration += 1
        solveTask?.cancel()
        solveTask = nil
        solveProgress = nil
        solveOutcome = nil
        hasUnsavedAnalysis = false
    }

    /// `keepPage`: the change doesn't move content between pages (circling
    /// options), so stay where the reader is rather than going back to page 1.
    private func render(keepPage: Bool) {
        guard let file else { return }
        generation += 1
        let mine = generation
        let (text, layout, options, source) = (file.text, layout, options, file.name)
        let name = Self.fileName(stem: file.stem, layout: layout)
        isRendering = true
        Task.detached(priority: .userInitiated) {
            // The PDF carries its source and a map of its boards (Contract 5),
            // so a saved or shared copy opens in lesson-stage with tappable
            // boards; the map also drives the board index here.
            let result = Result {
                try Renderer.renderEmbedded(text, layout: layout, options: options, sourceName: source)
            }
            let url = try? result.get().pdf.writeToShareDirectory(named: name)
            await MainActor.run {
                guard mine == self.generation else {
                    url.map(Self.discard)
                    return
                }
                self.isRendering = false
                self.shareURL.map(Self.discard)
                switch result {
                case .success(let rendered):
                    let data = rendered.pdf
                    let page = keepPage ? self.currentPage : 0
                    let pdf = PDFDocument(data: data)
                    pdf?.removeLessonBlockLinks()
                    self.pdf = pdf
                    self.pdfData = data
                    self.figures = rendered.figures
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
                    self.figures = []
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
        if args.contains("-ShowBoards") { isShowingBoards = true }
        if let board = value(after: "-GoToBoard").flatMap(Int.init),
           let figure = boards.first(where: { $0.board == board }) {
            show(figure)
        }
        if let query = value(after: "-Search") {
            try? await Task.sleep(for: .seconds(1))
            beginSearch()
            searchText = query
        }
        // Re-render with the search field focused: the case that once hung
        // UIKit in a first-responder loop.
        if let name = value(after: "-SwitchLayout"), let match = PageLayout.all.first(where: { $0.rawValue == name }) {
            try? await Task.sleep(for: .seconds(2))
            layout = match
            // As a tap in the strip does: the strip folds away too.
            NotificationCenter.default.post(name: .debugCollapseStrip, object: nil)
        }
        // Solve once the PDF is up, logging the outcome for a scripted check.
        if args.contains("-Solve") {
            solve()
            while isSolving { try? await Task.sleep(for: .milliseconds(100)) }
            print("Solve outcome: \(String(describing: solveOutcome)), unsaved: \(hasUnsavedAnalysis)")
        }
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
#if DEBUG
extension Notification.Name {
    static let debugCollapseStrip = Notification.Name("debugCollapseStrip")
}
#endif

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
            o.allPlayRecords = defaults.bool(forKey: "allPlayRecords")
            // By seat unless turned off: it reads better than play order
            o.playBySeat = defaults.object(forKey: "playBySeat") as? Bool ?? true
            return o
        }
        set {
            defaults.set(newValue.circleSureWinners, forKey: "circleSureWinners")
            defaults.set(newValue.circlePromotableWinners, forKey: "circlePromotableWinners")
            defaults.set(newValue.circleLengthWinners, forKey: "circleLengthWinners")
            defaults.set(newValue.allPlayRecords, forKey: "allPlayRecords")
            defaults.set(newValue.playBySeat, forKey: "playBySeat")
        }
    }
}

private extension PDFDocument {
    /// Drop the boards' `lesson-block:` links (Contract 5) from the copy on
    /// screen. They cover each board -- on the analysis layout the whole
    /// page -- and PDFView treats a press on a link as a click: it flashes
    /// the link and never starts a text selection. Saved and shared
    /// bytes come from `pdfData` and keep them.
    func removeLessonBlockLinks() {
        for index in 0..<pageCount {
            guard let page = page(at: index) else { continue }
            for annotation in page.annotations where annotation.url?.scheme == "lesson-block" {
                page.removeAnnotation(annotation)
            }
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
