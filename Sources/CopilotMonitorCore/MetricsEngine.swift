import Foundation

public enum UsagePeriod: String, CaseIterable, Sendable {
    case today, sevenDays, thirtyDays, cycle
    public var title: String {
        switch self {
        case .today: return "Hoje"
        case .sevenDays: return "7d"
        case .thirtyDays: return "30d"
        case .cycle: return "Ciclo"
        }
    }
}

public struct UsageDelta: Sendable, Equatable {
    public let sample: UsageSample
    public let amount: Double
    public let duringAbsence: Bool
    public let previousTimestamp: Int64?
}

public struct InferredSession: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let credits: Double
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public struct UsageBucket: Sendable, Equatable {
    public let date: Date
    public let observed: Double
    public let duringAbsence: Double
}

public struct UsageMetrics: Sendable {
    public let deltas: [UsageDelta]
    public let periodTotal: Double
    public let yesterdayTotal: Double
    public let cycleUsed: Double
    public let entitlement: Double
    public let remaining: Double
    public let overage: Double
    public let expectedNow: Double
    public let paceDifference: Double
    public let projectedAtReset: Double?
    public let recent24HourRate: Double?
    public let projectedAtResetLast24Hours: Double?
    public let exhaustionDate: Date?
    public let weekdayBudget: Double?
    public let burnLastHour: Double
    public let burnLast15Minutes: Double
    public let sessions: [InferredSession]
    public let buckets: [UsageBucket]
    public let selectedStart: Date
    public let selectedEnd: Date
    public let isHourlyChart: Bool
}

public enum MetricsEngine {
    public static func deltas(samples: [UsageSample], gapLimit: TimeInterval = 600) -> [UsageDelta] {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        return ordered.enumerated().map { index, sample in
            guard index > 0 else {
                return UsageDelta(sample: sample, amount: 0, duringAbsence: false, previousTimestamp: nil)
            }
            let previous = ordered[index - 1]
            let reset = sample.resetDate != previous.resetDate || sample.used < previous.used - 1
            let amount = reset ? sample.used : max(0, sample.used - previous.used)
            return UsageDelta(
                sample: sample, amount: amount,
                duringAbsence: TimeInterval(sample.timestamp - previous.timestamp) > gapLimit,
                previousTimestamp: previous.timestamp
            )
        }
    }

    public static func sessions(from deltas: [UsageDelta], gapLimit: TimeInterval = 600) -> [InferredSession] {
        let positive = deltas.filter { $0.amount > 0 && !$0.duringAbsence }
        guard let first = positive.first else { return [] }
        var result: [InferredSession] = []
        var start = Date(timeIntervalSince1970: TimeInterval(first.previousTimestamp ?? first.sample.timestamp))
        var end = first.sample.date
        var credits = first.amount
        var previous = first
        for event in positive.dropFirst() {
            if TimeInterval(event.sample.timestamp - previous.sample.timestamp) <= gapLimit {
                end = event.sample.date
                credits += event.amount
            } else {
                result.append(InferredSession(start: start, end: end, credits: credits))
                start = Date(timeIntervalSince1970: TimeInterval(event.previousTimestamp ?? event.sample.timestamp))
                end = event.sample.date
                credits = event.amount
            }
            previous = event
        }
        result.append(InferredSession(start: start, end: end, credits: credits))
        return result
    }

    public static func analyze(
        samples: [UsageSample], now: Date = Date(), assignedDate: Date, resetDate: Date,
        entitlement: Double, period: UsagePeriod = .today, periodOffset: Int = 0,
        gapLimit: TimeInterval = 600, sessionGap: TimeInterval = 600,
        calendar: Calendar = .current
    ) -> UsageMetrics {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        let allDeltas = deltas(samples: ordered, gapLimit: gapLimit)
        let cycleStart = calendar.date(byAdding: .month, value: -1, to: resetDate) ?? resetDate
        let paceStart = max(cycleStart, assignedDate)
        let currentResetKey = ordered.last?.resetDate ?? ""
        let cycleSamples = ordered.filter { $0.resetDate == currentResetKey }
        let currentUsed = cycleSamples.last?.used ?? 0
        let selected = dateRange(
            period, offset: periodOffset, now: now, cycleStart: cycleStart,
            resetDate: resetDate, calendar: calendar
        )
        let periodDeltas = allDeltas.filter { $0.sample.date >= selected.start && $0.sample.date < selected.end }
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!
        let yesterday = allDeltas.filter {
            $0.sample.date >= yesterdayStart && $0.sample.date < todayStart
        }.reduce(0) { $0 + $1.amount }

        let elapsed = max(0, now.timeIntervalSince(paceStart))
        let cycleDuration = max(1, resetDate.timeIntervalSince(paceStart))
        let expected = entitlement * min(1, elapsed / cycleDuration)
        let usedAtPaceStart = cycleSamples.last(where: { $0.date <= paceStart })?.used ?? currentUsed
        let hoursSincePaceStart = elapsed / 3600
        let paceRate = hoursSincePaceStart > 0
            ? max(0, currentUsed - usedAtPaceStart) / hoursSincePaceStart : nil
        let hoursUntilReset = max(0, resetDate.timeIntervalSince(now) / 3600)
        let projection = paceRate.map { currentUsed + $0 * hoursUntilReset }
        let lastDayUse = allDeltas.filter {
            $0.sample.date > now.addingTimeInterval(-86400) && $0.sample.date <= now && !$0.duringAbsence
        }.reduce(0) { $0 + $1.amount }
        let remaining = entitlement - currentUsed
        let exhausted = paceRate.flatMap { rate -> Date? in
            guard rate > 0 else { return nil }
            let hours = max(0, remaining) / rate
            return hours < hoursUntilReset ? now.addingTimeInterval(hours * 3600) : nil
        }
        let weekdays = weekdayCount(from: todayStart, through: resetDate, calendar: calendar)
        let hourAgo = now.addingTimeInterval(-3600)
        let quarterAgo = now.addingTimeInterval(-900)
        let burn60 = allDeltas.filter {
            $0.sample.date > hourAgo && $0.sample.date <= now && !$0.duringAbsence
        }.reduce(0) { $0 + $1.amount }
        let burn15 = allDeltas.filter {
            $0.sample.date > quarterAgo && $0.sample.date <= now && !$0.duringAbsence
        }.reduce(0) { $0 + $1.amount } * 4

        return UsageMetrics(
            deltas: allDeltas,
            periodTotal: periodDeltas.reduce(0) { $0 + $1.amount },
            yesterdayTotal: yesterday, cycleUsed: currentUsed, entitlement: entitlement,
            remaining: remaining, overage: max(0, currentUsed - entitlement),
            expectedNow: expected, paceDifference: currentUsed - expected,
            projectedAtReset: projection,
            recent24HourRate: lastDayUse > 0 ? lastDayUse / 24 : nil,
            projectedAtResetLast24Hours: lastDayUse > 0
                ? currentUsed + (lastDayUse / 24) * hoursUntilReset : nil,
            exhaustionDate: exhausted,
            weekdayBudget: weekdays > 0 ? max(0, remaining) / Double(weekdays) : nil,
            burnLastHour: burn60, burnLast15Minutes: burn15,
            sessions: sessions(from: periodDeltas, gapLimit: sessionGap),
            buckets: makeBuckets(periodDeltas, hourly: period == .today, calendar: calendar),
            selectedStart: selected.start, selectedEnd: selected.end,
            isHourlyChart: period == .today
        )
    }

    public static func weekdayCount(from start: Date, through end: Date, calendar: Calendar = .current) -> Int {
        guard start <= end else { return 0 }
        var day = calendar.startOfDay(for: start)
        let finalDay = calendar.startOfDay(for: end)
        var count = 0
        while day <= finalDay {
            let weekday = calendar.component(.weekday, from: day)
            if weekday != 1 && weekday != 7 { count += 1 }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return count
    }

    private static func dateRange(
        _ period: UsagePeriod, offset: Int, now: Date, cycleStart: Date,
        resetDate: Date, calendar: Calendar
    ) -> (start: Date, end: Date) {
        switch period {
        case .today:
            let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
            return (start, calendar.date(byAdding: .day, value: 1, to: start)!)
        case .sevenDays:
            let reference = calendar.date(byAdding: .day, value: 7 * offset, to: now)!
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference))!
            return (calendar.date(byAdding: .day, value: -7, to: end)!, end)
        case .thirtyDays:
            let reference = calendar.date(byAdding: .month, value: offset, to: now)!
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference))!
            return (calendar.date(byAdding: .day, value: -29, to: end)!, end)
        case .cycle:
            return (
                calendar.date(byAdding: .month, value: offset, to: cycleStart)!,
                calendar.date(byAdding: .month, value: offset, to: resetDate)!
            )
        }
    }

    private static func makeBuckets(_ deltas: [UsageDelta], hourly: Bool, calendar: Calendar) -> [UsageBucket] {
        struct Totals { var observed = 0.0; var absent = 0.0 }
        var grouped: [Date: Totals] = [:]
        for delta in deltas {
            let date = hourly
                ? (calendar.dateInterval(of: .hour, for: delta.sample.date)?.start ?? calendar.startOfDay(for: delta.sample.date))
                : calendar.startOfDay(for: delta.sample.date)
            if delta.duringAbsence { grouped[date, default: Totals()].absent += delta.amount }
            else { grouped[date, default: Totals()].observed += delta.amount }
        }
        return grouped.keys.sorted().map { date in
            let totals = grouped[date]!
            return UsageBucket(date: date, observed: totals.observed, duringAbsence: totals.absent)
        }
    }
}
