import SwiftUI

@main
struct BridgeViewerApp: App {
    @State private var model = DocumentModel()

    var body: some Scene {
        #if os(macOS)
        // One window: the model is the app's single open document, and a
        // second window sharing it would mirror the first.
        Window("Bridge Viewer", id: "main") { root }
            .defaultSize(width: 1100, height: 900)
            .commands { MenuCommands(model: model) }
        #else
        WindowGroup { root }
        #endif
    }

    private var root: some View {
        ContentView()
            .environment(model)
            // A .pbn tapped in Files, sent from the share sheet, or (on the
            // Mac) opened from Finder or dropped on the Dock icon.
            .onOpenURL { model.open(url: $0) }
            #if DEBUG
            // Launch arguments for screenshotting without tapping through:
            // `-LoadSample`, or `-LoadFile <path>`; then `-Layout <name>`,
            // `-ShowGrid`, `-ShowBoards`, `-GoToBoard <n>` and `-Search <text>`.
            .task { await model.applyDebugArguments(CommandLine.arguments) }
            #endif
    }
}

#if os(macOS)
/// File ▸ Open, Save PDF and Print, and View ▸ the page grid and the board
/// index.
private struct MenuCommands: Commands {
    let model: DocumentModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.isImporting = true }
                .keyboardShortcut("o")
        }
        // Close lives in this group too, so replacing it drops ⌘W unless it
        // is put back. Close the file first, then the window.
        CommandGroup(replacing: .saveItem) {
            Button("Close") {
                if model.file != nil {
                    model.close()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")
            Button("Save PDF…") { model.isExporting = true }
                .keyboardShortcut("s")
                .disabled(model.pdfData == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { model.pdf?.printWithPanel() }
                .keyboardShortcut("p")
                .disabled(model.pdf == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find…") { model.isSearching = true }
                .keyboardShortcut("f")
                .disabled(model.pdf == nil)
        }
        CommandGroup(before: .toolbar) {
            Button(model.viewMode == .grid ? "Show Pages" : "Show Page Grid") {
                model.viewMode = model.viewMode == .grid ? .pages : .grid
            }
            .keyboardShortcut("g", modifiers: [.command, .option])
            .disabled(model.pdf == nil)
            Button("Go to Board…") { model.isShowingBoards = true }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(model.boards.isEmpty)
            Divider()
        }
    }
}
#endif
