import Foundation

/// A calendar date without a time or time zone: the BE's date-only `YYYY-MM-DD` (`dueDate`, `startDate`).
///
/// Arithmetic happens on a fixed UTC Gregorian calendar, so results never depend on the Mac's time zone.
/// Only `today(in:)` and `date(in:)` / `init(_:in:)` touch the user's calendar.
public struct LocalDate: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let year: Int
  public let month: Int
  public let day: Int

  /// Callers pass a valid date; `init?(_ string:)` is the validating entry point.
  public init(year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  /// Parses exactly `YYYY-MM-DD` and rejects impossible dates such as `2026-02-30`.
  public init?(_ string: String) {
    let parts = string.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
    let candidate = LocalDate(year: y, month: m, day: d)
    guard let date = candidate.utcDate, LocalDate.utc(date) == candidate else { return nil }
    self = candidate
  }

  /// The date it is now in `calendar`'s time zone.
  public static func today(in calendar: Calendar = .current, now: Date = Date()) -> LocalDate {
    LocalDate(now, in: calendar)
  }

  /// The calendar date of `date` as seen in `calendar`'s time zone.
  public init(_ date: Date, in calendar: Calendar = .current) {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
  }

  /// Midnight of this date in `calendar` (for date pickers).
  public func date(in calendar: Calendar = .current) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
  }

  public func adding(days: Int) -> LocalDate {
    guard let date = utcDate, let moved = LocalDate.gregorianUTC.date(byAdding: .day, value: days, to: date) else { return self }
    return LocalDate.utc(moved)
  }

  /// Whole calendar days from `other` to `self` (positive when `self` is later).
  public func days(since other: LocalDate) -> Int {
    guard let a = other.utcDate, let b = utcDate else { return 0 }
    return LocalDate.gregorianUTC.dateComponents([.day], from: a, to: b).day ?? 0
  }

  public var description: String {
    String(format: "%04d-%02d-%02d", year, month, day)
  }

  public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
    (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
  }

  // MARK: - UTC helpers

  private static let gregorianUTC: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  private var utcDate: Date? {
    LocalDate.gregorianUTC.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
  }

  private static func utc(_ date: Date) -> LocalDate {
    LocalDate(date, in: gregorianUTC)
  }
}

extension LocalDate: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let value = LocalDate(raw) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected YYYY-MM-DD, got \(raw)")
    }
    self = value
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}
