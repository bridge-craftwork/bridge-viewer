import CoreGraphics
import Foundation
import PbnToPdfFFI

/// One of the renderer's page layouts. `rawValue` is the CLI's spelling.
public struct PageLayout: Hashable, Sendable, Identifiable {
    public let rawValue: String
    public var id: String { rawValue }

    /// Every layout the linked renderer knows, in the app's display order:
    /// whole-deal views first, then the declarer's plans by boards per page,
    /// then anything newer the renderer has grown since. (The web app orders
    /// its gallery differently, declarer's plans first.)
    public static let all: [PageLayout] = {
        let names = takeString(ptp_layouts()).split(separator: "\n").map(String.init)
        return names
            .sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
            .map(PageLayout.init(rawValue:))
    }()

    private static let order = [
        "analysis", "hand-record", "dealer-summary", "bidding-sheets",
        "declarers-plan-1up", "declarers-plan-2up", "declarers-plan",
    ]

    /// Display name. Mirrors `layoutLabel` in the web app.
    public var label: String {
        switch rawValue {
        case "analysis": "Analysis"
        case "bidding-sheets": "Bidding sheets"
        case "declarers-plan-1up": "Declarer's plan — 1 per page"
        case "declarers-plan-2up": "Declarer's plan — 2 per page"
        case "declarers-plan": "Declarer's plan — 4 per page"
        case "dealer-summary": "Dealer summary"
        case "hand-record": "Hand record"
        default: rawValue
        }
    }

    /// The declarer's plans are the only layouts that draw cards, and so the
    /// only ones the circling options apply to.
    public var usesCardArt: Bool { rawValue.hasPrefix("declarers-plan") }
}

public struct RenderOptions: Sendable, Equatable {
    /// The CLI's `--boards` syntax ("1-8", "5,8,12"); nil renders every board.
    public var boards: String?
    public var circleSureWinners = false
    public var circlePromotableWinners = false
    public var circleLengthWinners = false
    public var omitPageFurniture = false

    public init() {}
}

/// Where one board sits in a rendered PDF, from the Contract 5 click map the
/// renderer embeds (lesson-stage's `docs/contracts/pdf-attachments.md`).
///
/// A board can have several figures: bidding sheets show each board on four
/// pages.
public struct BoardFigure: Sendable, Equatable, Identifiable {
    /// The figure's index in the click map, and its `lesson-block:` link.
    public let id: Int
    /// 0-based page index.
    public let page: Int
    /// In page space, points from the bottom-left, the way PDFKit has it.
    public let rect: CGRect
    /// The board's number in the PDF's embedded deals, 1 upward.
    public let board: Int
    /// The board's own number in the file, as the page labels it.
    public let label: String
}

/// A PDF with its payload attached, and where its boards are.
public struct RenderedDocument: Sendable {
    public let pdf: Data
    /// In reading order.
    public let figures: [BoardFigure]
}

public struct RenderError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// PBN text in, PDF bytes out. Stateless and thread-safe; a full lesson takes
/// a fraction of a second, so call it off the main actor.
public enum Renderer {
    public static func render(
        _ pbn: String, layout: PageLayout, options: RenderOptions = .init()
    ) throws(RenderError) -> Data {
        try call(ptp_render, pbn, layout, options)
    }

    /// Render with the Contract 5 payload embedded, so a saved or shared PDF
    /// carries its source and opens in lesson-stage with tappable boards.
    /// `sourceName` is the filename the embedded PBN carries.
    public static func renderEmbedded(
        _ pbn: String, layout: PageLayout, options: RenderOptions = .init(), sourceName: String
    ) throws(RenderError) -> RenderedDocument {
        var pdf = PtpBuffer(ptr: nil, len: 0)
        var clickMap: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let status = withOptions(options) { opts in
            ptp_render_embedded(pbn, layout.rawValue, opts, sourceName, &pdf, &clickMap, &error)
        }
        let map = takeString(clickMap)
        guard status == PTP_OK, let ptr = pdf.ptr else {
            throw RenderError(message: error.map(takeString) ?? "Rendering failed.")
        }
        let data = Data(bytes: ptr, count: pdf.len)
        ptp_buffer_free(pdf)
        return RenderedDocument(pdf: data, figures: ClickMap.figures(in: map))
    }

    /// The layout's representative opening boards — enough for a first page.
    public static func preview(
        _ pbn: String, layout: PageLayout, options: RenderOptions = .init()
    ) throws(RenderError) -> Data {
        try call(ptp_render_preview, pbn, layout, options)
    }

    /// Number of boards in the file, or nil if it can't be read as PBN.
    public static func boardCount(_ pbn: String) -> Int? {
        let n = ptp_board_count(pbn)
        return n < 0 ? nil : Int(n)
    }

    private typealias Entry = (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<PtpOptions>?,
        UnsafeMutablePointer<PtpBuffer>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32

    private static func call(
        _ entry: Entry, _ pbn: String, _ layout: PageLayout, _ options: RenderOptions
    ) throws(RenderError) -> Data {
        var pdf = PtpBuffer(ptr: nil, len: 0)
        var error: UnsafeMutablePointer<CChar>?
        let status = withOptions(options) { opts in
            entry(pbn, layout.rawValue, opts, &pdf, &error)
        }
        guard status == PTP_OK, let ptr = pdf.ptr else {
            throw RenderError(message: error.map(takeString) ?? "Rendering failed.")
        }
        // Copy out and hand the Rust allocation straight back.
        let data = Data(bytes: ptr, count: pdf.len)
        ptp_buffer_free(pdf)
        return data
    }

    private static func withOptions<T>(
        _ options: RenderOptions, _ body: (UnsafePointer<PtpOptions>) -> T
    ) -> T {
        func make(_ boards: UnsafePointer<CChar>?) -> T {
            var raw = PtpOptions(
                boards: boards,
                circle_sure_winners: options.circleSureWinners,
                circle_promotable_winners: options.circlePromotableWinners,
                circle_length_winners: options.circleLengthWinners,
                omit_page_furniture: options.omitPageFurniture
            )
            return withUnsafePointer(to: &raw, body)
        }
        guard let boards = options.boards else { return make(nil) }
        return boards.withCString(make)
    }
}

/// The fields of `lesson-blocks.json` the app uses. Unknown fields are ignored,
/// as the contract requires; a map that won't decode gives no figures, and the
/// PDF still shows.
private struct ClickMap: Decodable {
    struct Block: Decodable {
        let index: Int
        let page: Int?
        let rect: [Double]?
        let board: Int?
        let sourceBoard: String?
    }
    let blocks: [Block]

    static func figures(in json: String) -> [BoardFigure] {
        guard let map = try? JSONDecoder().decode(ClickMap.self, from: Data(json.utf8)) else { return [] }
        return map.blocks.compactMap { block in
            guard let page = block.page, let rect = block.rect, rect.count == 4, let board = block.board
            else { return nil }
            return BoardFigure(
                id: block.index,
                page: page - 1,
                rect: CGRect(x: rect[0], y: rect[1], width: rect[2] - rect[0], height: rect[3] - rect[1]),
                board: board,
                label: block.sourceBoard ?? String(board)
            )
        }
    }
}

/// Copy a library-owned C string into Swift and free it.
private func takeString(_ s: UnsafeMutablePointer<CChar>?) -> String {
    guard let s else { return "" }
    defer { ptp_string_free(s) }
    return String(cString: s)
}
