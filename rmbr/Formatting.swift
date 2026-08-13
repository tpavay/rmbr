import Foundation

/// Dumb string helpers. The whole interface is a monospaced text view, so everything
/// here exists only to make columns line up.
enum Fmt {

    static let calendar = Calendar.current

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    static let timeOnly = formatter("HH:mm:ss")
    static let timeShort = formatter("HH:mm")
    static let dateOnly = formatter("yyyy-MM-dd")
    static let dateTime = formatter("yyyy-MM-dd HH:mm:ss")
    static let dateTimeShort = formatter("yyyy-MM-dd HH:mm")

    static func date(_ d: Date?) -> String {
        guard let d else { return "-" }
        return dateOnly.string(from: d)
    }

    static func stamp(_ d: Date?) -> String {
        guard let d else { return "-" }
        return dateTime.string(from: d)
    }

    static func time(_ d: Date?) -> String {
        guard let d else { return "-" }
        return timeOnly.string(from: d)
    }

    /// "1h 23m" / "4m 06s" / "12s"
    static func duration(_ t: TimeInterval?) -> String {
        guard let t, t.isFinite else { return "-" }
        let total = Int(t.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
        if m > 0 { return "\(m)m \(String(format: "%02d", s))s" }
        return "\(s)s"
    }

    static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    static func padLeft(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }

    static func num(_ n: Int, _ width: Int = 0) -> String {
        let s = n.formatted(.number.grouping(.never))
        return width > 0 ? padLeft(s, width) : s
    }

    /// Percentage of `n` out of `total`, or "-" when there is nothing to divide by.
    static func pct(_ n: Int, of total: Int, width: Int = 0) -> String {
        guard total > 0 else { return width > 0 ? padLeft("-", width) : "-" }
        let s = "\(Int((Double(n) / Double(total) * 100).rounded()))%"
        return width > 0 ? padLeft(s, width) : s
    }

    static func rule(_ title: String) -> String {
        "== \(title.uppercased()) " + String(repeating: "=", count: max(0, 44 - title.count))
    }
}
