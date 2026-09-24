import Foundation

public enum DemoData {
    public static func make(now: Date = Date(), calendar: Calendar = .current) -> (samples: [UsageSample], snapshot: UsageSnapshot) {
        let resetDate = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now))!
        let cycleStart = calendar.date(byAdding: .month, value: -1, to: resetDate)!
        let assignedDate = calendar.date(byAdding: .day, value: 2, to: cycleStart)!
        let key = resetKey(resetDate)
        var timestamp = Int64(now.addingTimeInterval(-21 * 86400).timeIntervalSince1970)
        let end = Int64(now.timeIntervalSince1970)
        var used = 320.0
        var samples = [UsageSample(timestamp: timestamp, used: used, entitlement: 4000, overage: 0, resetDate: key)]
        var index = 0
        while timestamp + 300 <= end {
            timestamp += 300
            index += 1
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let parts = calendar.dateComponents([.day, .hour, .minute], from: date)
            let day = parts.day ?? 0
            let hour = parts.hour ?? 0
            let minute = parts.minute ?? 0
            if day % 4 == 0 && hour == 12 && [0, 5, 10].contains(minute) { continue }
            var increment = 0.0
            let active = (hour >= 9 && hour < 12) || (hour >= 14 && hour < 18)
            if active && minute % 10 == 0 { increment = Double(2 + index % 7) }
            if abs(date.timeIntervalSince(now.addingTimeInterval(-2 * 3600))) < 150 { increment += 55 }
            used += increment
            samples.append(UsageSample(
                timestamp: timestamp, used: used, entitlement: 4000,
                overage: max(0, used - 4000), resetDate: key
            ))
        }
        return (samples, UsageSnapshot(
            login: "demo-user", plan: "business", assignedDate: assignedDate,
            resetDate: resetDate, resetDateKey: key, entitlement: 4000,
            quotaRemaining: 4000 - used, used: used, overage: max(0, used - 4000),
            timestamp: now, rawJSON: Data("{\"demo\":true}".utf8)
        ))
    }

    private static func resetKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
