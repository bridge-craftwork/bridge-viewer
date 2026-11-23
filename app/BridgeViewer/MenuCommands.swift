import SwiftUI

/// The menu bar on the Mac, and on the iPad the menu bar and the list a held
/// ⌘ shows.
///
/// Copy and Select All aren't here: the system's Edit items send them down
/// the responder chain, so they reach PDFView after a click in the page and
/// the search field while it is being typed in.
struct MenuCommands: Commands {
    let model: DocumentModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.isImporting = true }
                .keyboardShortcut("o")
        }
        // Close lives in this group too, so replacing it drops ⌘W unless it
        // is put back. Close the file first, then (on the Mac) the window.
        CommandGroup(replacing: .saveItem) {
            #if os(macOS)
            Button("Close") {
                if model.file != nil {
                    model.close()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")
            #else
            Button("Close File") { model.close() }
                .keyboardShortcut("w")
                .disabled(model.file == nil)
            #endif
            Button("Save PDF…") { model.isExporting = true }
                .keyboardShortcut("s")
                .disabled(model.pdfData == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { model.printPDF() }
                .keyboardShortcut("p")
                .disabled(model.pdfData == nil)
        }
        CommandGroup(after: .textEditing) {
            Menu("Find") {
                Button("Find…") { model.beginSearch() }
                    .keyboardShortcut("f")
                    .disabled(model.pdf == nil)
                Button("Find Next") { model.nextMatch() }
                    .keyboardShortcut("g")
                    .disabled(model.searchResults.isEmpty)
                Button("Find Previous") { model.previousMatch() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(model.searchResults.isEmpty)
                Button("Use Selection for Find") { model.useSelectionForFind() }
                    .keyboardShortcut("e")
                    .disabled(model.pdf == nil)
            }
        }
        CommandGroup(before: .toolbar) {
            // ⌘= rather than ⌘+: menus match the unshifted key, so a "+"
            // shortcut would need ⇧ on most keyboards.
            Button("Actual Size") { model.actualSize() }
                .keyboardShortcut("0")
                .disabled(!model.canNavigate)
            Button("Zoom to Fit") { model.zoomToFit() }
                .keyboardShortcut("9")
                .disabled(!model.canNavigate)
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("=")
                .disabled(!model.canNavigate)
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-")
                .disabled(!model.canNavigate)
            Divider()
            Toggle("Show Play Records", isOn: Binding(
                get: { model.options.allPlayRecords },
                set: { model.options.allPlayRecords = $0 }
            ))
            .disabled(!model.offersPlayRecords)
            // ⌥⌘U, as Safari's Show Page Source
            Button(model.isShowingSource ? "Hide Source" : "View Source") {
                model.isShowingSource.toggle()
            }
            .keyboardShortcut("u", modifiers: [.command, .option])
            .disabled(model.file == nil)
            Button(model.viewMode == .grid ? "Show Pages" : "Show Page Grid") {
                model.viewMode = model.viewMode == .grid ? .pages : .grid
            }
            .keyboardShortcut("g", modifiers: [.command, .option])
            .disabled(model.pdf == nil)
            Divider()
        }
        CommandMenu("Go") {
            Button("Previous Page") { model.previousPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!model.canNavigate)
            Button("Next Page") { model.nextPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!model.canNavigate)
            Divider()
            Button("First Page") { model.firstPage() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option, .shift])
                .disabled(!model.canNavigate)
            Button("Last Page") { model.lastPage() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
                .disabled(!model.canNavigate)
            Divider()
            Button("Go to Board…") { model.isShowingBoards = true }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(model.boards.isEmpty)
        }
    }
}
