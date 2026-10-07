import ProcopticonCore
import SwiftUI

struct GraphSeries {
    var values: [Double]
    var color: Color
    var label: String = ""
}

/// Scrolling history graph (newest sample on the right).
struct GraphView: View {
    var series: [GraphSeries]
    var maxValue: Double?
    var capacity: Int = 300
    var title: String = ""
    var valueText: String = ""
    var formatter: (Double) -> String = { String(format: "%.1f", $0) }
    var tooltips: [String] = []
    var stacked = false
    @State private var hoverIndex: Int?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                Canvas { context, size in
                    draw(context: context, size: size)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                if !title.isEmpty || !valueText.isEmpty {
                    HStack(spacing: 6) {
                        Text(title).font(.caption.weight(.semibold))
                        Text(valueText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(4)
                }
                if let hoverIndex, let text = hoverText(hoverIndex) {
                    Text(text)
                        .font(.caption.monospacedDigit())
                        .padding(5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let step = geo.size.width / CGFloat(max(1, capacity - 1))
                    let fromRight = Int(((geo.size.width - p.x) / step).rounded())
                    hoverIndex = fromRight
                case .ended:
                    hoverIndex = nil
                }
            }
        }
    }

    private var effectiveMax: Double {
        if let maxValue { return max(maxValue, 0.0001) }
        let m: Double
        if stacked {
            let count = series.map(\.values.count).max() ?? 0
            m = (0..<count).map { i in series.reduce(0) { $0 + ($1.values.indices.contains(i) ? $1.values[i] : 0) } }.max() ?? 0
        } else {
            m = series.flatMap(\.values).max() ?? 0
        }
        return max(m * 1.1, 0.0001)
    }

    private func hoverText(_ fromRight: Int) -> String? {
        var parts: [String] = []
        for s in series {
            let idx = s.values.count - 1 - fromRight
            guard s.values.indices.contains(idx) else { continue }
            parts.append((s.label.isEmpty ? "" : s.label + ": ") + formatter(s.values[idx]))
        }
        let tIdx = tooltips.count - 1 - fromRight
        if tooltips.indices.contains(tIdx), !tooltips[tIdx].isEmpty {
            parts.append(tooltips[tIdx])
        }
        if parts.isEmpty { return nil }
        let seconds = fromRight
        parts.append(seconds == 0 ? "now" : "\(seconds) samples ago")
        return parts.joined(separator: "\n")
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        // Grid
        var grid = Path()
        let gridStep: CGFloat = 12
        var y = size.height
        while y > 0 {
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
            y -= gridStep
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.08)), lineWidth: 0.5)

        let maxV = effectiveMax
        let step = size.width / CGFloat(max(1, capacity - 1))
        var baseline = [Double](repeating: 0, count: series.map(\.values.count).max() ?? 0)
        for s in series {
            let values = s.values
            guard values.count > 1 else { continue }
            let n = values.count
            func point(_ i: Int, _ v: Double) -> CGPoint {
                let x = size.width - CGFloat(n - 1 - i) * step
                let yv = size.height - CGFloat(min(1, max(0, v / maxV))) * (size.height - 2)
                return CGPoint(x: x, y: yv)
            }
            var line = Path()
            var area = Path()
            let first = point(0, values[0] + (stacked ? baseline[0] : 0))
            line.move(to: first)
            area.move(to: CGPoint(x: first.x, y: size.height))
            area.addLine(to: first)
            for i in 1..<n {
                let p = point(i, values[i] + (stacked ? baseline[i] : 0))
                line.addLine(to: p)
                area.addLine(to: p)
            }
            if stacked {
                for i in stride(from: n - 1, through: 0, by: -1) {
                    area.addLine(to: point(i, baseline[i]))
                }
                for i in 0..<n { baseline[i] += values[i] }
            } else {
                area.addLine(to: CGPoint(x: size.width, y: size.height))
            }
            area.closeSubpath()
            context.fill(area, with: .color(s.color.opacity(0.22)))
            context.stroke(line, with: .color(s.color), lineWidth: 1.2)
        }
        if let hoverIndex {
            let x = size.width - CGFloat(hoverIndex) * step
            var marker = Path()
            marker.move(to: CGPoint(x: x, y: 0))
            marker.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(marker, with: .color(.primary.opacity(0.4)), lineWidth: 1)
        }
    }
}

/// Labeled value used in property/info grids.
struct InfoRow: View {
    var label: String
    var value: String
    var selectable = true

    init(_ label: String, _ value: String, selectable: Bool = true) {
        self.label = label
        self.value = value
        self.selectable = selectable
    }

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            if selectable {
                Text(value.isEmpty ? "—" : value)
                    .textSelection(.enabled)
                    .gridColumnAlignment(.leading)
                    .lineLimit(4)
            } else {
                Text(value.isEmpty ? "—" : value).gridColumnAlignment(.leading)
            }
        }
    }
}

struct SectionBox<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        } label: {
            Text(title).font(.headline)
        }
    }
}

struct UsageBar: View {
    var fraction: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(color.gradient).frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}

/// Text field used for list filters: shows a regex toggle and flags invalid patterns.
struct FilterField: View {
    @Binding var text: String
    var prompt: String = "Filter"
    var width: CGFloat = 220
    @ObservedObject private var settings = AppSettings.shared

    init(_ text: Binding<String>, prompt: String = "Filter", width: CGFloat = 220) {
        _text = text
        self.prompt = prompt
        self.width = width
    }

    var body: some View {
        let matcher = settings.matcher(text)
        HStack(spacing: 4) {
            TextField(settings.searchUsesRegex ? prompt + " (regex)" : prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(matcher.isValid ? Color.clear : Color.red, lineWidth: 1.5))
                .help(matcher.error ?? "Plain text matches anywhere. Enable .* or type /pattern/ for a regular expression (/pattern/c is case-sensitive).")
            RegexToggle()
                .toggleStyle(.button)
            if let error = matcher.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(error)
            }
        }
        .frame(maxWidth: width + 50)
    }
}

/// ".*" button that toggles regular-expression search globally. Callers outside the toolbar give it
/// `.toggleStyle(.button)`; toolbar groups apply their own style.
struct RegexToggle: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Toggle(isOn: $settings.searchUsesRegex) {
            Text(".*").font(.system(.body, design: .monospaced).weight(.semibold))
        }
        .help(settings.searchUsesRegex ? "Search text is a regular expression. Click for plain text matching (⌥⌘R)" : "Treat search text as a regular expression (⌥⌘R)")
    }
}
