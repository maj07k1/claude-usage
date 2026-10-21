import Foundation
import SwiftUI

// MARK: - Accounts

struct Account: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String = ""
    var email: String?
    var orgId: String?

    var displayName: String {
        if !name.isEmpty { return name }
        return email ?? "Claude account"
    }
}

// MARK: - Live limits (from claude.ai)

struct LimitWindow: Identifiable, Equatable {
    let key: String
    let utilization: Double      // percent, 0...100
    let resetsAt: Date?

    var id: String { key }

    var title: String {
        switch key {
        case "five_hour": return "Current session"
        case "seven_day": return "Weekly · all models"
        case "seven_day_opus": return "Weekly · Opus"
        case "seven_day_sonnet": return "Weekly · Sonnet"
        default:
            return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Length of the rolling window, when we can infer it from the key.
    var length: TimeInterval? {
        if key == "five_hour" { return 5 * 3600 }
        if key.hasPrefix("seven_day") { return 7 * 86400 }
        return nil
    }

    var sortRank: Int {
        switch key {
        case "five_hour": return 0
        case "seven_day": return 1
        case "seven_day_opus": return 2
        case "seven_day_sonnet": return 3
        default: return 10
        }
    }
}

struct AccountUsage {
    var windows: [LimitWindow]
    var fetchedAt: Date
    var raw: String

    func window(_ key: String) -> LimitWindow? { windows.first { $0.key == key } }
}

enum UsageParser {
    static func parse(_ body: String) -> [LimitWindow] {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [LimitWindow] = []
        for (key, value) in obj {
            guard let dict = value as? [String: Any],
                  let util = (dict["utilization"] as? NSNumber)?.doubleValue else { continue }
            let reset = (dict["resets_at"] as? String).flatMap(parseDate)
            out.append(LimitWindow(key: key, utilization: util, resetsAt: reset))
        }
        return out.sorted { ($0.sortRank, $0.key) < ($1.sortRank, $1.key) }
    }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        if let d = fractional.date(from: s) ?? whole.date(from: s) { return d }
        // Microsecond precision ("...00.943648+00:00") trips the parser; drop the fraction.
        let stripped = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return whole.date(from: stripped)
    }
}

// MARK: - History

/// One recorded reading of an account's limits.
struct Snapshot: Codable {
    var t: Date
    var acct: UUID
    var w: [String: Double]      // window key -> utilization %
    var r: [String: Date]        // window key -> reset time
}

/// One 5-hour limit window reconstructed from snapshots.
struct LimitSession: Identifiable {
    let id: String
    let start: Date
    let end: Date
    let peak: Double
}

// MARK: - App info

/// Release metadata, read from Info.plist so forks and releases can set it without code changes
/// (see build.sh). Links are nil, and hidden in the UI, until configured.
enum AppInfo {
    private static func string(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var version: String { string("CFBundleShortVersionString") ?? "dev" }
    static var sourceURL: URL? { string("ClaudeUsageSourceURL").flatMap(URL.init(string:)) }
    static var tipJarURL: URL? { string("ClaudeUsageTipJarURL").flatMap(URL.init(string:)) }
}

// MARK: - Settings

enum MenuBarMode: String, CaseIterable, Identifiable {
    case session, weekly, both, iconOnly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .session: return "Session %"
        case .weekly: return "Weekly %"
        case .both: return "Session · Weekly"
        case .iconOnly: return "Icon only"
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.98, green: 0.36, blue: 0.32)
    static let palette: [Color] = [
        Color(red: 0.98, green: 0.36, blue: 0.32), .blue, .green, .orange, .purple, .teal, .pink,
    ]

    static func level(_ pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .green
    }
}

// MARK: - Formatting

enum Fmt {
    static func money(_ v: Double) -> String {
        v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
    }

    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
        if d >= 1e3 { return String(format: "%.0fK", d / 1e3) }
        return "\(n)"
    }

    static func duration(_ s: TimeInterval) -> String {
        let m = max(0, Int(s / 60))
        if m >= 1440 { return "\(m / 1440)d \((m % 1440) / 60)h" }
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }

    static func resetText(_ date: Date?) -> String {
        guard let date else { return "Reset time unknown" }
        let remaining = date.timeIntervalSinceNow
        if remaining <= 0 { return "Resetting…" }
        if remaining < 24 * 3600 { return "Resets in \(duration(remaining))" }
        return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    /// Whole numbers, abbreviated past 10,000 ("12.3K").
    static func count(_ n: Int) -> String {
        n >= 10_000 ? tokens(n) : n.formatted()
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    static func shortDate(_ d: Date) -> String { shortDateFormatter.string(from: d) }

    static func dayTime(_ d: Date) -> String {
        d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
