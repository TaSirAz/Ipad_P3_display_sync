import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var server = FrameServer()
    @State private var showStatus = true
    @State private var outputColorTag = DisplayConfig.defaultOutputColorTag

    @State private var showColorReference = false
    @State private var showStreamReference = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !showStreamReference {
            MetalDisplayContainer(frameStore: server.frameStore, outputColorTag: outputColorTag)
                .background(Color.black)
                .ignoresSafeArea()
            }

            if showStatus { VStack(alignment: .leading, spacing: 6) {
                Text("COLOR CHECK 7.4 (12) • 2360×1640 • 10-bit")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))

                Text(server.status)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))

                Text("PIXELS UNCHANGED • TAG: \(outputColorTag.title)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))

                Picker("Output color tag", selection: $outputColorTag) {
                    ForEach(OutputColorTag.allCases) { tag in
                        Text(tag.title).tag(tag)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 420)

                Button("Windows 串流 / 原生 P3 比較") { showStreamReference = true }
                    .buttonStyle(.borderedProminent)

                Button("Check Metal against native P3") { showColorReference = true }
                    .buttonStyle(.borderedProminent)

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
        .sheet(isPresented: $showStreamReference) { StreamColorReferenceView(store: server.frameStore) }
        .sheet(isPresented: $showColorReference) { ColorReferenceView() }
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            server.start()
        }
    }
}
