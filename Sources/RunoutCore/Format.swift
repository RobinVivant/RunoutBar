import Foundation

public enum Format {
    /// "2d 9h", "23h 40m", "12m", "40s".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let days = s / 86_400, hours = s % 86_400 / 3600, minutes = s % 3600 / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(s)s"
    }

    /// A wait that ticks: "2m 40s", "40s". From ten minutes up, as `duration`.
    public static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        if s >= 600 { return duration(seconds) }
        return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
    }

    public static func until(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let delta = date.timeIntervalSince(now)
        return delta <= 0 ? "now" : duration(delta)
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    /// "Sat 21:00".
    public static func dayTime(_ date: Date) -> String { formatter("EEE HH:mm").string(from: date) }

    /// "Sat 28 Nov".
    public static func day(_ date: Date) -> String { formatter("EEE d MMM").string(from: date) }

    /// "12:13".
    public static func time(_ date: Date) -> String { formatter("HH:mm").string(from: date) }

    /// "12:13:05".
    public static func timeSeconds(_ date: Date) -> String { formatter("HH:mm:ss").string(from: date) }

    /// "51%".
    public static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    /// "126M", "3.1M", "896K", "19K", "812".
    public static func count(_ value: Double) -> String {
        let units: [(Double, String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (scale, suffix) in units where value >= scale {
            let scaled = value / scale
            return (scaled >= 100 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
                .replacingOccurrences(of: ".0", with: "")) + suffix
        }
        return String(Int(value))
    }

    /// "claude-opus-5-5" → "Opus 5.5".
    public static func modelName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().prefix { Int($0) != nil && $0.count <= 2 }.joined(separator: ".")
        return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
    }
}
