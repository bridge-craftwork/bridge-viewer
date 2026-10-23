import PDFKit
import SwiftUI

/// PDFKit's viewer: native scrolling and pinch-zoom, which is what the web
/// app's iframe could not give an iPad.
struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard view.document !== document else { return }
        view.document = document
        // Fit the new document's width; autoScales alone keeps the old scale.
        view.scaleFactor = view.scaleFactorForSizeToFit
    }
}
