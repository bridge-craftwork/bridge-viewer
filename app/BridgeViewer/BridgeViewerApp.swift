import SwiftUI

@main
struct BridgeViewerApp: App {
    @State private var model = DocumentModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                // A .pbn tapped in Files, or sent here from the share sheet.
                .onOpenURL { model.open(url: $0) }
                #if DEBUG
                // `-LoadSample` opens the bundled sample at launch, so the
                // simulator can be screenshotted without tapping through.
                .task {
                    if CommandLine.arguments.contains("-LoadSample"), let sample = PBNFile.sample() {
                        model.load(sample)
                    }
                }
                #endif
        }
    }
}
