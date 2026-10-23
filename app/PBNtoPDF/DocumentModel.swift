import Observation
import PDFKit
import PbnToPdfKit
import UIKit

/// The open file, the chosen layout, and what they render to.
///
/// Rendering runs off the main actor. A change of file, layout or options
/// starts a new render and cancels interest in the old one: each render
/// carries a generation number, and a result that arrives after a newer
/// request has been made is dropped.
@MainActor @Observable
final class DocumentModel {
    private(set) var file: PBNFile?
    var layout: PageLayout = PageLayout.all[0] { didSet { if layout != oldValue { render() } } }
    var options = RenderOptions() { didSet { if options != oldValue { render(); renderPreviews() } } }

    private(set) var pdf: PDFDocument?
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
    private(set) var previews: [PageLayout: UIImage] = [:]

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
        render()
        renderPreviews()
    }

    private func render() {
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
                    self.pdf = PDFDocument(data: data)
                    self.shareURL = url
                    self.error = nil
                case .failure(let error):
                    self.pdf = nil
                    self.shareURL = nil
                    self.error = error.localizedDescription
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
                      let page = PDFDocument(data: data)?.page(at: 0)
                else { continue }
                let image = page.thumbnail(of: CGSize(width: 240, height: 240), for: .mediaBox)
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
