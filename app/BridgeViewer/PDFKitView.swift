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
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged, object: view)
    }

    fileprivate func update(_ view: PDFView, _ coordinator: Coordinator) {
        coordinator.parent = self
        if view.document !== document {
            view.document = document
            // Fit the new document's width; autoScales alone keeps the old scale.
            view.scaleFactor = view.scaleFactorForSizeToFit
        }
        if let request, request != coordinator.lastRequest,
           let page = document?.page(at: request.index) {
            coordinator.lastRequest = request
            view.go(to: page)
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
        let view = PDFView()
        view.backgroundColor = .secondarySystemBackground
        configure(view, context.coordinator)
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) { update(view, context.coordinator) }
}

extension PDFKitView.Coordinator: UIGestureRecognizerDelegate {
    /// Alongside PDFView's own pinch-to-zoom, never instead of it.
    func gestureRecognizer(
        _ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    @objc func pinch(_ g: UIPinchGestureRecognizer) {
        guard let view = g.view as? PDFView else { return }
        let ended = [.ended, .cancelled, .failed].contains(g.state)
        pinched(view, scale: g.scale, ended: ended)
    }
}
#endif
