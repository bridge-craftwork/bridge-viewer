import PDFKit
import SwiftUI

/// PDFKit's viewer: native scrolling and zoom, which is what the web app's
/// iframe could not give an iPad.
///
/// Reports the page on screen, follows `request` to jump to a page, and turns
/// a pinch *out* past fit-to-width into `onPinchOut` -- the way into the page
/// grid, since PDFView itself stops at one column.
struct PDFKitView {
    let document: PDFDocument?
    let request: DocumentModel.PageRequest?
    /// Matches to highlight, the one to show, and a generation that changes
    /// with either.
    let search: (results: [PDFSelection], index: Int, generation: Int)
    let onPageChange: (Int) -> Void
    let onPinchOut: () -> Void
    /// Handed the view once it exists, for the menu commands.
    var onCreate: (PDFView) -> Void = { _ in }
    /// A click or tap on a page: its index, and the point in page space.
    var onClick: (Int, CGPoint) -> Void = { _, _ in }

    final class Coordinator: NSObject {
        var parent: PDFKitView
        var lastRequest: DocumentModel.PageRequest?
        var lastSearch = 0
        /// One pinch opens the grid once, however long it goes on.
        var pinchFired = false

        init(_ parent: PDFKitView) { self.parent = parent }

        @objc func pageChanged(_ note: Notification) {
            guard let view = note.object as? PDFView,
                  let page = view.currentPage,
                  let index = view.document?.index(for: page)
            else { return }
            parent.onPageChange(index)
        }

        /// Report a click at `point`, in the view's own coordinates.
        func clicked(_ view: PDFView, at point: CGPoint) {
            guard let page = view.page(for: point, nearest: false),
                  let index = view.document?.index(for: page)
            else { return }
            parent.onClick(index, view.convert(point, to: page))
        }

        /// True when the view is zoomed out as far as PDFView goes.
        func atFit(_ view: PDFView) -> Bool {
            view.scaleFactor <= view.scaleFactorForSizeToFit * 1.02
        }

        /// `scale` is the pinch so far: 1 at the start, below 1 pinching out.
        func pinched(_ view: PDFView, scale: CGFloat, ended: Bool) {
            if ended { pinchFired = false; return }
            guard !pinchFired, atFit(view), scale < 0.8 else { return }
            pinchFired = true
            parent.onPinchOut()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }


    fileprivate func configure(_ view: PDFView, _ coordinator: Coordinator) {
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.delegate = coordinator
        onCreate(view)
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged, object: view)
    }

    fileprivate func update(_ view: PDFView, _ coordinator: Coordinator) {
        coordinator.parent = self
        if view.document !== document {
            view.document = document
            // Refit the new document's width. Not by setting scaleFactor:
            // that switches autoScales off, and the view then stops refitting
            // when it is resized (the layout strip folding away).
            view.autoScales = false
            view.autoScales = true
            // A swapped-in document can sit undrawn until something forces a
            // layout -- on the iPad a layout change showed nothing until the
            // next zoom. Lay it out now, and again once SwiftUI has settled
            // the view's size for this update.
            view.layoutDocumentView()
            let page = request.flatMap { document?.page(at: $0.index) }
            DispatchQueue.main.async { [weak view] in
                guard let view, view.document === document else { return }
                view.layoutDocumentView()
                if let page { view.go(to: page) }
            }
        }
        if let request, request != coordinator.lastRequest,
           let page = document?.page(at: request.index) {
            coordinator.lastRequest = request
            if let rect = request.rect {
                view.go(to: rect, on: page)
            } else {
                view.go(to: page)
            }
        }
        if search.generation != coordinator.lastSearch {
            coordinator.lastSearch = search.generation
            for match in search.results { match.color = .systemYellow.withAlphaComponent(0.5) }
            view.highlightedSelections = search.results.isEmpty ? nil : search.results
            if search.results.indices.contains(search.index) {
                let match = search.results[search.index]
                view.setCurrentSelection(match, animate: true)
                view.go(to: match)
            } else {
                view.clearSelection()
            }
        }
    }
}

#if os(macOS)
extension PDFKitView: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView {
        let view = PinchablePDFView()
        view.coordinator = context.coordinator
        view.backgroundColor = .windowBackgroundColor
        configure(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) { update(view, context.coordinator) }
}

/// A trackpad pinch reaches the view as magnify events, which PDFView uses to
/// zoom; watch them on the way through rather than competing for them.
private final class PinchablePDFView: PDFView {
    weak var coordinator: PDFKitView.Coordinator?
    private var total: CGFloat = 0
    private let place = PlaceKeeper()

    /// Keep the reader's place when the width changes (View Source opening
    /// or closing): the refit to the new width otherwise leaves the scroll
    /// offset where it was, on a page now drawn larger or smaller.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanges = newSize.width != frame.width
        if widthChanges { place.hold(self) }
        super.setFrameSize(newSize)
        if widthChanges { place.restoreSoon(self) }
    }

    /// Take the keyboard when the window has nothing else focused, so the
    /// arrow keys, Select All and Copy reach the page before a first click.
    /// Never from a field that has it (the search box).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window,
                  window.firstResponder == nil || window.firstResponder === window
            else { return }
            window.makeFirstResponder(self)
        }
    }

    /// Watched after `super`, which runs PDFView's own tracking (selection,
    /// links) to the mouse-up, so the click still does all it did.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        if event.clickCount == 1 { coordinator?.clicked(self, at: point) }
    }

    override func magnify(with event: NSEvent) {
        let wasAtFit = coordinator?.atFit(self) ?? false
        super.magnify(with: event)
        switch event.phase {
        case .began:
            total = 0
        case .ended, .cancelled:
            coordinator?.pinched(self, scale: 1, ended: true)
            return
        default:
            break
        }
        total += event.magnification
        if wasAtFit { coordinator?.pinched(self, scale: 1 + total, ended: false) }
    }
}
#else
extension PDFKitView: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView {
        let view = PlaceKeepingPDFView()
        view.backgroundColor = .secondarySystemBackground
        configure(view, context.coordinator)
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)
        // Taps are watched, not taken, like the pinch
        let tap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) { update(view, context.coordinator) }
}

/// Keeps the reader's place when the width changes, as on the Mac.
private final class PlaceKeepingPDFView: PDFView {
    private let place = PlaceKeeper()

    override var frame: CGRect {
        willSet { if newValue.width != frame.width { place.hold(self) } }
        didSet { if frame.width != oldValue.width { place.restoreSoon(self) } }
    }
}

extension PDFKitView.Coordinator: UIGestureRecognizerDelegate {
    /// Alongside PDFView's own pinch-to-zoom, never instead of it.
    func gestureRecognizer(
        _ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    @objc func tap(_ g: UITapGestureRecognizer) {
        guard let view = g.view as? PDFView else { return }
        clicked(view, at: g.location(in: view))
    }

    @objc func pinch(_ g: UIPinchGestureRecognizer) {
        guard let view = g.view as? PDFView else { return }
        let ended = [.ended, .cancelled, .failed].contains(g.state)
        pinched(view, scale: g.scale, ended: ended)
    }
}
#endif

extension PDFKitView.Coordinator: PDFViewDelegate {
    /// Each board carries a `lesson-block:` link (Contract 5) for presenters
    /// such as lesson-stage. The model strips them from the document shown,
    /// so text can be selected across a board; should one get through, a
    /// click on it is just a click on the page rather than a URL to open.
    /// Any other link opens as usual.
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        guard url.scheme != "lesson-block" else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

/// The place a PDFView was showing before a run of size changes, put back
/// once they stop. An animated resize sends many; the first one's place is
/// the reader's, and it is restored after the last, when PDFView has refit.
private final class PlaceKeeper {
    /// The page and the point at the view's top-left. Not the destination
    /// PDFView hands out: that carries the old zoom, and going to it put the
    /// page back at its old size instead of refitting it to the new width.
    private var held: (page: PDFPage, point: CGPoint, fitting: Bool)?
    private var pending: DispatchWorkItem?

    func hold(_ view: PDFView) {
        guard held == nil, let place = view.currentDestination, let page = place.page else { return }
        held = (page, place.point, view.autoScales)
    }

    func restoreSoon(_ view: PDFView) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, let place = self.held else { return }
            self.held = nil
            guard place.page.document === view.document else { return }
            if place.fitting {
                // Refit to the new width before going back
                view.autoScales = false
                view.autoScales = true
            }
            view.go(to: PDFDestination(page: place.page, at: place.point))
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}
