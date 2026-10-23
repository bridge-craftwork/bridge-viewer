import Foundation
import PDFKit

/// Page thumbnails for the grid, drawn off the main actor on demand.
///
/// Holds its own PDFDocument, made from the rendered bytes, so drawing never
/// touches the one PDFView is showing. Thumbnails are cached by page and by
/// width bucket; NSCache lets the system take them back under memory
/// pressure, which matters for a 120-page lesson on an iPad.
actor ThumbnailLoader {
    private let document: PDFDocument?
    private let cache = NSCache<NSString, CGImage>()

    init(data: Data) {
        document = PDFDocument(data: data)
        cache.countLimit = 400
    }

    /// Page `index` (0-based) drawn `width` points wide.
    func thumbnail(page index: Int, width: CGFloat, scale: CGFloat) -> CGImage? {
        // Bucket widths so a pinch doesn't redraw every page at every step.
        let bucket = (width / 80).rounded(.up) * 80
        let key = "\(index)@\(Int(bucket * scale))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let page = document?.page(at: index) else { return nil }
        let box = page.bounds(for: .mediaBox)
        let size = CGSize(width: bucket, height: bucket * box.height / max(box.width, 1))
        guard let image = page.cgThumbnail(fitting: size, scale: scale) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
