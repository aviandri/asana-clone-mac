import MekariProjectKit
import SwiftUI

/// Display strings for dates and priorities. Pure functions so the hosted tests can cover them.
enum Formatting {
    /// "Today", "Tomorrow", "Yesterday", a weekday within the next 6 days, else "Mar 4" (or "Mar 4, 2027" in another year).
    static func due(_ date: LocalDate, today: LocalDate, calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch date.days(since: today) {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6:
            let f = DateFormatter()
            f.locale = locale
            f.calendar = calendar
            f.setLocalizedDateFormatFromTemplate("EEEE")
            return f.string(from: date.date(in: calendar))
        default:
            let f = DateFormatter()
            f.locale = locale
            f.calendar = calendar
            f.setLocalizedDateFormatFromTemplate(date.year == today.year ? "MMMd" : "yMMMd")
            return f.string(from: date.date(in: calendar))
        }
    }

    static func isOverdue(_ date: LocalDate, today: LocalDate) -> Bool { date < today }

    /// Relative timestamp for stories: "just now", "5 min. ago", "yesterday", …
    static func relative(_ date: Date, now: Date = .now) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }

    /// Basic inline markdown (bold, italic, code, links) as in the web; whitespace and line breaks
    /// are kept as typed. Text that doesn't parse is shown as-is.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

extension Priority {
    var label: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        default: "Other" // Priority is an open enum (unknown BE values)
        }
    }

    var tint: Color {
        switch self {
        case .none: .secondary
        case .low: .blue
        case .medium: .orange
        case .high: .red
        default: .secondary
        }
    }
}
