import SwiftUI
import WidgetKit

struct ComponentView: View {
    let node: LayoutNode
    var nativeWidget = false
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View { content }
    private var foreground: Color {
        if nativeWidget && renderingMode != .fullColor { return .primary }
        switch node.color {
        case "accent": return .teal
        case "secondary": return .secondary
        case "green": return .green
        case "red": return .red
        case "orange": return .orange
        case "blue": return .blue
        default: return .primary
        }
    }
    private var fontWeight: Font.Weight {
        switch node.weight { case "bold": return .bold; case "semibold": return .semibold; case "medium": return .medium; default: return .regular }
    }
    private var children: [LayoutNode] { node.children ?? [] }
    private func child(_ index: Int) -> ComponentView { ComponentView(node: children[index], nativeWidget: nativeWidget) }
    private var spacing: CGFloat { CGFloat(min(32, max(0, node.spacing ?? 8))) }
    private var fontSize: CGFloat { CGFloat(min(64, max(8, node.size ?? 13))) }

    @ViewBuilder private var content: some View {
        switch node.type {
        case "column":
            VStack(alignment: node.alignment == "center" ? .center : .leading, spacing: spacing) {
                ForEach(children.indices, id: \.self) { index in AnyView(child(index)) }
            }.frame(maxWidth: .infinity, alignment: node.alignment == "center" ? .center : .leading)
        case "row":
            HStack(alignment: .center, spacing: spacing) {
                ForEach(children.indices, id: \.self) { index in AnyView(child(index)) }
            }
        case "text":
            Text(node.text ?? "").font(.system(size: fontSize, weight: fontWeight))
                .foregroundStyle(foreground).monospacedDigit().lineLimit(nativeWidget ? 3 : 8)
                .minimumScaleFactor(0.7).fixedSize(horizontal: false, vertical: true)
                .widgetAccentable(node.color == "accent")
        case "metric":
            HStack {
                if let symbol = node.symbol { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18) }
                Text(node.label ?? "").foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(node.text ?? "—").fontWeight(.medium).monospacedDigit().foregroundStyle(foreground)
            }.font(.system(size: fontSize))
        case "progress":
            let progress = ProgressView(value: min(max(node.value ?? 0, 0), max(node.max ?? 100, 0.001)), total: max(node.max ?? 100, 0.001))
            if nativeWidget {
                progress.progressViewStyle(WidgetProgressStyle(color: foreground))
                    .accessibilityLabel(node.label ?? "进度")
            } else {
                progress.tint(foreground).accessibilityLabel(node.label ?? "进度")
            }
        case "symbol":
            Image(systemName: node.symbol ?? "square.grid.2x2").font(.system(size: fontSize, weight: fontWeight)).foregroundStyle(foreground)
        case "divider": Divider()
        case "spacer": Spacer(minLength: CGFloat(max(0, min(node.size ?? 0, 40))))
        case "chart":
            Sparkline(values: node.values ?? [], color: foreground).frame(height: CGFloat(max(20, min(node.size ?? 42, 120))))
        case "link":
            if let string = node.url, let url = URL(string: string), ["https", "http", "deskkit"].contains(url.scheme ?? "") {
                Link(node.text ?? "打开", destination: url).font(.system(size: fontSize))
            } else { Text(node.text ?? "").font(.system(size: fontSize)) }
        default: EmptyView()
        }
    }
}

private struct WidgetProgressStyle: ProgressViewStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        let fraction = min(1, max(0, configuration.fractionCompleted ?? 0))
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Widget recoloring preserves alpha; RGB differences alone can disappear.
                Capsule().fill(.primary).opacity(0.18)
                Capsule().fill(color)
                    .frame(width: geometry.size.width * fraction)
                    .widgetAccentable()
            }
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { geometry in
            let peak = max(values.max() ?? 1, 1)
            Path { path in
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: geometry.size.width * Double(index) / Double(max(values.count - 1, 1)),
                                        y: geometry.size.height * (1 - min(1, max(0, value / peak))))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }.stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }.accessibilityLabel("最近采样趋势")
    }
}
