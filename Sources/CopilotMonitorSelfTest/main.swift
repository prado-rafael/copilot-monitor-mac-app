import CopilotMonitorCore
import Foundation

@main
struct CopilotMonitorSelfTest {
    static func main() {
        do {
            try testDeltasBaselineResetAndAbsence()
            try testSessionGrouping()
            try testPaceProjectionAndWeekdays()
            try testAPIParsing()
            try testSQLitePersistence()
            try testDemoData()
            print("CopilotMonitorSelfTest: todos os testes passaram.")
        } catch {
            fputs("CopilotMonitorSelfTest: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func testDeltasBaselineResetAndAbsence() throws {
        let start: Int64 = 1_000_000
        let samples = [
            sample(start, 100, "reset-a"),
            sample(start + 300, 110, "reset-a"),
            sample(start + 1200, 125, "reset-a"),
            sample(start + 1500, 130, "reset-a"),
            sample(start + 1800, 2, "reset-b")
        ]
        let deltas = MetricsEngine.deltas(samples: samples)
        try check(deltas.map(\.amount) == [0, 10, 15, 5, 2], "delta baseline/reset")
        try check(!deltas[0].duringAbsence && deltas[2].duringAbsence, "gap marker")
    }

    private static func testSessionGrouping() throws {
        let start: Int64 = 2_000_000
        let samples = [
            sample(start, 0, "r"),
            sample(start + 300, 3, "r"),
            sample(start + 600, 8, "r"),
            sample(start + 900, 8, "r"),
            sample(start + 1200, 8, "r"),
            sample(start + 1500, 11, "r")
        ]
        let deltas = MetricsEngine.deltas(samples: samples)
        let sessions = MetricsEngine.sessions(from: deltas)
        try check(sessions.count == 2, "session grouping")
        try check(sessions[0].credits == 8, "session credits")
        try check(sessions[0].start.timeIntervalSince1970 == TimeInterval(start), "session start")
    }

    private static func testPaceProjectionAndWeekdays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = date("2026-09-21T12:00:00Z")
        let assigned = now.addingTimeInterval(-10 * 3600)
        let reset = now.addingTimeInterval(10 * 3600)
        let samples = [
            UsageSample(timestamp: Int64(assigned.timeIntervalSince1970), used: 0, entitlement: 100, overage: 0, resetDate: "r"),
            UsageSample(timestamp: Int64(now.addingTimeInterval(-5 * 3600).timeIntervalSince1970), used: 40, entitlement: 100, overage: 0, resetDate: "r"),
            UsageSample(timestamp: Int64(now.timeIntervalSince1970), used: 80, entitlement: 100, overage: 0, resetDate: "r")
        ]
        let metrics = MetricsEngine.analyze(
            samples: samples, now: now, assignedDate: assigned, resetDate: reset,
            entitlement: 100, calendar: calendar
        )
        try check(abs(metrics.expectedNow - 50) < 0.01, "linear pace")
        try check(abs(metrics.paceDifference - 30) < 0.01, "pace difference")
        try check(abs((metrics.projectedAtReset ?? 0) - 160) < 0.01, "reset projection")
        try check(metrics.exhaustionDate != nil, "exhaustion date")
        let monday = date("2026-09-21T00:00:00Z")
        let friday = date("2026-09-25T00:00:00Z")
        try check(MetricsEngine.weekdayCount(from: monday, through: friday, calendar: calendar) == 5, "weekday count")
    }

    private static func testAPIParsing() throws {
        let json = """
        {
          "login":"demo",
          "copilot_plan":"business",
          "assigned_date":"2026-09-23T09:53:58-03:00",
          "quota_reset_date_utc":"2026-10-01T00:00:00.000Z",
          "quota_snapshots":{
            "chat":{"unlimited":true,"entitlement":0,"remaining":0},
            "premium_interactions":{"entitlement":4000,"quota_remaining":3036.4,"credits_used":964}
          }
        }
        """
        let parsed = try GitHubResponseParser.parse(Data(json.utf8))
        try check(abs(parsed.used - 963.6) < 0.001, "precise quota remaining")
        try check(parsed.login == "demo" && parsed.plan == "business", "profile fields")
    }

    private static func testSQLitePersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotMonitorSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteUsageStore(url: directory.appendingPathComponent("usage.sqlite"))
        let expected = sample(1_700_000_000, 12.5, "reset")
        try store.append(expected)
        try store.setMetadata(Data("etag-value".utf8), forKey: "etag")
        let savedSample = try store.latestSample()
        let savedETag = try store.metadata(forKey: "etag")
        try check(savedSample == expected, "SQLite sample persistence")
        try check(savedETag == Data("etag-value".utf8), "SQLite metadata persistence")
    }

    private static func testDemoData() throws {
        let now = date("2026-09-24T13:00:00Z")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let demo = DemoData.make(now: now, calendar: calendar)
        let metrics = MetricsEngine.analyze(
            samples: demo.samples, now: now, assignedDate: demo.snapshot.assignedDate,
            resetDate: demo.snapshot.resetDate, entitlement: demo.snapshot.entitlement,
            calendar: calendar
        )
        try check(demo.samples.count > 5_000, "demo history")
        try check(metrics.periodTotal > 0 && metrics.yesterdayTotal > 0, "demo daily metrics")
        try check(!metrics.sessions.isEmpty, "demo sessions")
        try check(metrics.deltas.contains(where: \.duringAbsence), "demo absence gaps")
        try check(metrics.deltas.contains(where: { $0.amount >= 40 && !$0.duringAbsence }), "demo peak")
    }

    private static func sample(_ timestamp: Int64, _ used: Double, _ reset: String) -> UsageSample {
        UsageSample(timestamp: timestamp, used: used, entitlement: 1000, overage: 0, resetDate: reset)
    }

    private static func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
        guard condition() else {
            throw NSError(
                domain: "CopilotMonitorSelfTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Falhou: \(name)"]
            )
        }
    }
}
