import PDFKit
import SwiftUI

// The few places iPad and Mac differ below SwiftUI. Images cross between
// threads as CGImage, which both platforms share; UIImage/NSImage stay here.

extension PDFPage {
    /// The page drawn to fit `size` points, at `scale` pixels per point.
    func cgThumbnail(fitting size: CGSize, scale: CGFloat) -> CGImage? {
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        #if os(macOS)
        return thumbnail(of: pixels, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return thumbnail(of: pixels, for: .mediaBox).cgImage
        #endif
    }
}

extension Image {
    init(page image: CGImage, scale: CGFloat) {
        self.init(decorative: image, scale: scale)
    }
}

#if os(macOS)
import AppKit

extension PDFDocument {
    /// Print through the standard panel, scaled to the paper.
    @MainActor func printWithPanel() {
        guard let operation = printOperation(for: .shared, scalingMode: .pageScaleToFit, autoRotate: true)
        else { return }
        if let window = NSApp.keyWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}
#endif
