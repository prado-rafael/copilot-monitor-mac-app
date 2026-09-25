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
    public var total: Double { observed + duringAbsence }
}

public struct TrendStats: Sendable, Equatable {
    /// Soma de observed + duringAbsence dos buckets do período.
    public let total: Double
    /// total / buckets decorridos (horas em `Hoje`, dias nos demais períodos).
    public let averagePerBucket: Double
    /// Bucket com maior total; nil se total == 0.
    public let peak: UsageBucket?
    /// Buckets com total > 0.
    public let activeBuckets: Int
    /// Total do mesmo período com offset − 1; nil se não há deltas lá ou se essa janela começa antes
    /// da primeira leitura carregada (soma parcial).
    public let previousTotal: Double?
    /// (total − previousTotal) / previousTotal × 100; nil se previousTotal é nil ou 0.
    public let deltaPercent: Double?
}

public struct PeriodStats: Sendable, Equatable {
    /// Dias do período com créditos > 0.
    public let activeDays: Int
    /// Dias do período já decorridos (até hoje inclusive), mínimo 1.
    public let elapsedDays: Int
    /// Calendar.weekday (1 = domingo … 7 = sábado) com maior soma no período.
    public let mostActiveWeekday: Int?
    public let mostActiveWeekdayCredits: Double
    /// Dia com maior total no período (sempre buckets diários).
    public let peakDay: UsageBucket?
    public let sessionCount: Int
    /// 0 se não há sessões.
    public let averagePerSession: Double
    public let costliestSession: InferredSession?
    /// Dias ativos consecutivos terminando hoje (ou ontem, se hoje ainda não tem uso).
    public let currentStreak: Int
    /// Maior sequência de dias ativos consecutivos no histórico carregado.
    public let longestStreak: Int
}

/// Total de créditos de um dia local.
public struct DailyTotal: Sendable, Equatable {
    /// Início do dia local.
    public let date: Date
    public let credits: Double

    public init(date: Date, credits: Double) {
        self.date = date
        self.credits = credits
    }
}

public struct ContributionStats: Sendable, Equatable {
    /// Dias com créditos > 0.
    public let activeDays: Int
    /// total / activeDays; 0 se nenhum dia ativo.
    public let averageActiveDay: Double
    /// Dia com mais créditos; nil se nenhum dia ativo.
    public let peak: DailyTotal?
    /// Dias ativos consecutivos terminando hoje (ou ontem, se hoje ainda não tem uso).
    public let currentStreak: Int
}

public enum BudgetState: String, Sendable { case ok, warning, over }

public struct BudgetStatus: Sendable, Equatable {
    public let limit: Double
    public let spent: Double
    public let state: BudgetState
    /// 0 quando `limit` é 0, para não dividir por zero.
    public var percent: Double { limit > 0 ? spent / limit * 100 : 0 }

    /// `spent >= limit` → over; `spent >= limit × warningFraction` → warning; senão ok.
    public init(limit: Double, spent: Double, warningFraction: Double = 0.8) {
        self.limit = limit
        self.spent = spent
        if spent >= limit {
            state = .over
        } else if spent >= limit * warningFraction {
            state = .warning
        } else {
            state = .ok
        }
    }
}

public enum DailyBudgetSetting: Sendable, Hashable {
    case off
    /// = (remaining + gasto de hoje no ciclo atual) / dias úteis até o reset: saldo no início do dia
    /// (ou no reset, se foi hoje), estável ao longo dele.
    case automatic
    case manual(Double)

    /// Valor persistido em `dailyBudgetMode`: `"off" | "auto" | "manual"`.
    public var mode: String {
        switch self {
        case .off: return "off"
        case .automatic: return "auto"
        case .manual: return "manual"
        }
    }

    /// Interpreta `dailyBudgetMode` + `dailyBudgetCredits`. Modo ausente ou desconhecido vira `.automatic`.
    public init(mode: String?, credits: Double) {
        switch mode {
        case "off": self = .off
        case "manual": self = .manual(credits)
        default: self = .automatic
        }
    }
}

/// Origem de `UsageMetrics.projectedAtReset`.
public enum ProjectionSource: Sendable, Equatable {
    /// Ritmo desde o início do ciclo extrapolado até o reset.
    case linear
    /// Ciclo recém-iniciado (ou sem uso ainda): total do ciclo anterior escalado pelo entitlement atual.
    case previousCycle
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
    public let trend: TrendStats
    public let stats: PeriodStats
    /// Orçamento de hoje; nil quando desligado ou quando o automático não é calculável. `spent` conta só os
    /// deltas de hoje do ciclo atual (no dia do reset, difere de `periodTotal` em `Hoje`).
    public let dailyBudget: BudgetStatus?
    /// limit = entitlement, spent = cycleUsed.
    public let cycleBudget: BudgetStatus
    /// Sessão em andamento, calculada sobre todos os deltas (não só o período) com `gapLimit = sessionGap`.
    public let activeSession: InferredSession?
    /// `.previousCycle` quando a projeção vem do ciclo anterior; nil só se não há projeção linear possível.
    public let projectionSource: ProjectionSource?
    /// Ciclo de maior `resetDate` estritamente menor que a chave do ciclo atual.
    public let previousCycle: CycleSummary?
    /// `used` do ciclo anterior no mesmo ponto (tempo desde o início do ciclo); nil sem amostras dele.
    public let previousCycleAtSamePoint: Double?
    /// (cycleUsed − previousCycleAtSamePoint) / previousCycleAtSamePoint × 100, quando o anterior é > 0.
    public let deltaVsPreviousCyclePercent: Double?
    /// Totais diários dos últimos 14 dias (último = hoje), sobre todos os deltas.
    public let sparkline: [DailyTotal]
    /// Totais diários dos últimos 91 dias (último = hoje), sobre todos os deltas.
    public let calendarDays: [DailyTotal]
}

public enum MetricsEngine {
    /// Dias de histórico que o app e o CLI carregam: as 13 semanas do calendário de atividade.
    public static let historyDays = 91

    /// Calendário dos limites de ciclo. `quota_reset_date_utc` é meia-noite UTC, então "1 mês antes do reset"
    /// é calculado em UTC: no fuso local (ex.: UTC−3, reset 1 out 00:00Z = 30 set 21:00), "−1 mês" daria
    /// 30 ago 21:00 local = 31 ago 00:00Z em vez de 1 set 00:00Z. Dias e horas continuam no calendário local.
    static let cycleCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Ciclo que termina em `resetDate` deslocado de `offset` ciclos: `[reset + (offset − 1) meses, reset + offset meses)`
    /// em UTC. As duas bordas partem do mesmo reset, então ciclos vizinhos são contíguos.
    static func cycleRange(resetDate: Date, offset: Int = 0) -> (start: Date, end: Date) {
        (
            cycleCalendar.date(byAdding: .month, value: offset - 1, to: resetDate) ?? resetDate,
            cycleCalendar.date(byAdding: .month, value: offset, to: resetDate) ?? resetDate
        )
    }

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

    /// Última sessão de `sessions(from:gapLimit:)` cujo `end` está a no máximo `gapLimit` de `now`.
    /// Leituras posteriores a `now` são ignoradas, para a resposta valer para o instante pedido.
    public static func activeSession(from deltas: [UsageDelta], now: Date, gapLimit: TimeInterval) -> InferredSession? {
        let upToNow = deltas.filter { $0.sample.date <= now }
        guard let last = sessions(from: upToNow, gapLimit: gapLimit).last,
              now.timeIntervalSince(last.end) <= gapLimit else { return nil }
        return last
    }

    public static func analyze(
        samples: [UsageSample], now: Date = Date(), assignedDate: Date, resetDate: Date,
        entitlement: Double, period: UsagePeriod = .today, periodOffset: Int = 0,
        gapLimit: TimeInterval = 600, sessionGap: TimeInterval = 600,
        dailyBudget: DailyBudgetSetting = .off, previousCycles: [CycleSummary] = [],
        calendar: Calendar = .current
    ) -> UsageMetrics {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        let allDeltas = deltas(samples: ordered, gapLimit: gapLimit)
        let cycleStart = cycleRange(resetDate: resetDate).start
        let paceStart = max(cycleStart, assignedDate)
        let currentResetKey = ordered.last?.resetDate ?? ""
        let cycleSamples = ordered.filter { $0.resetDate == currentResetKey }
        let currentUsed = cycleSamples.last?.used ?? 0
        let selected = dateRange(period, offset: periodOffset, now: now, resetDate: resetDate, calendar: calendar)
        let periodDeltas = allDeltas.filter { $0.sample.date >= selected.start && $0.sample.date < selected.end }
        let todayStart = calendar.startOfDay(for: now)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)!
        let yesterday = allDeltas.filter {
            $0.sample.date >= yesterdayStart && $0.sample.date < todayStart
        }.reduce(0) { $0 + $1.amount }
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart)!
        // Gasto de hoje para o orçamento diário (inclusive ausência), independente do período selecionado.
        // Só deltas do ciclo atual: no dia do reset, o que foi gasto antes dele não sai de `remaining`, e
        // somá-lo inflaria o limite automático e o `spent` (marcando "estourou" logo após o reset).
        let todayCycleTotal = allDeltas.filter {
            $0.sample.date >= todayStart && $0.sample.date < tomorrowStart && $0.sample.resetDate == currentResetKey
        }.reduce(0) { $0 + $1.amount }

        let elapsed = max(0, now.timeIntervalSince(paceStart))
        let cycleDuration = max(1, resetDate.timeIntervalSince(paceStart))
        let expected = entitlement * min(1, elapsed / cycleDuration)
        // Sem leitura do ciclo atual até `paceStart` (a primeira chega depois do reset), a base é 0:
        // o contador zera no reset. Usar `currentUsed` zeraria a taxa e a projeção seria sempre `currentUsed`.
        let usedAtPaceStart = cycleSamples.last(where: { $0.date <= paceStart })?.used ?? 0
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
        let previousCycle = previousCycles
            .filter { $0.resetDate < currentResetKey }
            .max { $0.resetDate < $1.resetDate }
        // Fallback: com menos de 3% do ciclo decorrido, ou sem uso desde `paceStart`, a projeção
        // linear não é confiável; usa o total do ciclo anterior escalado pelo entitlement atual,
        // nunca abaixo do que já foi usado neste ciclo.
        let minimumElapsedFraction = 0.03
        let usePreviousCycle = elapsed / cycleDuration < minimumElapsedFraction
            || max(0, currentUsed - usedAtPaceStart) == 0
        let projectedAtReset: Double?
        let projectionSource: ProjectionSource?
        let exhaustionDate: Date?
        if usePreviousCycle {
            projectedAtReset = previousCycle.flatMap { previous -> Double? in
                previous.entitlement > 0 ? max(currentUsed, previous.used / previous.entitlement * entitlement) : nil
            }
            projectionSource = .previousCycle
            exhaustionDate = nil
        } else {
            projectedAtReset = projection
            projectionSource = projection == nil ? nil : .linear
            exhaustionDate = exhausted
        }
        let previousAtSamePoint = previousCycle.flatMap { previous -> Double? in
            guard let previousEnd = GitHubResponseParser.parseDate(previous.resetDate) else { return nil }
            let previousStart = cycleRange(resetDate: previousEnd).start
            let target = previousStart.addingTimeInterval(now.timeIntervalSince(cycleStart))
            return ordered.last { $0.resetDate == previous.resetDate && $0.date <= target }?.used
        }
        let weekdays = weekdayCount(from: todayStart, through: resetDate, calendar: calendar)
        let weekdayBudget = weekdays > 0 ? max(0, remaining) / Double(weekdays) : nil
        let dailyLimit: Double?
        switch dailyBudget {
        case .off: dailyLimit = nil
        case .automatic:
            // Saldo no início do dia (ou no reset, se foi hoje), para o limite não encolher conforme se gasta hoje.
            dailyLimit = weekdays > 0 ? max(0, remaining + todayCycleTotal) / Double(weekdays) : nil
        case let .manual(credits): dailyLimit = credits
        }
        let hourAgo = now.addingTimeInterval(-3600)
        let quarterAgo = now.addingTimeInterval(-900)
        let burn60 = allDeltas.filter {
            $0.sample.date > hourAgo && $0.sample.date <= now && !$0.duringAbsence
        }.reduce(0) { $0 + $1.amount }
        let burn15 = allDeltas.filter {
            $0.sample.date > quarterAgo && $0.sample.date <= now && !$0.duringAbsence
        }.reduce(0) { $0 + $1.amount } * 4

        let hourly = period == .today
        let buckets = makeBuckets(periodDeltas, hourly: hourly, calendar: calendar)
        let periodSessions = sessions(from: periodDeltas, gapLimit: sessionGap)
        let previous = dateRange(period, offset: periodOffset - 1, now: now, resetDate: resetDate, calendar: calendar)
        // Janela anterior começando antes da primeira leitura carregada daria uma soma parcial: sem comparação.
        let previousLoaded = ordered.first.map { previous.start >= $0.date } ?? false
        let previousDeltas = previousLoaded
            ? allDeltas.filter { $0.sample.date >= previous.start && $0.sample.date < previous.end } : []
        let trend = makeTrendStats(
            buckets: buckets, previousDeltas: previousDeltas,
            elapsedBuckets: elapsedBucketCount(
                period: period, offset: periodOffset, range: selected, now: now, calendar: calendar
            )
        )
        let stats = makePeriodStats(
            periodDeltas: periodDeltas, dailyBuckets: hourly
                ? makeBuckets(periodDeltas, hourly: false, calendar: calendar) : buckets,
            sessions: periodSessions, streak: streaks(deltas: allDeltas, now: now, calendar: calendar),
            elapsedDays: elapsedDayCount(range: selected, now: now, calendar: calendar),
            calendar: calendar
        )
        // `historyDays` = 13 semanas do calendário; a sparkline são os 14 últimos (mesma soma, uma passada só).
        let calendarDays = dailyTotals(deltas: allDeltas, days: historyDays, endingAt: now, calendar: calendar)

        return UsageMetrics(
            deltas: allDeltas,
            periodTotal: periodDeltas.reduce(0) { $0 + $1.amount },
            yesterdayTotal: yesterday, cycleUsed: currentUsed, entitlement: entitlement,
            remaining: remaining, overage: max(0, currentUsed - entitlement),
            expectedNow: expected, paceDifference: currentUsed - expected,
            projectedAtReset: projectedAtReset,
            recent24HourRate: lastDayUse > 0 ? lastDayUse / 24 : nil,
            projectedAtResetLast24Hours: lastDayUse > 0
                ? currentUsed + (lastDayUse / 24) * hoursUntilReset : nil,
            exhaustionDate: exhaustionDate,
            weekdayBudget: weekdayBudget,
            burnLastHour: burn60, burnLast15Minutes: burn15,
            sessions: periodSessions,
            buckets: buckets,
            selectedStart: selected.start, selectedEnd: selected.end,
            isHourlyChart: hourly,
            trend: trend, stats: stats,
            dailyBudget: dailyLimit.map { BudgetStatus(limit: $0, spent: todayCycleTotal) },
            cycleBudget: BudgetStatus(limit: entitlement, spent: currentUsed),
            activeSession: activeSession(from: allDeltas, now: now, gapLimit: sessionGap),
            projectionSource: projectionSource,
            previousCycle: previousCycle,
            previousCycleAtSamePoint: previousAtSamePoint,
            deltaVsPreviousCyclePercent: previousAtSamePoint.flatMap { previous -> Double? in
                previous > 0 ? (currentUsed - previous) / previous * 100 : nil
            },
            sparkline: Array(calendarDays.suffix(14)),
            calendarDays: calendarDays
        )
    }

    /// Sequências de dias ativos (total > 0) sobre todos os deltas, agrupados por dia local.
    /// `current` começa hoje; se hoje ainda não tem uso, começa ontem. Um dia sem leitura quebra a sequência.
    public static func streaks(
        deltas: [UsageDelta], now: Date, calendar: Calendar = .current
    ) -> (current: Int, longest: Int) {
        var totals: [Date: Double] = [:]
        for delta in deltas { totals[calendar.startOfDay(for: delta.sample.date), default: 0] += delta.amount }
        let active = Set(totals.filter { $0.value > 0 }.keys)
        guard !active.isEmpty else { return (0, 0) }
        func shift(_ day: Date, by value: Int) -> Date {
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: value, to: day)!)
        }
        var longest = 0
        var run = 0
        var previousDay: Date?
        for day in active.sorted() {
            if let previousDay, shift(previousDay, by: 1) == day { run += 1 } else { run = 1 }
            longest = max(longest, run)
            previousDay = day
        }
        let today = calendar.startOfDay(for: now)
        var day = active.contains(today) ? today : shift(today, by: -1)
        var current = 0
        while active.contains(day) {
            current += 1
            day = shift(day, by: -1)
        }
        return (current, longest)
    }

    /// Créditos por dia local dos `days` dias terminando em `now`: exatamente `days` elementos,
    /// ordenados, zero nos dias sem leitura, último = hoje. Deltas fora da janela são ignorados.
    public static func dailyTotals(
        deltas: [UsageDelta], days: Int, endingAt now: Date, calendar: Calendar = .current
    ) -> [DailyTotal] {
        guard days > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        // starts[i] = início do dia i; starts[days] = início de amanhã (fim exclusivo da janela).
        let starts = (0...days).map { index in
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: index - (days - 1), to: today)!)
        }
        var credits = Array(repeating: 0.0, count: days)
        for delta in deltas {
            let date = delta.sample.date
            guard date >= starts[0], date < starts[days] else { continue }
            // Busca binária do último início de dia <= date: evita um `startOfDay` por delta.
            var low = 0
            var high = days - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if starts[middle] <= date { low = middle } else { high = middle - 1 }
            }
            credits[low] += delta.amount
        }
        return (0..<days).map { DailyTotal(date: starts[$0], credits: credits[$0]) }
    }

    /// Nível de cor do calendário: 0 se `value <= 0` ou `maxValue <= 0`; razão < 0,25 → 1;
    /// < 0,5 → 2; < 0,75 → 3; senão 4.
    public static func contributionLevel(value: Double, maxValue: Double) -> Int {
        guard value > 0, maxValue > 0 else { return 0 }
        let ratio = value / maxValue
        if ratio < 0.25 { return 1 }
        if ratio < 0.5 { return 2 }
        if ratio < 0.75 { return 3 }
        return 4
    }

    /// Estatísticas de dias contíguos e ordenados (saída de `dailyTotals`), com o último elemento = hoje.
    /// `currentStreak` segue a regra de `streaks`: começa hoje; se hoje ainda não tem uso, começa ontem.
    public static func contributionStats(_ days: [DailyTotal]) -> ContributionStats {
        let active = days.filter { $0.credits > 0 }
        let total = active.reduce(0) { $0 + $1.credits }
        var index = days.count - 1
        if index >= 0 && days[index].credits <= 0 { index -= 1 }
        var streak = 0
        while index >= 0 && days[index].credits > 0 {
            streak += 1
            index -= 1
        }
        return ContributionStats(
            activeDays: active.count,
            averageActiveDay: active.isEmpty ? 0 : total / Double(active.count),
            peak: active.max { $0.credits < $1.credits },
            currentStreak: streak
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

    /// Intervalo `[start, end)` do período com `offset` (0 = atual, −1 = anterior…). Dias no calendário local;
    /// o ciclo em UTC (`cycleRange`), porque o reset é meia-noite UTC.
    private static func dateRange(
        _ period: UsagePeriod, offset: Int, now: Date, resetDate: Date, calendar: Calendar
    ) -> (start: Date, end: Date) {
        switch period {
        case .today:
            let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
            return (start, calendar.date(byAdding: .day, value: 1, to: start)!)
        case .sevenDays:
            return rollingWindow(days: 7, offset: offset, now: now, calendar: calendar)
        case .thirtyDays:
            return rollingWindow(days: 30, offset: offset, now: now, calendar: calendar)
        case .cycle:
            return cycleRange(resetDate: resetDate, offset: offset)
        }
    }

    /// Janela de exatamente `days` dias locais terminando no fim de hoje, deslocada de `days` em `days` dias.
    /// As duas bordas partem da mesma âncora (início de amanhã), então a janela com offset − 1 termina
    /// exatamente onde esta começa: "vs 30d anteriores" compara janelas contíguas, sem lacuna nem sobreposição.
    private static func rollingWindow(
        days: Int, offset: Int, now: Date, calendar: Calendar
    ) -> (start: Date, end: Date) {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return (
            calendar.date(byAdding: .day, value: days * (offset - 1), to: tomorrow)!,
            calendar.date(byAdding: .day, value: days * offset, to: tomorrow)!
        )
    }

    private static func makeTrendStats(
        buckets: [UsageBucket], previousDeltas: [UsageDelta], elapsedBuckets: Int
    ) -> TrendStats {
        let total = buckets.reduce(0) { $0 + $1.total }
        let previousTotal = previousDeltas.isEmpty ? nil : previousDeltas.reduce(0) { $0 + $1.amount }
        let deltaPercent = previousTotal.flatMap { previous -> Double? in
            previous != 0 ? (total - previous) / previous * 100 : nil
        }
        return TrendStats(
            total: total,
            averagePerBucket: total / Double(max(1, elapsedBuckets)),
            peak: total > 0 ? buckets.max { $0.total < $1.total } : nil,
            activeBuckets: buckets.filter { $0.total > 0 }.count,
            previousTotal: previousTotal,
            deltaPercent: deltaPercent
        )
    }

    private static func makePeriodStats(
        periodDeltas: [UsageDelta], dailyBuckets: [UsageBucket], sessions: [InferredSession],
        streak: (current: Int, longest: Int), elapsedDays: Int, calendar: Calendar
    ) -> PeriodStats {
        var weekdayTotals: [Int: Double] = [:]
        for delta in periodDeltas where delta.amount > 0 {
            weekdayTotals[calendar.component(.weekday, from: delta.sample.date), default: 0] += delta.amount
        }
        var mostActive: (weekday: Int, credits: Double)?
        for weekday in 1...7 {
            let credits = weekdayTotals[weekday] ?? 0
            if credits > (mostActive?.credits ?? 0) { mostActive = (weekday, credits) }
        }
        let dailyTotal = dailyBuckets.reduce(0) { $0 + $1.total }
        let sessionCredits = sessions.reduce(0) { $0 + $1.credits }
        return PeriodStats(
            activeDays: dailyBuckets.filter { $0.total > 0 }.count,
            elapsedDays: elapsedDays,
            mostActiveWeekday: mostActive?.weekday,
            mostActiveWeekdayCredits: mostActive?.credits ?? 0,
            peakDay: dailyTotal > 0 ? dailyBuckets.max { $0.total < $1.total } : nil,
            sessionCount: sessions.count,
            averagePerSession: sessions.isEmpty ? 0 : sessionCredits / Double(sessions.count),
            costliestSession: sessions.max { $0.credits < $1.credits },
            currentStreak: streak.current,
            longestStreak: streak.longest
        )
    }

    /// Buckets decorridos: em `Hoje` com offset 0, horas desde o início do dia (para cima, mínimo 1);
    /// nos períodos diários com offset 0, dias de `selectedStart` até hoje inclusive;
    /// com offset diferente de 0, o tamanho inteiro do período.
    private static func elapsedBucketCount(
        period: UsagePeriod, offset: Int, range: (start: Date, end: Date), now: Date, calendar: Calendar
    ) -> Int {
        guard period == .today else {
            return offset == 0
                ? elapsedDayCount(range: range, now: now, calendar: calendar)
                : dayCount(range: range, calendar: calendar)
        }
        let fullHours = max(1, Int((range.end.timeIntervalSince(range.start) / 3600).rounded()))
        guard offset == 0 else { return fullHours }
        let hours = Int((now.timeIntervalSince(range.start) / 3600).rounded(.up))
        return min(fullHours, max(1, hours))
    }

    /// Dias locais tocados pelo intervalo [start, end), mínimo 1.
    private static func dayCount(range: (start: Date, end: Date), calendar: Calendar) -> Int {
        let first = calendar.startOfDay(for: range.start)
        let last = calendar.startOfDay(for: max(range.start, range.end.addingTimeInterval(-1)))
        return max(1, (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1)
    }

    /// Dias do intervalo já decorridos até hoje inclusive, limitado ao tamanho do período, mínimo 1.
    private static func elapsedDayCount(range: (start: Date, end: Date), now: Date, calendar: Calendar) -> Int {
        let first = calendar.startOfDay(for: range.start)
        let elapsed = (calendar.dateComponents([.day], from: first, to: calendar.startOfDay(for: now)).day ?? 0) + 1
        return max(1, min(dayCount(range: range, calendar: calendar), elapsed))
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
