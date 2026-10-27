import Foundation
import PDFKit
import Testing
@testable import PbnToPdfKit

// Run on the Mac with `swift test`, or on a simulator:
//   xcodebuild test -scheme PbnToPdfKit -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)'

private func fixture() throws -> String {
    let url = try #require(Bundle.module.url(forResource: "Drury", withExtension: "pbn", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func everyLayoutRendersAPDF() throws {
    let pbn = try fixture()
    #expect(PageLayout.all.count == 7)
    for layout in PageLayout.all {
        let data = try Renderer.render(pbn, layout: layout)
        let doc = try #require(PDFDocument(data: data), "\(layout.rawValue)")
        #expect(doc.pageCount > 0, "\(layout.rawValue)")
    }
}

@Test func layoutsAreInDisplayOrder() {
    #expect(PageLayout.all.map(\.rawValue) == [
        "analysis", "hand-record", "dealer-summary", "bidding-sheets",
        "declarers-plan-1up", "declarers-plan-2up", "declarers-plan",
    ])
}

@Test func previewIsAFirstPageNotALesson() throws {
    let pbn = try fixture()
    let layout = try #require(PageLayout.all.first { $0.rawValue == "declarers-plan-1up" })
    let preview = try #require(PDFDocument(data: try Renderer.preview(pbn, layout: layout)))
    let full = try #require(PDFDocument(data: try Renderer.render(pbn, layout: layout)))
    #expect(preview.pageCount == 1)
    #expect(full.pageCount > 1)
}

@Test func boardsSelectByNumber() throws {
    let pbn = try fixture()
    let layout = try #require(PageLayout.all.first { $0.rawValue == "declarers-plan-1up" })
    var options = RenderOptions()
    options.boards = "1-2"
    let doc = try #require(PDFDocument(data: try Renderer.render(pbn, layout: layout, options: options)))
    #expect(doc.pageCount == 2)
}

@Test func embeddedRenderListsEveryBoardsFigure() throws {
    let pbn = try fixture()
    let count = try #require(Renderer.boardCount(pbn))
    let layout = try #require(PageLayout.all.first { $0.rawValue == "declarers-plan" })
    let rendered = try Renderer.renderEmbedded(pbn, layout: layout, sourceName: "Drury.pbn")
    let doc = try #require(PDFDocument(data: rendered.pdf))

    #expect(rendered.figures.map(\.board) == Array(1...count))
    #expect(rendered.figures.map(\.page) == (0..<count).map { $0 / 4 }, "four to a page")
    // The links PDFKit sees carry the same rects as the figures.
    for figure in rendered.figures {
        let page = try #require(doc.page(at: figure.page))
        let link = page.annotations.first {
            ($0.action as? PDFActionURL)?.url?.absoluteString == "lesson-block:\(figure.id)"
        }
        let bounds = try #require(link?.bounds, "figure \(figure.id)")
        #expect(abs(bounds.minX - figure.rect.minX) < 0.5 && abs(bounds.maxY - figure.rect.maxY) < 0.5)
        #expect(page.bounds(for: .mediaBox).contains(figure.rect))
    }
}

@Test func bareRendersCarryNoLinks() throws {
    let pbn = try fixture()
    let doc = try #require(PDFDocument(data: try Renderer.render(pbn, layout: PageLayout.all[0])))
    let page = try #require(doc.page(at: 0))
    #expect(!page.annotations.contains { $0.action is PDFActionURL })
}

@Test func notAPBNIsAnError() {
    #expect(Renderer.boardCount("hello") == 0)
    #expect(throws: RenderError.self) {
        try Renderer.render("hello", layout: PageLayout.all[0])
    }
}
