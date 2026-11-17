import SwiftUI
import UsageCore

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16) ?? 0x8e8e93
        self.init(.sRGB, red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}

enum Palette {
    static let ok = Color(hex: "#30d158")
    static let amber = Color(hex: "#ff9f0a")
    static let red = Color(hex: "#ff453a")

    static func level(_ used: Double?, full: Double = Levels.full) -> Color {
        guard let used else { return .secondary }
        return used >= full ? red : used >= Levels.high ? amber : ok
    }

    /// Colour for "left" figures: green when plenty remains.
    static func remaining(_ left: Double?) -> Color {
        guard let left else { return .secondary }
        return left <= 100 - Levels.full ? red : left <= 100 - Levels.high ? amber : ok
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct Pill: View {
    var text: String
    var color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.16), in: Capsule())
    }
}

struct Badge: View {
    var identity: AccountIdentity
    var size: CGFloat = 22

    var body: some View {
        Text(identity.letter)
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hex: identity.color).gradient, in: RoundedRectangle(cornerRadius: size * 0.3,
                                                                                  style: .continuous))
    }
}

/// A segmented level bar with a tick where an even pace would be.
struct SegmentBar: View {
    var used: Double?
    var even: Double?
    var color: Color
    var segments = 20

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                let lit = used.map { Double(index) < ($0 / 100 * Double(segments)).rounded() } ?? false
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(lit ? AnyShapeStyle(color) : AnyShapeStyle(Color.primary.opacity(0.1)))
                    .overlay {
                        if let even, Int(even / 100 * Double(segments)) == index, even > 0 {
                            RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.primary.opacity(0.8), lineWidth: 1)
                        }
                    }
            }
        }
        .frame(height: 8)
    }
}

/// A slim capsule level bar.
struct CapsuleBar: View {
    var used: Double?
    var color: Color
    var even: Double?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if let used, used > 0 {
                    Capsule().fill(color.gradient)
                        .frame(width: max(3, geometry.size.width * min(1, used / 100)))
                }
                if let even {
                    Capsule().fill(Color.primary.opacity(0.85))
                        .frame(width: 2, height: geometry.size.height + 4)
                        .offset(x: geometry.size.width * min(1, even / 100) - 1)
                }
            }
        }
        .frame(height: 6)
    }
}

struct StatTile: View {
    var value: String
    var label: String
    var color: Color = .primary
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            if let detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

struct Callout: View {
    var symbol: String
    var color: Color
    var text: String

    var body: some View {
        Label {
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 11, weight: .semibold))
        }
    }
}

struct ActionButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = .accentColor
    /// Sized to its label instead of filling the row.
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: compact ? nil : .infinity)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(prominent ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

extension View {
    func sectionTitle() -> some View {
        font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(nil)
    }
}
