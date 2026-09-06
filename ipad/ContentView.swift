import SwiftUI

struct ContentView: View {
    private let store = FrameStore()
    @State private var paired = false
    @State private var swapped = false

    private let colors: [[Double]] = [
        [1, 0, 0],
        [0, 1, 0],
        [0, 0, 1],
        [1, 0.3, 0],
        [1, 0, 0.6],
        [0, 0.8, 0.7],
        [0, 0, 0],
        [0.18, 0.18, 0.18],
        [0.5, 0.5, 0.5],
        [0.75, 0.75, 0.75],
        [1, 1, 1],
        [0.16, 0.02, 0.7]
    ]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Windows 串流 / 原生 P3")
                    .font(.headline)

                Spacer()

                Button(paired ? "回到串流" : "LR／原生 P3 並排") {
                    paired.toggle()
                }

                if paired {
                    Button("交換左右") {
                        swapped.toggle()
                    }
                }
            }

            MetalDisplayContainer(
                frameStore: store,
                outputColorTag: .displayP3
            )
            .overlay {
                if paired {
                    comparisonGrid
                }
            }
            .clipShape(
                RoundedRectangle(cornerRadius: 12)
            )
        }
        .padding()
    }

    private var comparisonGrid: some View {
        GeometryReader { proxy in
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 0),
                    GridItem(.flexible(), spacing: 0),
                    GridItem(.flexible(), spacing: 0)
                ],
                spacing: 0
            ) {
                ForEach(
                    Array(colors.enumerated()),
                    id: \.offset
                ) { index, color in
                    comparisonCell(color)
                        .frame(
                            height: proxy.size.height / 4
                        )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func comparisonCell(
        _ color: [Double]
    ) -> some View {
        HStack(spacing: 0) {
            if swapped {
                p3Patch(color)
                Color.clear
            } else {
                Color.clear
                p3Patch(color)
            }
        }
    }

    private func p3Patch(
        _ color: [Double]
    ) -> some View {
        Color(
            .displayP3,
            red: color[0],
            green: color[1],
            blue: color[2],
            opacity: 1
        )
    }
}