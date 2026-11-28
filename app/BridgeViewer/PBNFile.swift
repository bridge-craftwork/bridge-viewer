import Foundation
import PbnToPdfKit
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist; keep the identifier in step.
    static let pbn = UTType(exportedAs: "com.popperbiz.pbn", conformingTo: .plainText)

    /// What the file picker accepts: PBN and LIN. Another app may export its own type for
    /// .pbn and win -- on a Mac with Shark Bridge installed, .pbn files can be
    /// com.emabridge.bridgedeal, which doesn't even conform to text -- so also
    /// take whatever the system maps .pbn to.
    static let pbnFiles: [UTType] = {
        var types: [UTType] = [.pbn, .lin]
        for ext in ["pbn", "lin"] {
            for type in UTType.types(tag: ext, tagClass: .filenameExtension, conformingTo: nil)
            where !types.contains(type) {
                types.append(type)
            }
        }
        return types + [.plainText]
    }()

    /// BBO's LIN, declared in Info.plist like .pbn; keep the identifier in step.
    static let lin = UTType(exportedAs: "com.popperbiz.lin", conformingTo: .plainText)
}

/// A PBN file, read into memory. A LIN file arrives here already turned
/// into PBN.
struct PBNFile: Equatable {
    var name: String
    /// The PBN the app renders: the file itself, or a LIN file read into PBN.
    var text: String
    var boardCount: Int
    /// The file as it was opened, for View Source.
    var source: String
    var isLIN: Bool
    /// Where each board's record sits in `source`, in UTF-16 (`NSString`)
    /// units: entry `i` is board `i` of `text`, and of the click map.
    var sourceRecords: [NSRange]

    /// The name without its extension, for naming the PDF.
    var stem: String { (name as NSString).deletingPathExtension }

    /// Whether any board records its play, so the play-record toggle has
    /// something to show.
    var hasPlay: Bool { text.contains("[Play ") }

    enum ReadError: LocalizedError {
        case unreadable(String)
        case notPBN(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Couldn't read \(name)."
            case .notPBN(let name): "\(name) has no boards in it. Is it a PBN or LIN file?"
            }
        }
    }

    /// Read a file from a picker or an "Open in" hand-off. Either may be a
    /// security-scoped URL into another app's storage.
    static func read(_ url: URL) throws -> PBNFile {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { throw ReadError.unreadable(name) }
        return try parse(data, name: name)
    }

    static func parse(_ data: Data, name: String) throws -> PBNFile {
        // Most PBN is UTF-8, but older producers write Windows-1252 (accented
        // player names, the odd curly quote). Fall back rather than refuse.
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
        else { throw ReadError.unreadable(name) }
        // LIN is read into PBN, the way Bridge Composer opens it, and from
        // then on the file is PBN to the rest of the app.
        let isLIN = (name as NSString).pathExtension.lowercased() == "lin"
        let pbn: String
        if isLIN {
            do { pbn = try Renderer.pbn(fromLIN: text) } catch { throw ReadError.notPBN(name) }
        } else {
            pbn = text
        }
        guard let count = Renderer.boardCount(pbn), count > 0 else { throw ReadError.notPBN(name) }
        return PBNFile(
            name: name, text: pbn, boardCount: count,
            source: text, isLIN: isLIN, sourceRecords: records(in: text, lin: isLIN)
        )
    }

    /// The renderer's byte ranges as ranges a text view can use.
    private static func records(in text: String, lin: Bool) -> [NSRange] {
        let utf8 = text.utf8
        return Renderer.sourceRecords(text, lin: lin).compactMap { bytes in
            guard let start = utf8.index(utf8.startIndex, offsetBy: bytes.lowerBound, limitedBy: utf8.endIndex),
                  let end = utf8.index(utf8.startIndex, offsetBy: bytes.upperBound, limitedBy: utf8.endIndex)
            else { return nil }
            return NSRange(start..<end, in: text)
        }
    }

    /// This file with `pbn`, its text after solving, in place of its own.
    /// From then on it is that PBN: a LIN file becomes a `.pbn` of the same
    /// name, and View Source shows the new text.
    func withAnalysis(_ pbn: String) throws -> PBNFile {
        try PBNFile.parse(Data(pbn.utf8), name: isLIN ? "\(stem).pbn" : name)
    }

    static func sample() -> PBNFile? {
        guard let url = Bundle.main.url(forResource: "Sample", withExtension: "pbn"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? parse(data, name: "Sample.pbn")
    }
}
