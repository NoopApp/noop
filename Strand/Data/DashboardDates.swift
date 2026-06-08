import Foundation
import WhoopStore

/// Calendar anchors for dashboard surfaces. "Today" and trailing windows are based on
/// the device's actual local date, not the newest imported row in the local database.
enum DashboardDates {
    static func todayKey(now: Date = Date(), calendar: Calendar = .current) -> String {
        dayFormatter.string(from: calendar.startOfDay(for: now))
    }

    static func row(for days: [DailyMetric], day: String = todayKey()) -> DailyMetric? {
        days.first { $0.day == day }
    }

    static func row(for days: [AppleDaily], day: String = todayKey()) -> AppleDaily? {
        days.first { $0.day == day }
    }

    static func throughDay(_ days: [DailyMetric], day: String = todayKey()) -> [DailyMetric] {
        days.filter { $0.day <= day }.sorted { $0.day < $1.day }
    }

    static func trailingWindow(_ days: [DailyMetric], ending day: String = todayKey(), count: Int) -> [DailyMetric] {
        guard count > 0, let start = startDayKey(ending: day, count: count) else { return [] }
        return days
            .filter { $0.day >= start && $0.day <= day }
            .sorted { $0.day < $1.day }
    }

    static func trailingWindow(
        _ points: [(day: String, value: Double)],
        ending day: String = todayKey(),
        count: Int
    ) -> [(day: String, value: Double)] {
        guard count > 0, let start = startDayKey(ending: day, count: count) else { return [] }
        return points.filter { $0.day >= start && $0.day <= day }
    }

    private static func startDayKey(ending day: String, count: Int) -> String? {
        guard let end = dayFormatter.date(from: day),
              let start = Calendar.current.date(byAdding: .day, value: -(count - 1), to: end)
        else { return nil }
        return dayFormatter.string(from: start)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
