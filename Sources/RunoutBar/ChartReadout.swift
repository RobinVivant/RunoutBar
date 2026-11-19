import Charts
import SwiftUI

/// What a chart shows for the pointer: a guide line at `x`, a dot per value and a small label.
struct ChartReadout<X: Plottable> {
    struct Dot {
        var y: Double
        var color: Color
    }

    struct Row {
        var color: Color?
        var text: String
    }

    var x: X
    var dots: [Dot] = []
    var title: String
    var rows: [Row] = []
    /// What the readout is about, such as an account id, for charts that highlight or open it.
    var subject: String?
}

extension View {
    /// Reads the chart under the pointer. `readout` gets the pointer in chart values and answers what to show
    /// there. `subject` follows the readout's subject, and a click hands the readout to `onTap`.
    func chartReadout<X: Plottable>(subject: Binding<String?> = .constant(nil),
                                    onTap: ((ChartReadout<X>) -> Void)? = nil,
                                    _ readout: @escaping (X, Double) -> ChartReadout<X>?) -> some View {
        modifier(ChartReadoutModifier(subject: subject, onTap: onTap, readout: readout))
    }
}

/// Draws the readout above the chart instead of as chart marks, so the plot never resizes under the pointer.
private struct ChartReadoutModifier<X: Plottable>: ViewModifier {
    @Binding var subject: String?
    var onTap: ((ChartReadout<X>) -> Void)?
    var readout: (X, Double) -> ChartReadout<X>?
    @State private var pointer: CGPoint?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active(let location) = phase { pointer = location } else { pointer = nil }
                            let found = pointer.flatMap { find(proxy, plot, $0) }?.subject
                            if found != subject { subject = found }
                        }
                        .gesture(SpatialTapGesture().onEnded { tap in
                            if let found = find(proxy, plot, tap.location) { onTap?(found) }
                        }, isEnabled: onTap != nil)
                    if let found = pointer.flatMap({ find(proxy, plot, $0) }), let x = proxy.position(forX: found.x) {
                        drawing(found, x: x, proxy: proxy, plot: plot).allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func find(_ proxy: ChartProxy, _ plot: CGRect, _ location: CGPoint) -> ChartReadout<X>? {
        guard plot.insetBy(dx: -2, dy: -2).contains(location),
              let x: X = proxy.value(atX: location.x - plot.minX),
              let y: Double = proxy.value(atY: location.y - plot.minY) else { return nil }
        return readout(x, y)
    }

    @ViewBuilder
    private func drawing(_ found: ChartReadout<X>, x: CGFloat, proxy: ChartProxy, plot: CGRect) -> some View {
        Rectangle().fill(Color.primary.opacity(0.35))
            .frame(width: 1, height: plot.height)
            .offset(x: plot.minX + x - 0.5, y: plot.minY)
        ForEach(Array(found.dots.enumerated()), id: \.offset) { _, dot in
            if let y = proxy.position(forY: dot.y) {
                Circle().fill(dot.color)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                    .frame(width: 8, height: 8)
                    .offset(x: plot.minX + x - 4, y: plot.minY + y - 4)
            }
        }
        // Beside the guide on the side with more room, and away from the values it names.
        let onRight = x < plot.width / 2
        let highest = found.dots.compactMap { proxy.position(forY: $0.y) }.min() ?? plot.height
        let atTop = highest > plot.height / 2
        label(found)
            .fixedSize()
            .padding(onRight ? .leading : .trailing, (onRight ? x : plot.width - x) + 8)
            .frame(width: plot.width, height: plot.height,
                   alignment: Alignment(horizontal: onRight ? .leading : .trailing, vertical: atTop ? .top : .bottom))
            .offset(x: plot.minX, y: plot.minY)
    }

    private func label(_ found: ChartReadout<X>) -> some View {
        VStack(alignment: .leading, spacing: 1.5) {
            Text(found.title).font(.system(size: 9.5, weight: .semibold))
            ForEach(Array(found.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    if let color = row.color { Circle().fill(color).frame(width: 6, height: 6) }
                    Text(row.text).font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}
