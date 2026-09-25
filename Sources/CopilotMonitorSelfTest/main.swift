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
            try testTrendAndStats()
            try testBudgetStates()
            try testActiveSession()
            try testProjectionFallbackAndCycleComparison()
            try testDailyTotalsAndContribution()
            try testUsageReport()
            try testCycleBoundariesInUTC()
            try testDailyBudgetOnResetDay()
            try testFallbackProjectionNotBelowUsed()
            try testThirtyDayWindows()
            try testPreviousWindowNeedsLoadedHistory()
            try testDemoSeedAcrossMidnight()
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

    private static func testTrendAndStats() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // 15–24 set 2026 (UTC). 15–19 ativos (5 dias), 20 sem uso, 21–24 ativos (4 dias).
        // Janela anterior de 7d (11–17 set) soma 40; janela atual (18–24 set) soma 120, pico em 21 set (segunda).
        // A leitura-base de 10 set (sem consumo) deixa a janela anterior inteira no histórico carregado;
        // sem ela, a comparação seria com uma janela parcial e `previousTotal` sairia nil.
        let amounts: [Double] = [30, 4, 6, 10, 20, 0, 50, 30, 4, 6]
        let firstDay = date("2026-09-15T10:00:00Z")
        var used = 0.0
        var samples = [sample(at: "2026-09-10T10:00:00Z", 0, "r")]
        for (index, amount) in amounts.enumerated() {
            let dayStart = Int64(firstDay.addingTimeInterval(Double(index) * 86400).timeIntervalSince1970)
            samples.append(sample(dayStart, used, "r"))
            used += amount
            samples.append(sample(dayStart + 300, used, "r"))
        }
        let now = date("2026-09-24T15:30:00Z")
        func analyze(_ period: UsagePeriod, at moment: Date = now) -> UsageMetrics {
            MetricsEngine.analyze(
                samples: samples, now: moment, assignedDate: date("2026-09-01T00:00:00Z"),
                resetDate: date("2026-10-01T00:00:00Z"), entitlement: 1000, period: period,
                calendar: calendar
            )
        }

        let week = analyze(.sevenDays)
        try check(week.trend.total == 120 && week.trend.previousTotal == 40, "trend totals")
        try check(abs((week.trend.deltaPercent ?? 0) - 200) < 0.001, "trend delta percent")
        try check(week.trend.peak?.date == date("2026-09-21T00:00:00Z") && week.trend.peak?.total == 50, "trend peak")
        try check(week.trend.activeBuckets == 6 && abs(week.trend.averagePerBucket - 120.0 / 7) < 0.001, "trend average")
        try check(week.stats.activeDays == 6 && week.stats.elapsedDays == 7, "active days")
        try check(week.stats.mostActiveWeekday == 2 && week.stats.mostActiveWeekdayCredits == 50, "most active weekday")
        try check(week.stats.peakDay?.date == date("2026-09-21T00:00:00Z"), "peak day")
        try check(week.stats.sessionCount == 6 && week.stats.averagePerSession == 20, "session stats")
        try check(week.stats.costliestSession?.credits == 50, "costliest session")
        try check(week.stats.currentStreak == 4 && week.stats.longestStreak == 5, "streaks")

        let month = analyze(.thirtyDays)
        // Janela de 30 dias exatos (26 ago – 24 set): "Dias ativos 9 de 30".
        try check(month.stats.activeDays == 9 && month.stats.elapsedDays == 30, "active days 30d")
        try check(month.stats.mostActiveWeekday == 3 && month.stats.mostActiveWeekdayCredits == 60, "weekday aggregation")
        try check(month.trend.previousTotal == nil && month.trend.deltaPercent == nil, "no previous window")

        let today = analyze(.today)
        try check(today.trend.total == 6 && abs(today.trend.averagePerBucket - 6.0 / 16) < 0.001, "hourly average")
        try check(today.trend.peak?.date == date("2026-09-24T10:00:00Z"), "hourly peak")
        try check(abs((today.trend.deltaPercent ?? 0) - 50) < 0.001, "vs yesterday")

        let nextMorning = analyze(.today, at: date("2026-09-25T09:00:00Z"))
        try check(nextMorning.stats.currentStreak == 4 && nextMorning.stats.longestStreak == 5, "streak from yesterday")
    }

    private static func testBudgetStates() throws {
        try check(BudgetStatus(limit: 100, spent: 79).state == .ok, "budget ok")
        try check(BudgetStatus(limit: 100, spent: 80).state == .warning, "budget warning")
        try check(BudgetStatus(limit: 100, spent: 100).state == .over, "budget over")
        let zero = BudgetStatus(limit: 0, spent: 0)
        try check(zero.state == .over && zero.percent == 0, "budget zero limit")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Ontem +50; hoje +10 observado e +20 durante ausência (total 30). Usado 130 de 1000.
        let samples = [
            sample(Int64(date("2026-09-23T10:00:00Z").timeIntervalSince1970), 50, "r"),
            sample(Int64(date("2026-09-23T10:05:00Z").timeIntervalSince1970), 100, "r"),
            sample(Int64(date("2026-09-24T09:00:00Z").timeIntervalSince1970), 100, "r"),
            sample(Int64(date("2026-09-24T09:05:00Z").timeIntervalSince1970), 110, "r"),
            sample(Int64(date("2026-09-24T09:30:00Z").timeIntervalSince1970), 130, "r")
        ]
        func analyze(_ budget: DailyBudgetSetting) -> UsageMetrics {
            MetricsEngine.analyze(
                samples: samples, now: date("2026-09-24T15:00:00Z"),
                assignedDate: date("2026-09-01T00:00:00Z"), resetDate: date("2026-10-01T00:00:00Z"),
                entitlement: 1000, period: .sevenDays, dailyBudget: budget, calendar: calendar
            )
        }
        let automatic = analyze(.automatic)
        // Qui 24 set → qui 1 out: 6 dias úteis. weekdayBudget = restante 870 / 6 = 145;
        // automático = saldo no início do dia (870 + 30) / 6 = 150.
        try check(automatic.weekdayBudget.map { abs($0 - 145) < 0.001 } ?? false, "weekday budget")
        try check(automatic.dailyBudget.map { abs($0.limit - 150) < 0.001 } ?? false, "automatic budget limit")
        try check(automatic.dailyBudget?.spent == 30 && automatic.periodTotal == 80, "budget spent is today only")
        try check(automatic.dailyBudget?.state == .ok, "automatic budget state")
        try check(analyze(.manual(30)).dailyBudget?.state == .over, "manual budget over")
        try check(analyze(.off).dailyBudget == nil, "budget off")
        try check(automatic.cycleBudget == BudgetStatus(limit: 1000, spent: 130), "cycle budget")

        try check(DailyBudgetSetting(mode: nil, credits: 0) == .automatic, "budget mode default")
        let settings = MonitorSettings(
            dailyBudgetMode: DailyBudgetSetting.manual(120).mode, dailyBudgetCredits: 120,
            sessionGapMinutes: 10, peakThreshold: 40
        )
        let encoded = try JSONEncoder().encode(settings)
        let keys = (try JSONSerialization.jsonObject(with: encoded) as? [String: Any]).map { Set($0.keys) }
        try check(keys == ["dailyBudgetMode", "dailyBudgetCredits", "sessionGapMinutes", "peakThreshold"], "settings keys")
        let decoded = try JSONDecoder().decode(MonitorSettings.self, from: encoded)
        try check(decoded == settings && decoded.dailyBudget == .manual(120), "settings round trip")
    }

    private static func testActiveSession() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Leituras a cada 5 min. Sessão A: 23:30–23:35 (+5). Sessão B atravessa a meia-noite:
        // 23:50–00:05 (+4, +3, +6 = 13), último delta positivo às 00:05.
        let used: [Double] = [0, 5, 5, 5, 5, 9, 12, 18]
        let first = Int64(date("2026-09-23T23:30:00Z").timeIntervalSince1970)
        let samples = used.enumerated().map { index, value in sample(first + Int64(index) * 300, value, "r") }
        let deltas = MetricsEngine.deltas(samples: samples)
        let lastPositive = date("2026-09-24T00:05:00Z")

        let active = MetricsEngine.activeSession(from: deltas, now: lastPositive.addingTimeInterval(300), gapLimit: 600)
        try check(active?.credits == 13, "active session credits")
        try check(active?.start == date("2026-09-23T23:50:00Z") && active?.end == lastPositive, "active session bounds")
        let expired = MetricsEngine.activeSession(from: deltas, now: lastPositive.addingTimeInterval(1200), gapLimit: 600)
        try check(expired == nil, "active session expired")

        func analyze(at moment: Date, sessionGap: TimeInterval = 600) -> UsageMetrics {
            MetricsEngine.analyze(
                samples: samples, now: moment, assignedDate: date("2026-09-01T00:00:00Z"),
                resetDate: date("2026-10-01T00:00:00Z"), entitlement: 1000, period: .today,
                sessionGap: sessionGap, calendar: calendar
            )
        }
        // `Hoje` só vê 00:00–00:05 (+9), mas a sessão ativa usa todos os deltas.
        let today = analyze(at: lastPositive.addingTimeInterval(300))
        try check(today.activeSession?.credits == 13 && today.sessions.last?.credits == 9, "active session over all deltas")
        try check(today.sessions.last?.end == today.activeSession?.end, "active session matches period session")
        try check(analyze(at: lastPositive.addingTimeInterval(1200)).activeSession == nil, "analyze active session expired")
        // Com intervalo de 30 min, A e B viram uma sessão e 20 min depois ainda está ativa.
        try check(analyze(at: lastPositive.addingTimeInterval(1200), sessionGap: 1800).activeSession?.credits == 18, "active session uses session gap")

        // O demo precisa exibir a sessão ativa a qualquer hora, inclusive nas lacunas das 12h de dias múltiplos de 4.
        for moment in ["2026-09-24T13:00:00Z", "2026-09-24T12:12:00Z", "2026-09-24T03:07:30Z"].map(date) {
            let demo = DemoData.make(now: moment, calendar: calendar)
            let deltas = MetricsEngine.deltas(samples: demo.samples)
            try check(MetricsEngine.activeSession(from: deltas, now: moment, gapLimit: 600) != nil, "demo active session")
            try check(demo.snapshot.used < demo.snapshot.entitlement, "demo below entitlement")
        }
    }

    private static func testProjectionFallbackAndCycleComparison() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        // Cenário 1: 1% decorrido (1h de 100h desde a atribuição). Linear daria 20 + 20 cr/h × 99h e
        // esgotaria antes do reset; o fallback usa o ciclo anterior de maior chave < a atual, escalado.
        let now = date("2026-09-21T12:00:00Z")
        let assigned = now.addingTimeInterval(-3600)
        let reset = now.addingTimeInterval(99 * 3600)
        let fresh = [
            sample(Int64(assigned.timeIntervalSince1970), 0, "2026-10-01"),
            sample(Int64(now.timeIntervalSince1970), 20, "2026-10-01")
        ]
        let previousCycles = [
            CycleSummary(resetDate: "2026-08-01", entitlement: 1000, used: 999),
            CycleSummary(resetDate: "2026-09-01", entitlement: 800, used: 600),
            CycleSummary(resetDate: "2026-11-01", entitlement: 1000, used: 10)
        ]
        func analyzeFresh(_ cycles: [CycleSummary]) -> UsageMetrics {
            MetricsEngine.analyze(
                samples: fresh, now: now, assignedDate: assigned, resetDate: reset,
                entitlement: 1000, previousCycles: cycles, calendar: calendar
            )
        }
        let early = analyzeFresh(previousCycles)
        try check(early.projectionSource == .previousCycle, "fallback projection source")
        try check(early.previousCycle == previousCycles[1], "previous cycle selection")
        try check(abs((early.projectedAtReset ?? 0) - 750) < 0.001, "fallback scaled projection")
        try check(early.exhaustionDate == nil, "fallback without exhaustion date")
        try check(early.previousCycleAtSamePoint == nil && early.deltaVsPreviousCyclePercent == nil, "no previous samples")
        let noHistory = analyzeFresh([])
        try check(noHistory.projectionSource == .previousCycle && noHistory.projectedAtReset == nil, "fallback without previous cycle")

        // Metade do ciclo decorrida, mas sem uso desde `paceStart` → também cai no ciclo anterior.
        let idle = MetricsEngine.analyze(
            samples: [
                sample(Int64(now.addingTimeInterval(-10 * 3600).timeIntervalSince1970), 30, "2026-10-01"),
                sample(Int64(now.timeIntervalSince1970), 30, "2026-10-01")
            ],
            now: now, assignedDate: now.addingTimeInterval(-10 * 3600), resetDate: now.addingTimeInterval(10 * 3600),
            entitlement: 1000, previousCycles: previousCycles, calendar: calendar
        )
        try check(idle.projectionSource == .previousCycle && idle.exhaustionDate == nil, "fallback without usage")

        // Sem leitura até `paceStart` (a primeira chega depois do reset), a base é 0 e a projeção é linear.
        let lateStart = MetricsEngine.analyze(
            samples: [
                sample(Int64(now.addingTimeInterval(-5 * 3600).timeIntervalSince1970), 40, "2026-10-01"),
                sample(Int64(now.timeIntervalSince1970), 50, "2026-10-01")
            ],
            now: now, assignedDate: now.addingTimeInterval(-10 * 3600), resetDate: now.addingTimeInterval(10 * 3600),
            entitlement: 1000, previousCycles: previousCycles, calendar: calendar
        )
        try check(lateStart.projectionSource == .linear, "linear projection source")
        try check(abs((lateStart.projectedAtReset ?? 0) - 100) < 0.001, "linear projection from zero baseline")

        // Cenário 2: ciclo atual 1–30 set (reset 1 out), agora = 11 set 00:00 → 10 dias decorridos.
        // Ciclo anterior 1–31 ago: no mesmo ponto (11 ago 00:00) a última leitura tinha 50; o atual tem 60.
        let currentKey = "2026-10-01T00:00:00Z"
        let previousKey = "2026-09-01T00:00:00Z"
        let history = [
            sample(Int64(date("2026-08-05T00:00:00Z").timeIntervalSince1970), 20, previousKey),
            sample(Int64(date("2026-08-10T00:00:00Z").timeIntervalSince1970), 50, previousKey),
            sample(Int64(date("2026-08-12T00:00:00Z").timeIntervalSince1970), 70, previousKey),
            sample(Int64(date("2026-08-31T23:55:00Z").timeIntervalSince1970), 400, previousKey),
            sample(Int64(date("2026-09-01T00:00:00Z").timeIntervalSince1970), 0, currentKey),
            sample(Int64(date("2026-09-11T00:00:00Z").timeIntervalSince1970), 60, currentKey)
        ]
        let previous = CycleSummary(resetDate: previousKey, entitlement: 1000, used: 400)
        let compared = MetricsEngine.analyze(
            samples: history, now: date("2026-09-11T00:00:00Z"), assignedDate: date("2026-07-01T00:00:00Z"),
            resetDate: date("2026-10-01T00:00:00Z"), entitlement: 1000, period: .cycle,
            previousCycles: [previous], calendar: calendar
        )
        try check(compared.projectionSource == .linear, "linear after minimum elapsed fraction")
        try check(compared.previousCycle == previous && compared.previousCycle?.overage == 0, "previous cycle summary")
        try check(compared.previousCycleAtSamePoint == 50, "previous cycle at same point")
        try check(abs((compared.deltaVsPreviousCyclePercent ?? 0) - 20) < 0.001, "delta vs previous cycle")
        let decoded = try JSONDecoder().decode(CycleSummary.self, from: JSONEncoder().encode(previous))
        try check(decoded == previous, "cycle summary codable")

        // SQLite: backfill deriva o último `used` de cada ciclo fechado sem sobrescrever o que já existe.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotMonitorSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteUsageStore(url: directory.appendingPathComponent("usage.sqlite"))
        for stored in [sample(100, 10, "a"), sample(200, 30, "a"), sample(300, 5, "b"), sample(400, 2, "c")] {
            try store.append(stored)
        }
        try store.upsertCycle(CycleSummary(resetDate: "b", entitlement: 1000, used: 999), closedAt: Date())
        try store.backfillCycles(excluding: "c")
        let backfilled = [
            CycleSummary(resetDate: "a", entitlement: 1000, used: 30),
            CycleSummary(resetDate: "b", entitlement: 1000, used: 999)
        ]
        let afterBackfill = try store.cycles()
        try check(afterBackfill == backfilled, "SQLite cycles backfill")
        try store.upsertCycle(CycleSummary(resetDate: "b", entitlement: 1200, used: 7), closedAt: Date())
        try store.backfillCycles(excluding: "c")
        let afterUpsert = try store.cycles()
        try check(afterUpsert == [backfilled[0], CycleSummary(resetDate: "b", entitlement: 1200, used: 7)], "SQLite cycles upsert")
    }

    private static func testDailyTotalsAndContribution() throws {
        // UTC−3: o dia local não coincide com o dia UTC, então o agrupamento precisa usar o calendário.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -3 * 3600)!
        // +100 em 10 set (fora dos 7 dias), +10 em 20 set, +20 em 22 set 02:05 UTC = 21 set 23:05 local, +5 hoje (24 set).
        let samples = [
            sample(Int64(date("2026-09-10T12:00:00Z").timeIntervalSince1970), 0, "r"),
            sample(Int64(date("2026-09-10T12:05:00Z").timeIntervalSince1970), 100, "r"),
            sample(Int64(date("2026-09-20T12:00:00Z").timeIntervalSince1970), 100, "r"),
            sample(Int64(date("2026-09-20T12:05:00Z").timeIntervalSince1970), 110, "r"),
            sample(Int64(date("2026-09-22T02:00:00Z").timeIntervalSince1970), 110, "r"),
            sample(Int64(date("2026-09-22T02:05:00Z").timeIntervalSince1970), 130, "r"),
            sample(Int64(date("2026-09-24T12:00:00Z").timeIntervalSince1970), 130, "r"),
            sample(Int64(date("2026-09-24T12:05:00Z").timeIntervalSince1970), 135, "r")
        ]
        let deltas = MetricsEngine.deltas(samples: samples)
        let now = date("2026-09-24T15:00:00Z")
        let week = MetricsEngine.dailyTotals(deltas: deltas, days: 7, endingAt: now, calendar: calendar)
        try check(week.count == 7, "daily totals count")
        try check(week.first?.date == date("2026-09-18T03:00:00Z") && week.last?.date == date("2026-09-24T03:00:00Z"), "daily totals local days")
        try check(zip(week, week.dropFirst()).allSatisfy { $1.date.timeIntervalSince($0.date) == 86400 }, "daily totals consecutive")
        try check(week.map(\.credits) == [0, 0, 10, 20, 0, 0, 5], "daily totals sums and zero fill")
        let month = MetricsEngine.dailyTotals(deltas: deltas, days: 30, endingAt: now, calendar: calendar)
        try check(month.count == 30 && month.reduce(0) { $0 + $1.credits } == 135, "daily totals window")
        try check(MetricsEngine.dailyTotals(deltas: deltas, days: 0, endingAt: now, calendar: calendar).isEmpty, "daily totals empty")

        try check(MetricsEngine.contributionLevel(value: 24, maxValue: 100) == 1, "contribution level 0.24")
        try check(MetricsEngine.contributionLevel(value: 25, maxValue: 100) == 2, "contribution level 0.25")
        try check(MetricsEngine.contributionLevel(value: 50, maxValue: 100) == 3, "contribution level 0.5")
        try check(MetricsEngine.contributionLevel(value: 75, maxValue: 100) == 4, "contribution level 0.75")
        try check(MetricsEngine.contributionLevel(value: 100, maxValue: 100) == 4, "contribution level 1.0")
        try check(MetricsEngine.contributionLevel(value: 0, maxValue: 100) == 0, "contribution level zero value")
        try check(MetricsEngine.contributionLevel(value: 5, maxValue: 0) == 0, "contribution level zero max")

        // Dois dias ativos (30 anteontem, 10 ontem), hoje sem uso: a sequência começa ontem.
        let firstDay = date("2026-09-20T03:00:00Z")
        let days = [0, 0, 30, 10, 0].enumerated().map { index, credits in
            DailyTotal(date: firstDay.addingTimeInterval(Double(index) * 86400), credits: Double(credits))
        }
        let stats = MetricsEngine.contributionStats(days)
        try check(stats.activeDays == 2 && stats.averageActiveDay == 20, "contribution active days")
        try check(stats.peak == days[2], "contribution peak")
        try check(stats.currentStreak == 2, "contribution streak from yesterday")
        try check(MetricsEngine.contributionStats(Array(days.dropLast())).currentStreak == 2, "contribution streak from today")
        let empty = MetricsEngine.contributionStats(days.map { DailyTotal(date: $0.date, credits: 0) })
        try check(empty.activeDays == 0 && empty.averageActiveDay == 0 && empty.peak == nil && empty.currentStreak == 0, "contribution empty")

        // `analyze` usa todos os deltas, mesmo com o período `Hoje`.
        let metrics = MetricsEngine.analyze(
            samples: samples, now: now, assignedDate: date("2026-09-01T00:00:00Z"),
            resetDate: date("2026-10-01T00:00:00Z"), entitlement: 1000, period: .today, calendar: calendar
        )
        try check(metrics.calendarDays.count == 91 && metrics.sparkline.count == 14, "calendar and sparkline sizes")
        try check(metrics.calendarDays.last?.date == date("2026-09-24T03:00:00Z"), "calendar ends today")
        try check(metrics.sparkline == Array(metrics.calendarDays.suffix(14)), "sparkline is last 14 days")
        try check(metrics.calendarDays.reduce(0) { $0 + $1.credits } == 135 && metrics.periodTotal == 5, "calendar over all deltas")

        // O demo precisa ter dias com níveis variados para o calendário e a sparkline.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let demoNow = date("2026-09-24T13:00:00Z")
        let demo = DemoData.make(now: demoNow, calendar: utc)
        let demoDays = MetricsEngine.dailyTotals(
            deltas: MetricsEngine.deltas(samples: demo.samples), days: 91, endingAt: demoNow, calendar: utc
        )
        let demoMax = demoDays.map(\.credits).max() ?? 0
        let demoLevels = Set(demoDays.map { MetricsEngine.contributionLevel(value: $0.credits, maxValue: demoMax) })
        try check(MetricsEngine.contributionStats(demoDays).activeDays > 30, "demo calendar history")
        try check(demoLevels == [0, 1, 2, 3, 4], "demo calendar levels")
    }

    private static func testUsageReport() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Ontem +50; hoje +10 às 09:05, +20 durante ausência às 09:30 e +10 às 14:55 (total 40).
        // Agora 15:00: a sessão 14:50–14:55 ainda está ativa. Usado 140 de 1000.
        let key = "2026-10-01T00:00:00Z"
        let samples = [
            ("2026-09-23T10:00:00Z", 50.0), ("2026-09-23T10:05:00Z", 100), ("2026-09-24T09:00:00Z", 100),
            ("2026-09-24T09:05:00Z", 110), ("2026-09-24T09:30:00Z", 130), ("2026-09-24T14:50:00Z", 130),
            ("2026-09-24T14:55:00Z", 140)
        ].map { sample(Int64(date($0.0).timeIntervalSince1970), $0.1, key) }
        let snapshot = UsageSnapshot(
            login: "demo", plan: "business", assignedDate: date("2026-09-01T00:00:00Z"),
            resetDate: date(key), resetDateKey: key, entitlement: 1000, quotaRemaining: 860, used: 140,
            overage: 0, timestamp: date("2026-09-24T14:55:00Z"), rawJSON: Data()
        )
        let cycles = [CycleSummary(resetDate: "2026-09-01T00:00:00Z", entitlement: 1000, used: 700)]
        let now = date("2026-09-24T15:00:00Z")
        func report(_ budget: DailyBudgetSetting, at moment: Date = now) -> UsageReport {
            let settings = MonitorSettings(
                dailyBudgetMode: budget.mode, dailyBudgetCredits: { if case let .manual(value) = budget { return value }; return 0 }(),
                sessionGapMinutes: 10, peakThreshold: 40
            )
            return UsageReport.make(
                samples: samples, snapshot: snapshot, cycles: cycles, settings: settings, now: moment, calendar: calendar
            )
        }
        func object(_ report: UsageReport) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any] ?? [:]
        }

        let over = report(.manual(30))
        let json = try object(over)
        try check(["cycle", "today", "burn", "streak"].allSatisfy { json[$0] is [String: Any] }, "report sections")
        try check(Set(json.keys) == [
            "generated", "login", "plan", "stale", "lastUpdated", "cycle", "today", "yesterday", "burn",
            "activeSession", "streak"
        ], "report keys")
        let today = json["today"] as? [String: Any]
        let budget = today?["budget"] as? [String: Any]
        try check(budget?["state"] as? String == "over" && budget?["limit"] as? Double == 30, "report budget over")
        try check(today?["credits"] as? Double == 40 && today?["usd"] as? Double == 0.4, "report today")
        try check((json["yesterday"] as? [String: Any])?["credits"] as? Double == 50, "report yesterday")
        try check(json["generated"] as? String == "2026-09-24T15:00:00Z", "report ISO 8601 dates")
        try check(json["lastUpdated"] as? String == "2026-09-24T14:55:00Z" && json["stale"] as? Bool == false, "report fresh")
        let cycle = json["cycle"] as? [String: Any]
        try check(cycle?["used"] as? Double == 140 && cycle?["remaining"] as? Double == 860 && cycle?["percent"] as? Double == 14, "report cycle")
        try check(cycle?["resetDate"] as? String == key && cycle?["projectionSource"] as? String == "linear", "report projection")
        try check(cycle?["previousCycleUsed"] as? Double == 700 && cycle?["exhaustionDate"] is NSNull, "report cycle nulls")
        let session = json["activeSession"] as? [String: Any]
        try check(session?["credits"] as? Double == 10 && session?["minutes"] as? Int == 10, "report active session")
        try check(over.streak.current == 2 && over.streak.longest == 2, "report streak")
        try check(over.burn.lastHour == 10 && over.cycle.budget.state == .ok, "report burn and cycle budget")
        let compact = String(decoding: try over.jsonData(pretty: false), as: UTF8.self)
        let order = ["\"activeSession\"", "\"burn\"", "\"cycle\"", "\"generated\""].compactMap { compact.range(of: $0)?.lowerBound }
        try check(!compact.contains("\n") && order.count == 4 && order == order.sorted(), "report compact sorted keys")
        let decoded = try UsageReport.decode(over.jsonData())
        try check(decoded == over, "report round trip")

        // Orçamento desligado → `budget: null` (chave presente); manual folgado → ok; 80% → warning.
        let off = try object(report(.off))
        try check((off["today"] as? [String: Any])?["budget"] is NSNull, "report budget off is null")
        try check(report(.manual(100)).today.budget?.state == .ok, "report budget ok")
        try check(report(.manual(50)).today.budget?.state == .warning, "report budget warning")
        // 1h depois da última leitura: relatório velho e sem sessão ativa (`null`).
        let late = try object(report(.off, at: now.addingTimeInterval(3600)))
        try check(late["stale"] as? Bool == true && late["activeSession"] is NSNull, "report stale")

        // Semeadura do demo (app e CLI): banco vazio é preenchido; uma leitura recente não é regravada.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotMonitorSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteUsageStore(url: directory.appendingPathComponent("usage-demo.sqlite"))
        let demoNow = date("2026-09-24T13:00:00Z")
        let seeded = try DemoData.seed(store, now: demoNow, calendar: calendar)
        let stored = try store.samples()
        try check(seeded != nil && stored.count > 5_000 && seeded?.used == stored.last?.used, "demo seed")
        let demoCycles = try store.cycles()
        try check(demoCycles.count == 1, "demo seed cycles")
        try DemoData.seed(store, now: demoNow.addingTimeInterval(120), calendar: calendar)
        let reseeded = try store.samples()
        try check(reseeded.count == stored.count, "demo seed keeps fresh data")
        if let seeded {
            let demoReport = UsageReport.make(
                samples: stored, snapshot: seeded, cycles: demoCycles, settings: .defaults,
                now: demoNow, calendar: calendar
            )
            try check(!demoReport.stale && demoReport.activeSession != nil && demoReport.today.budget != nil, "demo report")
        }
    }

    /// Limites de ciclo em UTC. Em São Paulo (UTC−3) o reset 2026-10-01T00:00Z cai em 30 set 21:00 local;
    /// "−1 mês" no calendário local daria 30 ago 21:00 = 31 ago 00:00Z em vez de 1 set 00:00Z.
    private static func testCycleBoundariesInUTC() throws {
        let calendar = zonedCalendar("America/Sao_Paulo")
        let reset = date("2026-10-01T00:00:00Z")
        let key = "2026-10-01T00:00:00Z"
        let previousKey = "2026-09-01T00:00:00Z"
        let assigned = date("2026-07-01T00:00:00Z")
        // 2 h depois do reset, com uso (+30) desde o início do ciclo.
        let now = date("2026-09-01T02:00:00Z")
        let samples = [
            sample(at: "2026-08-31T23:55:00Z", 700, previousKey),
            sample(at: "2026-09-01T00:00:00Z", 0, key),
            sample(at: "2026-09-01T02:00:00Z", 30, key)
        ]
        let previousCycles = [CycleSummary(resetDate: previousKey, entitlement: 1000, used: 700)]
        func analyze(offset: Int) -> UsageMetrics {
            MetricsEngine.analyze(
                samples: samples, now: now, assignedDate: assigned, resetDate: reset, entitlement: 1000,
                period: .cycle, periodOffset: offset, previousCycles: previousCycles, calendar: calendar
            )
        }
        let current = analyze(offset: 0)
        try check(current.selectedStart == date("2026-09-01T00:00:00Z") && current.selectedEnd == reset, "cycle start in UTC")
        let previous = analyze(offset: -1)
        try check(
            previous.selectedStart == date("2026-08-01T00:00:00Z") && previous.selectedEnd == date("2026-09-01T00:00:00Z"),
            "previous cycle range in UTC"
        )
        // 2 h de 720 h = 0,28% < 3% → fallback. Com o início em 31 ago seriam 26 h de 744 h = 3,5% → linear.
        try check(current.projectionSource == .previousCycle && current.exhaustionDate == nil, "fallback 2h into cycle")
        try check(current.projectedAtReset == 700, "fallback 2h into cycle scaled")

        // "Neste ponto do ciclo anterior" também em UTC. Ciclo atual 1–31 out (reset 1 nov), agora = 11 out 00:00Z.
        // O ciclo anterior (chave 2026-10-01) começou em 1 set 00:00Z (no fuso local, "−1 mês" daria 31 ago):
        // no mesmo ponto (11 set 00:00Z) tinha 50, não os 20 de 10 set 00:00Z.
        let novemberKey = "2026-11-01T00:00:00Z"
        let history = [
            sample(at: "2026-09-05T00:00:00Z", 20, key),
            sample(at: "2026-09-10T12:00:00Z", 40, key),
            sample(at: "2026-09-11T00:00:00Z", 50, key),
            sample(at: "2026-09-30T23:55:00Z", 400, key),
            sample(at: "2026-10-01T00:00:00Z", 0, novemberKey),
            sample(at: "2026-10-11T00:00:00Z", 60, novemberKey)
        ]
        let compared = MetricsEngine.analyze(
            samples: history, now: date("2026-10-11T00:00:00Z"), assignedDate: assigned,
            resetDate: date(novemberKey), entitlement: 1000, period: .cycle,
            previousCycles: [CycleSummary(resetDate: key, entitlement: 1000, used: 400)], calendar: calendar
        )
        try check(compared.selectedStart == date("2026-10-01T00:00:00Z"), "november cycle start in UTC")
        try check(compared.previousCycleAtSamePoint == 50, "previous cycle same point in UTC")
        try check(abs((compared.deltaVsPreviousCyclePercent ?? 0) - 20) < 0.001, "delta vs previous cycle in UTC")

        // Demo: reset à meia-noite UTC, como `quota_reset_date_utc`, e a virada das amostras do demo
        // coincide com o início do ciclo calculado pelo `analyze`.
        let demoNow = date("2026-09-24T13:00:00Z")
        let demo = DemoData.make(now: demoNow, calendar: calendar)
        try check(demo.snapshot.resetDate == reset && demo.snapshot.resetDateKey == "2026-10-01", "demo reset at UTC midnight")
        let demoCycle = MetricsEngine.analyze(
            samples: demo.samples, now: demoNow, assignedDate: demo.snapshot.assignedDate,
            resetDate: demo.snapshot.resetDate, entitlement: demo.snapshot.entitlement, period: .cycle, calendar: calendar
        )
        let firstCurrent = demo.samples.first { $0.resetDate == demo.snapshot.resetDateKey }
        try check(firstCurrent?.date == demoCycle.selectedStart && demoCycle.selectedStart == date("2026-09-01T00:00:00Z"), "demo cycle matches analyze")
    }

    /// No dia do reset, o orçamento automático só conta o gasto do ciclo novo: o do ciclo anterior não sai de `remaining`.
    private static func testDailyBudgetOnResetDay() throws {
        let calendar = zonedCalendar("America/Sao_Paulo")
        let oldKey = "2026-10-01T00:00:00Z"
        let newKey = "2026-11-01T00:00:00Z"
        // Quarta, 30 set, em São Paulo: +300 às 09:05 no ciclo antigo; reset às 21:00 local; +10 às 21:05 no novo.
        let samples = [
            sample(at: "2026-09-30T12:00:00Z", 500, oldKey),
            sample(at: "2026-09-30T12:05:00Z", 800, oldKey),
            sample(at: "2026-10-01T00:00:00Z", 0, newKey),
            sample(at: "2026-10-01T00:05:00Z", 10, newKey)
        ]
        let now = date("2026-10-01T00:30:00Z")
        let reset = date(newKey)
        let metrics = MetricsEngine.analyze(
            samples: samples, now: now, assignedDate: date("2026-07-01T00:00:00Z"), resetDate: reset,
            entitlement: 1000, period: .today, dailyBudget: .automatic, calendar: calendar
        )
        // 30 set (qua) a 31 out 21:00 local (sáb): 23 dias úteis.
        let weekdays = MetricsEngine.weekdayCount(from: calendar.startOfDay(for: now), through: reset, calendar: calendar)
        try check(weekdays == 23 && metrics.remaining == 990, "reset day remaining")
        try check(metrics.periodTotal == 310, "reset day KPI keeps both cycles")
        try check(metrics.dailyBudget?.spent == 10, "reset day budget spent is new cycle only")
        try check(metrics.dailyBudget.map { abs($0.limit - (990 + 10) / 23.0) < 0.001 } ?? false, "reset day budget limit")
        try check(metrics.dailyBudget?.state == .ok, "reset day budget not over")
    }

    /// No fallback do ciclo anterior, a projeção nunca fica abaixo do que já foi usado.
    private static func testFallbackProjectionNotBelowUsed() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let key = "2026-10-01T00:00:00Z"
        // 18 h de 720 h = 2,5% < 3%: fallback. Ciclo anterior 600 / 1000 → 600, mas já foram usados 900.
        let metrics = MetricsEngine.analyze(
            samples: [sample(at: "2026-09-01T00:00:00Z", 0, key), sample(at: "2026-09-01T18:00:00Z", 900, key)],
            now: date("2026-09-01T18:00:00Z"), assignedDate: date("2026-07-01T00:00:00Z"), resetDate: date(key),
            entitlement: 1000, previousCycles: [CycleSummary(resetDate: "2026-09-01T00:00:00Z", entitlement: 1000, used: 600)],
            calendar: calendar
        )
        try check(metrics.projectionSource == .previousCycle, "fallback floor source")
        try check(metrics.projectedAtReset == 900, "fallback projection not below used")
    }

    /// A janela de 30d tem exatamente 30 dias e a anterior termina onde ela começa (sem lacuna nem sobreposição).
    private static func testThirtyDayWindows() throws {
        let calendar = zonedCalendar("America/Sao_Paulo")
        // Datas depois de meses de 28, 30 e 31 dias, e perto da meia-noite local e UTC.
        let moments = [
            "2026-01-15T12:00:00Z", "2026-03-01T02:00:00Z", "2026-03-31T15:00:00Z",
            "2026-05-31T23:30:00Z", "2026-07-01T02:59:00Z", "2026-09-24T15:30:00Z", "2026-12-31T20:00:00Z"
        ].map(date)
        for moment in moments {
            let samples = [
                sample(Int64(moment.addingTimeInterval(-200 * 86400).timeIntervalSince1970), 0, "r"),
                sample(Int64(moment.timeIntervalSince1970), 10, "r")
            ]
            func analyze(_ offset: Int) -> UsageMetrics {
                MetricsEngine.analyze(
                    samples: samples, now: moment, assignedDate: date("2025-01-01T00:00:00Z"),
                    resetDate: date("2027-01-01T00:00:00Z"), entitlement: 1000, period: .thirtyDays,
                    periodOffset: offset, calendar: calendar
                )
            }
            let selected = analyze(0)
            let previous = analyze(-1)
            let older = analyze(-2)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: moment))
            try check(selected.selectedEnd == tomorrow, "30d window ends tomorrow")
            try check(selected.selectedEnd.timeIntervalSince(selected.selectedStart) == 30 * 86400, "30d window is 30 days")
            try check(previous.selectedEnd.timeIntervalSince(previous.selectedStart) == 30 * 86400, "previous 30d window is 30 days")
            try check(previous.selectedEnd == selected.selectedStart, "previous 30d window ends at selected start")
            try check(older.selectedEnd == previous.selectedStart, "older 30d window ends at previous start")
            // "Dias ativos X de 30" (antes, "X de 29").
            try check(selected.stats.elapsedDays == 30, "30d elapsed days")
        }

        // Leituras nas bordas (agora 24 set 12:30 local; janela 26 ago 00:00 local – 25 set; anterior 27 jul – 26 ago).
        // Cada delta cai em exatamente uma janela: a borda inicial é inclusiva, a final exclusiva.
        let edges = [
            sample(at: "2026-07-01T00:00:00Z", 0, "r"),
            sample(at: "2026-07-27T02:55:00Z", 100, "r"), // +100: 26 jul 23:55 local, antes da janela anterior
            sample(at: "2026-07-27T03:00:00Z", 103, "r"), // +3: início da janela anterior
            sample(at: "2026-08-26T02:55:00Z", 110, "r"), // +7: último minuto da janela anterior
            sample(at: "2026-08-26T03:00:00Z", 115, "r"), // +5: início da janela atual
            sample(at: "2026-09-24T15:00:00Z", 135, "r") // +20
        ]
        let month = MetricsEngine.analyze(
            samples: edges, now: date("2026-09-24T15:30:00Z"), assignedDate: date("2026-09-01T00:00:00Z"),
            resetDate: date("2026-10-01T00:00:00Z"), entitlement: 1000, period: .thirtyDays, calendar: calendar
        )
        try check(month.selectedStart == date("2026-08-26T03:00:00Z"), "30d window start local midnight")
        try check(month.trend.total == 25 && month.trend.previousTotal == 10, "30d windows split totals at the edges")
        try check(abs((month.trend.deltaPercent ?? 0) - 150) < 0.001, "vs 30d anteriores")
    }

    /// A comparação com a janela anterior só vale quando ela está inteira no histórico carregado.
    private static func testPreviousWindowNeedsLoadedHistory() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Janela de 7d: 18–24 set; anterior: 11–17 set. +40 em 15 set (anterior), +60 em 22 set (atual).
        let tail = [sample(at: "2026-09-15T10:05:00Z", 40, "r"), sample(at: "2026-09-22T10:05:00Z", 100, "r")]
        func week(firstSample: String) -> TrendStats {
            MetricsEngine.analyze(
                samples: [sample(at: firstSample, 0, "r")] + tail, now: date("2026-09-24T15:30:00Z"),
                assignedDate: date("2026-09-01T00:00:00Z"), resetDate: date("2026-10-01T00:00:00Z"),
                entitlement: 1000, period: .sevenDays, calendar: calendar
            ).trend
        }
        // Histórico começa em 14 set 12:00, no meio da janela anterior: sem comparação (não uma soma parcial).
        let partial = week(firstSample: "2026-09-14T12:00:00Z")
        try check(partial.total == 60, "partial history current total")
        try check(partial.previousTotal == nil && partial.deltaPercent == nil, "partial previous window is nil")
        // Primeira leitura exatamente no início da janela anterior, ou antes dele: janela inteira, comparação vale.
        for first in ["2026-09-11T00:00:00Z", "2026-09-10T12:00:00Z"] {
            let full = week(firstSample: first)
            try check(full.previousTotal == 40 && abs((full.deltaPercent ?? 0) - 50) < 0.001, "full previous window")
        }
    }

    /// Semear o demo perto da virada da chave do ciclo não deixa o snapshot com uma chave diferente das amostras.
    private static func testDemoSeedAcrossMidnight() throws {
        let calendar = zonedCalendar("America/Sao_Paulo")
        // 1) 23:55 → 00:03 local (24 → 25 set): antes, o reset do demo era à meia-noite local e a chave virava aqui.
        // 2) 23:55Z → 00:03Z (20:55 → 21:03 local): com o reset à meia-noite UTC, é aqui que a chave vira.
        let cases = [
            (seed: "2026-09-25T02:55:00Z", read: "2026-09-25T03:03:00Z"),
            (seed: "2026-09-24T23:55:00Z", read: "2026-09-25T00:03:00Z")
        ]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotMonitorSelfTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, item) in cases.enumerated() {
            let store = try SQLiteUsageStore(url: directory.appendingPathComponent("usage-demo-\(index).sqlite"))
            try DemoData.seed(store, now: date(item.seed), calendar: calendar)
            let snapshot = try DemoData.seed(store, now: date(item.read), calendar: calendar)
            let last = try store.latestSample()
            try check(snapshot != nil && snapshot?.resetDateKey == last?.resetDate, "demo seed key matches samples (\(index + 1))")
            try check(snapshot?.used == last?.used && snapshot?.timestamp == last?.date, "demo seed snapshot from last sample (\(index + 1))")
            // Nos dois casos a leitura das 00:03 (UTC ou local) é de 25 set UTC: reset em 2 out 00:00Z.
            try check(last?.resetDate == "2026-10-02" && snapshot?.resetDate == date("2026-10-02T00:00:00Z"), "demo reseeds on new key (\(index + 1))")
        }
    }

    private static func sample(_ timestamp: Int64, _ used: Double, _ reset: String) -> UsageSample {
        UsageSample(timestamp: timestamp, used: used, entitlement: 1000, overage: 0, resetDate: reset)
    }

    private static func sample(at iso: String, _ used: Double, _ reset: String) -> UsageSample {
        sample(Int64(date(iso).timeIntervalSince1970), used, reset)
    }

    private static func zonedCalendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
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
