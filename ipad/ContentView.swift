import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var server = FrameServer()
    @State private var showStatus = true
    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalDisplayContainer(frameStore: server.frameStore, outputColorTag: .displayP3)
                .background(Color.black).ignoresSafeArea()
            if showStatus {
                VStack(alignment: .leading) {
                    Text("FP16 TEST • linear scRGB • USB 55002")
                    Text(server.status)
                    Button("Restart USB Listener") { server.restart() }
                }
                .padding().background(.black.opacity(0.75)).foregroundStyle(.white)
            }
        }
        .onTapGesture { showStatus.toggle() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true; server.start() }
    }
}
