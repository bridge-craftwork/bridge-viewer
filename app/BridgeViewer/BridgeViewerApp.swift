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
        // On the iPad the same commands fill the menu bar and the ⌘-hold
        // shortcut list.
        WindowGroup { root }
            .commands { MenuCommands(model: model) }
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
