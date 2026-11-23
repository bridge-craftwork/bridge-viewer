import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
private extension PlatformColor {
    static var sourceText: NSColor { .labelColor }
    static var sourceDim: NSColor { .tertiaryLabelColor }
    static var sourceComment: NSColor { .secondaryLabelColor }
}
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
private extension PlatformColor {
    static var sourceText: UIColor { .label }
    static var sourceDim: UIColor { .tertiaryLabel }
    static var sourceComment: UIColor { .secondaryLabel }
}
#endif

/// View Source, as Bridge Composer has it: the file as it was opened, PBN or
/// LIN, syntax-coloured. The board the PDF last pointed at is highlighted and
/// scrolled to; clicking in a board's record reports its index.
struct SourceView {
    let file: PBNFile
    /// The record to highlight, an index into `file.sourceRecords`.
    let highlighted: Int?
    let onSelectRecord: (Int) -> Void

    final class Coordinator: NSObject {
        var parent: SourceView
        var shownFile: PBNFile?
        var shownHighlight: Int?
        /// Set while the text is being replaced, whose selection changes are
        /// not the reader's.
        var refreshing = false
        init(_ parent: SourceView) { self.parent = parent }

        /// The record holding `location`, or the last one starting before it.
        func record(at location: Int) -> Int? {
            let records = parent.file.sourceRecords
            if let hit = records.firstIndex(where: { NSLocationInRange(location, $0) }) { return hit }
            return records.lastIndex { $0.location <= location }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Fill the text storage when the file changes, and move the highlight
    /// when the record does.
    fileprivate func refresh(_ storage: NSTextStorage, _ coordinator: Coordinator, scroll: (NSRange) -> Void) {
        coordinator.parent = self
        coordinator.refreshing = true
        defer { coordinator.refreshing = false }
        if coordinator.shownFile != file {
            coordinator.shownFile = file
            coordinator.shownHighlight = nil
            storage.setAttributedString(SourceHighlighter.highlight(file.source, lin: file.isLIN))
        }
        guard coordinator.shownHighlight != highlighted else { return }
        let whole = NSRange(location: 0, length: storage.length)
        if let old = coordinator.shownHighlight, file.sourceRecords.indices.contains(old) {
            storage.removeAttribute(.backgroundColor, range: NSIntersectionRange(file.sourceRecords[old], whole))
        }
        coordinator.shownHighlight = highlighted
        if let new = highlighted, file.sourceRecords.indices.contains(new) {
            let range = NSIntersectionRange(file.sourceRecords[new], whole)
            storage.addAttribute(
                .backgroundColor, value: PlatformColor.systemYellow.withAlphaComponent(0.22), range: range)
            scroll(NSRange(location: range.location, length: 0))
        }
    }
}

#if os(macOS)
extension SourceView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.layoutManager?.allowsNonContiguousLayout = true
        text.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, let storage = text.textStorage else { return }
        refresh(storage, context.coordinator) { range in
            text.scrollRangeToVisible(range)
        }
    }
}

extension SourceView.Coordinator: NSTextViewDelegate {
    /// A click puts the insertion point in the text; the highlight is drawn
    /// with a background colour, never a selection, so every selection change
    /// is the reader's.
    func textViewDidChangeSelection(_ note: Notification) {
        guard !refreshing, let view = note.object as? NSTextView,
              let index = record(at: view.selectedRange().location)
        else { return }
        parent.onSelectRecord(index)
    }
}
#else
extension SourceView: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let text = UITextView()
        text.isEditable = false
        text.isSelectable = true
        text.alwaysBounceVertical = true
        text.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        text.backgroundColor = .systemBackground
        // A tap on text that can't be edited places no caret, so find the
        // character under the finger directly.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        text.addGestureRecognizer(tap)
        return text
    }

    func updateUIView(_ text: UITextView, context: Context) {
        refresh(text.textStorage, context.coordinator) { range in
            text.scrollRangeToVisible(range)
        }
    }
}

extension SourceView.Coordinator: UIGestureRecognizerDelegate {
    @objc func tapped(_ tap: UITapGestureRecognizer) {
        guard let view = tap.view as? UITextView,
              let position = view.closestPosition(to: tap.location(in: view)),
              let index = record(at: view.offset(from: view.beginningOfDocument, to: position))
        else { return }
        parent.onSelectRecord(index)
    }

    func gestureRecognizer(
        _ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}
#endif

/// Syntax colouring for PBN and LIN, in the system's colours so it reads in
/// light and dark mode alike.
enum SourceHighlighter {
    static func highlight(_ text: String, lin: Bool) -> NSAttributedString {
        let size: CGFloat
        #if os(macOS)
        size = 12
        #else
        size = 13
        #endif
        let font = PlatformFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let bold = PlatformFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        let out = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: PlatformColor.sourceText])
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)

        func paint(_ pattern: String, group: Int = 0, options: NSRegularExpression.Options = [],
                   _ attributes: [NSAttributedString.Key: Any]) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            regex.enumerateMatches(in: text, range: whole) { match, _, _ in
                guard let range = match?.range(at: group), range.location != NSNotFound else { return }
                out.addAttributes(attributes, range: range)
            }
        }
        let red: [NSAttributedString.Key: Any] = [.foregroundColor: PlatformColor.systemRed]

        if lin {
            highlightLIN(ns, into: out, bold: bold)
            return out
        }

        // Cards and annotations in section data first; tag lines, comments
        // and commentary are painted over them.
        paint(#"(?<![A-Za-z0-9])[HD][2-9TJQKA](?![A-Za-z0-9])"#, red)
        paint(#"=\d+=|\$\d+|[!?]{1,2}(?=\s|$)"#, options: .anchorsMatchLines,
              [.foregroundColor: PlatformColor.systemOrange])
        paint(#"^\s*\[[^\]\n]*\]"#, options: .anchorsMatchLines,
              [.foregroundColor: PlatformColor.sourceDim, .font: font])
        paint(#"^\s*\[(\w+)"#, group: 1, options: .anchorsMatchLines,
              [.foregroundColor: PlatformColor.systemBlue, .font: bold])
        paint(#"^\s*\[\w+\s+(".*")\s*\]"#, group: 1, options: .anchorsMatchLines,
              [.foregroundColor: PlatformColor.systemBrown])
        paint(#"^[%;].*$"#, options: .anchorsMatchLines, [.foregroundColor: PlatformColor.sourceComment])
        paint(#"\{[^}]*\}"#, [.foregroundColor: PlatformColor.systemGreen])
        return out
    }

    /// LIN by its `command|value|` pairs, which only a scan can tell apart:
    /// a value such as `CK` looks just like a command.
    private static func highlightLIN(_ text: NSString, into out: NSMutableAttributedString, bold: PlatformFont) {
        let pipe = UInt16(UInt8(ascii: "|"))
        var start = 0
        var isCommand = true
        var command = ""
        for i in 0..<text.length where text.character(at: i) == pipe {
            out.addAttribute(.foregroundColor, value: PlatformColor.sourceDim, range: NSRange(location: i, length: 1))
            let range = NSRange(location: start, length: i - start)
            let piece = text.substring(with: range)
            if isCommand {
                // The command, less the line break a board starts with
                let name = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                command = name.lowercased()
                let at = (piece as NSString).range(of: name)
                if at.location != NSNotFound {
                    out.addAttributes(
                        [.foregroundColor: PlatformColor.systemBlue, .font: bold],
                        range: NSRange(location: start + at.location, length: at.length))
                }
            } else {
                switch command {
                case "md":
                    out.addAttribute(.foregroundColor, value: PlatformColor.systemPurple, range: range)
                case "pc" where piece.first.map({ "HDhd".contains($0) }) == true:
                    out.addAttribute(.foregroundColor, value: PlatformColor.systemRed, range: range)
                case "mb":
                    out.addAttribute(.font, value: bold, range: range)
                case "an", "nt":
                    out.addAttribute(.foregroundColor, value: PlatformColor.systemGreen, range: range)
                default:
                    break
                }
            }
            isCommand.toggle()
            start = i + 1
        }
    }
}
