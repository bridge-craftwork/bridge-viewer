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
    var text: String
    var boardCount: Int

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
        let pbn: String
        if (name as NSString).pathExtension.lowercased() == "lin" {
            do { pbn = try Renderer.pbn(fromLIN: text) } catch { throw ReadError.notPBN(name) }
        } else {
            pbn = text
        }
        guard let count = Renderer.boardCount(pbn), count > 0 else { throw ReadError.notPBN(name) }
        return PBNFile(name: name, text: pbn, boardCount: count)
    }

    static func sample() -> PBNFile? {
        guard let url = Bundle.main.url(forResource: "Sample", withExtension: "pbn"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? parse(data, name: "Sample.pbn")
    }
}
