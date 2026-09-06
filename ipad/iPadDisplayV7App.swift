import SwiftUI

@main
struct iPadDisplayV7App: App {
    @StateObject private var server = FrameServer()

    var body: some Scene {
        WindowGroup {
            ContentView(frameStore: server.frameStore)
                .onAppear {
                    server.start()
                }
        }
    }
}