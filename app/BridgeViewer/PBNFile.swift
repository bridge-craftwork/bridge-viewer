import Foundation
import PbnToPdfKit
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist; keep the identifier in step.
    static let pbn = UTType(importedAs: "com.popperbiz.pbn", conformingTo: .plainText)
}

/// A PBN file, read into memory.
struct PBNFile: Equatable {
    var name: String
    var text: String
    var boardCount: Int

    /// The name without its extension, for naming the PDF.
    var stem: String { (name as NSString).deletingPathExtension }

    enum ReadError: LocalizedError {
        case unreadable(String)
        case notPBN(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): "Couldn't read \(name)."
            case .notPBN(let name): "\(name) has no boards in it. Is it a PBN file?"
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
        guard let count = Renderer.boardCount(text), count > 0 else { throw ReadError.notPBN(name) }
        return PBNFile(name: name, text: text, boardCount: count)
    }

    static func sample() -> PBNFile? {
        guard let url = Bundle.main.url(forResource: "Sample", withExtension: "pbn"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? parse(data, name: "Sample.pbn")
    }
}
