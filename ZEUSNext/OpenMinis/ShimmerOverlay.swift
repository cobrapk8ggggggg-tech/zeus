import SwiftUI
struct ShimmerOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var offsetX: CGFloat = -1.0

    private var peakOpacity: CGFloat {
        colorScheme == .light ? 0.75 : 0.25
    }

    private func bell(_ x: CGFloat) -> CGFloat {
        exp(-4.5 * x * x)
    }

    private var stableStops: [Gradient.Stop] {
        let stepCount = 12
        let bandRadius: CGFloat = 0.40
        let center: CGFloat = 0.5
        var stops: [Gradient.Stop] = []
        stops.append(.init(color: .white.opacity(0), location: 0))
        for i in 0...stepCount {
            let frac = CGFloat(i) / CGFloat(stepCount)
            let pos = center - bandRadius + frac * bandRadius * 2.0
            let dist = (pos - center) / bandRadius
            let alpha = bell(dist) * peakOpacity
            stops.append(.init(color: .white.opacity(Double(alpha)), location: pos))
        }
        stops.append(.init(color: .white.opacity(0), location: 1))
        return stops
    }

    var body: some View {
        GeometryReader { geo in
            let diag = geo.size.width + geo.size.height
            Rectangle()
                .fill(
                    LinearGradient(
                        stops: stableStops,
                        startPoint: UnitPoint(x: 0, y: 1),
                        endPoint: UnitPoint(x: 1, y: 0)
                    )
                )
                .frame(width: diag, height: geo.size.height)
                .offset(x: offsetX * geo.size.width)
                .onAppear {
                    withAnimation(
                        .linear(duration: 2.8)
                        .repeatForever(autoreverses: false)
                    ) {
                        offsetX = 1.0
                    }
                }
        }
        .clipped()
    }
}
