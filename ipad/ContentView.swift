import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var server = FrameServer()
    @State private var showStatus = true
    @State private var outputColorTag = DisplayConfig.defaultOutputColorTag

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalDisplayContainer(frameStore: server.frameStore, outputColorTag: outputColorTag)
                .background(Color.black)
                .ignoresSafeArea()

            if showStatus { VStack(alignment: .leading, spacing: 6) {
                Text("V7.1 • TRUE DISPLAY 2 • 2360×1640@60")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))

                Text(server.status)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))

                Text("PIXELS UNCHANGED • TAG: \(outputColorTag.title)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))

                Picker("Output color tag", selection: $outputColorTag) {
                    ForEach(OutputColorTag.allCases) { tag in
                        Text(tag == .displayP3 ? "P3 TAG" : "709 TAG").tag(tag)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Button("Restart USB Listener") {
                    server.restart()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(10)
            .background(.black.opacity(0.72))
            .foregroundStyle(.white)
            .padding(10)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showStatus.toggle() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            server.start()
        }
    }
}
