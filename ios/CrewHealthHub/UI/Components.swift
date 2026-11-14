import SwiftUI

// MARK: - Design tokens (PART 8.1)

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255) }
    static let bg = Color(hex: 0x0B0F17)
    static let elev1 = Color(hex: 0x121826)
    static let elev2 = Color(hex: 0x1A2234)
    static let line = Color(hex: 0x263048)
    static let text = Color(hex: 0xE8EDF7)
    static let dim = Color(hex: 0x9AA6BF)
    static let accent = Color(hex: 0x5AC8FA)
    static let warm = Color(hex: 0xFFB347)
    static let ok = Color(hex: 0x3DDC97)
    static let watch = Color(hex: 0xFFD166)
    static let act = Color(hex: 0xFF9F4A)
    static let escalate = Color(hex: 0xFF5D73)
    static let unknown = Color(hex: 0x7F8AA3)
}

extension Level {
    var color: Color {
        switch self { case .unknown: return .unknown; case .ok: return .ok; case .watch: return .watch; case .act: return .act; case .escalate: return .escalate }
    }
}

// MARK: - Status

/// Colour + icon + text, always (never colour alone).
struct StatusChip: View {
    let level: Level
    var compact = false
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: level.symbol).imageScale(.small)
            if !compact { Text(level.label).font(.caption.weight(.semibold)) }
        }
        .padding(.horizontal, compact ? 6 : 8).padding(.vertical, 4)
        .background(level.color.opacity(0.18), in: Capsule())
        .foregroundStyle(level.color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status \(level.label)")
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .glassSurface(24)
    }
}

struct SectionTitle: View {
    let text: String
    var trailing: AnyView? = nil
    init(_ text: String, trailing: AnyView? = nil) { self.text = text; self.trailing = trailing }
    var body: some View {
        HStack {
            Text(text).font(.headline).foregroundStyle(Color.text).accessibilityAddTraits(.isHeader)
            Spacer()
            trailing
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var color: Color = .accent
    var body: some View {
        GeometryReader { g in
            let vs = values.filter { $0.isUsable }
            if vs.count >= 2, let lo = vs.min(), let hi = vs.max() {
                let span = max(hi - lo, 1e-9)
                Path { p in
                    for (i, v) in vs.enumerated() {
                        let pt = CGPoint(x: g.size.width * CGFloat(i) / CGFloat(vs.count - 1), y: g.size.height * (1 - CGFloat((v - lo) / span)))
                        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                    }
                }.stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

struct GaugeRing: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 10
    var body: some View {
        ZStack {
            Circle().stroke(Color.elev2, lineWidth: lineWidth)
            Circle().trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

struct EmptyState: View {
    let icon: String
    let text: String
    var action: (String, () -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Color.dim)
            Text(text).font(.subheadline).foregroundStyle(Color.dim).multilineTextAlignment(.center)
            if let (label, f) = action { Button(label, action: f).buttonStyle(.borderedProminent) }
        }
        .frame(maxWidth: .infinity).padding(24)
    }
}

struct Bullets: View {
    let title: String
    let items: [String]
    var icon = "circle.fill"
    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.text)
                ForEach(items, id: \.self) { t in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon).font(.system(size: 5)).foregroundStyle(Color.dim).padding(.top, 2)
                        Text(t).font(.subheadline).foregroundStyle(Color.text.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

struct LabeledValue: View {
    let label: String
    let value: String
    var body: some View {
        HStack { Text(label).foregroundStyle(Color.dim); Spacer(); Text(value).foregroundStyle(Color.text).monospacedDigit() }
            .font(.subheadline)
    }
}

extension View {
    func screenBackground() -> some View { self.ambient() }
}

func relativeText(_ d: Date?, to now: Date = Date()) -> String {
    guard let d else { return "never" }
    let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: now)
}

func regionIcon(_ id: String) -> String { AppConfig.shared.region(id)?.icon ?? "circle" }
