import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var server = FrameServer()
    @State private var showStatus = true
    @State private var paired = false
    @State private var swapped = false
    private let codes: [[Double]] = [[1,0.04,0.04],[0.2,1,0.15],[1,0.55,0],[1,0.08,0.58],[0,0.95,0.75],[0.7,0.1,1],[0,0,0],[0.04,0.04,0.04],[0.184,0.184,0.184],[0.5,0.5,0.5],[0.75,0.75,0.75],[1,1,1]]
    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { g in
                let aspect = CGFloat(DisplayConfig.width) / CGFloat(DisplayConfig.height)
                let w = min(g.size.width, g.size.height * aspect)
                let h = w / aspect
                ZStack {
                    MetalDisplayContainer(frameStore: server.frameStore, outputColorTag: .displayP3, paired: paired)
                    if paired {
                        VStack(spacing: 0) {
                            ForEach(0..<4) { row in
                                HStack(spacing: 0) {
                                    ForEach(0..<3) { col in
                                        let c = codes[row*3+col]
                                        ZStack(alignment: .bottom) {
                                            HStack(spacing: 0) {
                                                if !swapped { Color.clear }
                                                Color(displayP3Red: c[0], green: c[1], blue: c[2], opacity: 1)
                                                if swapped { Color.clear }
                                            }
                                            HStack {
                                                Text(swapped ? "原生 P3" : "LR 串流")
                                                Spacer()
                                                Text(swapped ? "LR 串流" : "原生 P3")
                                            }
                                            .font(.caption).padding(4)
                                            .foregroundStyle(.white).background(.black.opacity(0.7))
                                        }
                                        .frame(width:w/3,height:h/4)
                                    }
                                }
                            }
                        }
                    }
                }.frame(width:w,height:h).position(x:g.size.width/2,y:g.size.height/2)
            }.ignoresSafeArea()
            if showStatus {
                VStack(alignment: .leading) {
                    Text("FP16 • LR / P3 比較")
                    if !paired { Text(server.status) }
                    Button(paired ? "回到串流" : "LR／原生 P3 並排") { paired.toggle() }
                    if paired {
                        Button("交換左右") { swapped.toggle() }
                        Text("固定取樣目前 LR 編輯版面；請勿移動或縮放圖片。")
                            .font(.caption)
                    }
                    Button("Restart USB Listener") { server.restart() }
                }.padding(8).background(.black.opacity(0.8)).foregroundStyle(.white)
            }
        }
        .background(Color.black)
        .onTapGesture(count:2) { showStatus.toggle() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true; server.start() }
    }
}
