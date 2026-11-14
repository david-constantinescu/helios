import SwiftUI

// MARK: - Liquid Glass design layer
//
// On iOS 26+ everything uses Apple's real Liquid Glass (`glassEffect`, `.glass` button styles, the floating
// glass tab bar). On earlier systems the same views fall back to a frosted material with a specular edge so the
// app keeps the same shape and hierarchy.

enum DesignFlags {
    /// Real Liquid Glass cards on iOS 26+ (launch with -solidCards for solid grouped fills).
    static var glassCards = !ProcessInfo.processInfo.arguments.contains("-solidCards")
}

extension View {
    /// Content card. Apple reserves Liquid Glass for the controls layer (tab bar, toolbars, sheets, floating buttons),
    /// so content sits on solid grouped fills; `DesignFlags.glassCards` switches cards to real glass for comparison.
    @ViewBuilder
    func glassSurface(_ radius: CGFloat = 26, tint: Color? = nil, interactive: Bool = false) -> some View {
        if DesignFlags.glassCards, #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint?.opacity(0.35)).interactive(interactive),
                             in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay { if let tint { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint.opacity(0.16)) } }
            }
        }
    }

    /// A capsule-shaped glass surface (chips, pills, floating controls).
    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint?.opacity(0.4)).interactive(interactive), in: Capsule())
        } else {
            self.background(Capsule().fill(.ultraThinMaterial))
                .background(Capsule().fill((tint ?? .clear).opacity(0.18)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
        }
    }

    /// Glass circle (icon buttons).
    @ViewBuilder
    func glassCircle(tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint?.opacity(0.4)).interactive(), in: Circle())
        } else {
            self.background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
        }
    }

    /// Apple-style ambient backdrop: black with soft coloured light behind the content, so glass has something to refract.
    func ambient(_ colors: [Color] = [.blue, .indigo]) -> some View {
        background(AmbientBackground(colors: colors).ignoresSafeArea())
    }

    /// Native glass button styles with a pre-iOS 26 fallback.
    @ViewBuilder
    func glassButton(prominent: Bool = false, tint: Color = .blue) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { self.buttonStyle(.glassProminent).tint(tint) } else { self.buttonStyle(.glass) }
        } else {
            if prominent { self.buttonStyle(.borderedProminent).tint(tint).buttonBorderShape(.capsule) }
            else { self.buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.white) }
        }
    }
}

struct AmbientBackground: View {
    var colors: [Color]
    var body: some View {
        ZStack {
            Color.black
            GeometryReader { g in
                let c0 = colors.first ?? .blue, c1 = colors.count > 1 ? colors[1] : c0
                Circle().fill(c0.opacity(0.32)).frame(width: g.size.width * 1.1).blur(radius: 100)
                    .offset(x: -g.size.width * 0.35, y: -g.size.width * 0.55)
                Circle().fill(c1.opacity(0.24)).frame(width: g.size.width * 0.95).blur(radius: 110)
                    .offset(x: g.size.width * 0.45, y: -g.size.width * 0.25)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Settings-style coloured icon square (as in Apple Health / Settings).
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Grouped glass list container with hairline separators (Apple "inset grouped" look).
struct GlassList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .glassSurface(24)
    }
}

struct GlassDivider: View {
    var inset: CGFloat = 60
    var body: some View { Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.leading, inset) }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.title3.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Capsule chip; selected chips are solid white like Apple's filter chips.
struct GlassChip: View {
    let text: String
    var selected = false
    var color: Color? = nil
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(selected ? .black : (color ?? .white))
            .background { if selected { Capsule().fill(.white) } }
            .modifier(ConditionalGlassCapsule(enabled: !selected, tint: color))
    }
}

struct ConditionalGlassCapsule: ViewModifier {
    let enabled: Bool
    let tint: Color?
    func body(content: Content) -> some View {
        if enabled { content.glassCapsule(tint: tint) } else { content }
    }
}

/// Status ring used on the hero card and gauges.
struct StatusRing: View {
    let level: Level
    var fraction: Double = 0.66
    var size: CGFloat = 76
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.12), lineWidth: size * 0.12)
            Circle().trim(from: 0, to: fraction)
                .stroke(level.color.gradient, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: level.ringSymbol).font(.system(size: size * 0.34, weight: .bold)).foregroundStyle(level.color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Level {
    var ringSymbol: String {
        switch self {
        case .unknown: return "questionmark"
        case .ok: return "checkmark"
        case .watch: return "eye.fill"
        case .act: return "exclamationmark"
        case .escalate: return "exclamationmark.2"
        }
    }
    /// Human headline used across the redesign.
    var headline: String {
        switch self {
        case .unknown: return "Getting to know you"
        case .ok: return "All clear"
        case .watch: return "Keep an eye on"
        case .act: return "Take action"
        case .escalate: return "Contact your flight surgeon"
        }
    }
    var ambient: [Color] {
        switch self {
        case .ok: return [.green, .teal]
        case .watch: return [.yellow, .blue]
        case .act: return [.orange, .pink]
        case .escalate: return [.red, .orange]
        case .unknown: return [.blue, .indigo]
        }
    }
}

/// Wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, w: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); w = max(w, x)
        }
        return CGSize(width: min(w, maxW), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

/// Region → SF Symbol + colour (Apple Health-like categories).
enum RegionStyle {
    static func symbol(_ id: String) -> String {
        switch id {
        case "brain": return "brain.head.profile"
        case "eyes": return "eye"
        case "heart": return "heart.fill"
        case "lungs": return "lungs.fill"
        case "gut": return "fork.knife"
        case "bones_muscle": return "figure.strengthtraining.traditional"
        case "immune_skin": return "allergens"
        default: return "atom"
        }
    }
    static func color(_ id: String) -> Color {
        switch id {
        case "brain": return .indigo
        case "eyes": return .cyan
        case "heart": return .pink
        case "lungs": return .teal
        case "gut": return .green
        case "bones_muscle": return .orange
        case "immune_skin": return .mint
        default: return .purple
        }
    }
    static func short(_ id: String) -> String {
        switch id {
        case "brain": return "Mind"
        case "eyes": return "Eyes"
        case "heart": return "Heart"
        case "lungs": return "Lungs"
        case "gut": return "Nutrition"
        case "bones_muscle": return "Muscle & bone"
        case "immune_skin": return "Immune"
        default: return "Radiation"
        }
    }
}

enum MetricStyle {
    static func symbol(_ id: String) -> String {
        switch id {
        case "heart_rate", "heart_rate_resting": return "heart.fill"
        case "hrv": return "waveform.path.ecg"
        case "bp_sys", "bp_dia": return "heart.text.square.fill"
        case "glucose": return "drop.fill"
        case "body_temp", "wrist_temp": return "thermometer.medium"
        case "spo2": return "lungs.fill"
        case "resp_rate": return "wind"
        case "sleep_hours", "sleep_quality": return "bed.double.fill"
        case "mood": return "face.smiling"
        case "stress", "workload": return "brain.head.profile"
        case "appetite", "water_l": return "fork.knife"
        case "exercise_min", "activity_steps": return "figure.run"
        case "weight": return "scalemass.fill"
        case "rad_dose_rate", "rad_dose_cum", "rad_cpm": return "atom"
        case "cabin_co2", "cabin_temp": return "aqi.medium"
        case "vo2max", "walking_hr", "hr_recovery": return "heart.circle.fill"
        case "active_kcal", "resting_kcal", "diet_kcal": return "flame.fill"
        case "distance_km", "six_min_walk", "walking_speed", "step_length": return "figure.walk"
        case "cycling_km": return "figure.outdoor.cycle"
        case "swim_m": return "figure.pool.swim"
        case "flights", "stair_up_speed", "stair_down_speed": return "figure.stairs"
        case "stand_min", "stand_hours": return "figure.stand"
        case "daylight_min", "uv_index": return "sun.max.fill"
        case "workout_min": return "dumbbell.fill"
        case "mindful_min": return "brain"
        case "noise_db", "headphone_db", "loud_noise_events": return "ear.fill"
        case "body_fat", "bmi", "lean_mass", "height_cm", "waist_cm": return "figure"
        case "sleep_deep_h", "sleep_rem_h", "sleep_core_h", "sleep_awake_h", "in_bed_h": return "bed.double.fill"
        case "breathing_disturbances", "sleep_apnea_events", "fvc", "fev1", "pef", "inhaler_uses": return "lungs.fill"
        case "falls", "walking_steadiness", "walking_asymmetry", "double_support": return "figure.fall"
        case "caffeine_mg": return "cup.and.saucer.fill"
        case "handwashing": return "hands.sparkles.fill"
        default:
            switch AppConfig.shared.metric(id)?.group {
            case "Heart": return "heart.fill"
            case "Nutrition": return "fork.knife"
            case "Activity": return "figure.run"
            default: return "cross.case.fill"
            }
        }
    }
    static func color(_ id: String) -> Color {
        switch id {
        case "heart_rate", "heart_rate_resting", "bp_sys", "bp_dia": return .pink
        case "hrv": return .indigo
        case "glucose", "appetite", "water_l": return .green
        case "body_temp", "wrist_temp": return .orange
        case "spo2", "resp_rate": return .teal
        case "sleep_hours", "sleep_quality": return .purple
        case "mood", "stress", "workload": return .indigo
        case "exercise_min", "activity_steps", "weight": return .orange
        case "rad_dose_rate", "rad_dose_cum", "rad_cpm": return .yellow
        default:
            switch AppConfig.shared.metric(id)?.group {
            case "Heart": return .pink
            case "Activity": return .orange
            case "Mobility": return .orange
            case "Nutrition", "Metabolism": return .green
            case "Breathing": return .teal
            case "Sleep & mind": return .purple
            case "Body": return .mint
            case "Hearing & environment": return .cyan
            default: return .blue
            }
        }
    }
}

extension String {
    /// Config text without its review marker, sentence-cased.
    var cleanedStep: String {
        let t = replacingOccurrences(of: "PLACEHOLDER: ", with: "")
        return t.prefix(1).uppercased() + t.dropFirst()
    }
}
