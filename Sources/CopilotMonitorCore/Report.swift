import Foundation

extension BudgetState: Codable {}

/// Relatório do modo CLI (`--json`, `--check`): o mesmo `analyze` do popover, com o período `Hoje`,
/// sobre as amostras gravadas pelo app. Campos opcionais saem como `null` (nunca omitidos), para as
/// chaves do JSON serem estáveis; créditos e percentuais vão arredondados a 2 casas, dólares a 4.
public struct UsageReport: Codable, Sendable, Equatable {
    public struct Cycle: Codable, Sendable, Equatable {
        public let used: Double
        public let entitlement: Double
        /// entitlement − used; negativo quando há excedente.
        public let remaining: Double
        public let percent: Double
        public let resetDate: Date
        public let projectedAtReset: Double?
        /// `"linear"` ou `"previousCycle"` (ver `ProjectionSource`).
        public let projectionSource: String?
        public let exhaustionDate: Date?
        /// used − uso esperado no ritmo linear; positivo = acima do ritmo.
        public let paceDifference: Double
        public let previousCycleUsed: Double?

        /// Orçamento do ciclo (limit = entitlement, spent = used), base da linha `ciclo:` do `--check`.
        /// Calculado, não serializado.
        public var budget: BudgetStatus { BudgetStatus(limit: entitlement, spent: used) }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(used, forKey: .used)
            try container.encode(entitlement, forKey: .entitlement)
            try container.encode(remaining, forKey: .remaining)
            try container.encode(percent, forKey: .percent)
            try container.encode(resetDate, forKey: .resetDate)
            try container.encode(projectedAtReset, forKey: .projectedAtReset)
            try container.encode(projectionSource, forKey: .projectionSource)
            try container.encode(exhaustionDate, forKey: .exhaustionDate)
            try container.encode(paceDifference, forKey: .paceDifference)
            try container.encode(previousCycleUsed, forKey: .previousCycleUsed)
        }
    }

    public struct Budget: Codable, Sendable, Equatable {
        public let limit: Double
        public let spent: Double
        public let percent: Double
        public let state: BudgetState
    }

    public struct Today: Codable, Sendable, Equatable {
        public let credits: Double
        public let usd: Double
        /// nil quando o orçamento está desligado ou o automático não é calculável.
        public let budget: Budget?

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(credits, forKey: .credits)
            try container.encode(usd, forKey: .usd)
            try container.encode(budget, forKey: .budget)
        }
    }

    public struct Yesterday: Codable, Sendable, Equatable {
        public let credits: Double
    }

    /// Ambos em cr/h, como no popover: `lastHour` é o total da última hora e `last15Minutes`
    /// o total dos últimos 15 min × 4. Leituras durante ausência não entram.
    public struct Burn: Codable, Sendable, Equatable {
        public let lastHour: Double
        public let last15Minutes: Double
    }

    public struct Session: Codable, Sendable, Equatable {
        public let start: Date
        /// Última leitura com consumo.
        public let end: Date
        public let credits: Double
        /// Minutos desde o início até `generated`, como no cabeçalho do popover.
        public let minutes: Int
    }

    public struct Streak: Codable, Sendable, Equatable {
        public let current: Int
        public let longest: Int
    }

    /// Tempo sem leitura (5 min) a partir do qual o relatório é marcado como `stale`.
    public static let staleAfter: TimeInterval = 5 * 60

    public let generated: Date
    public let login: String
    public let plan: String
    /// `lastUpdated` há mais de 5 min (ou sem nenhuma leitura): o app provavelmente não está coletando.
    public let stale: Bool
    /// Data da amostra mais recente.
    public let lastUpdated: Date?
    public let cycle: Cycle
    public let today: Today
    public let yesterday: Yesterday
    public let burn: Burn
    public let activeSession: Session?
    public let streak: Streak

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generated, forKey: .generated)
        try container.encode(login, forKey: .login)
        try container.encode(plan, forKey: .plan)
        try container.encode(stale, forKey: .stale)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encode(cycle, forKey: .cycle)
        try container.encode(today, forKey: .today)
        try container.encode(yesterday, forKey: .yesterday)
        try container.encode(burn, forKey: .burn)
        try container.encode(activeSession, forKey: .activeSession)
        try container.encode(streak, forKey: .streak)
    }

    /// Monta o relatório com as mesmas regras do popover: `today` e `budget` pelo período `Hoje`,
    /// sessão ativa e sequências sobre todas as amostras, orçamento e intervalo de sessão de `settings`.
    public static func make(
        samples: [UsageSample], snapshot: UsageSnapshot, cycles: [CycleSummary],
        settings: MonitorSettings, now: Date = Date(), calendar: Calendar = .current
    ) -> UsageReport {
        let metrics = MetricsEngine.analyze(
            samples: samples, now: now, assignedDate: snapshot.assignedDate,
            resetDate: snapshot.resetDate, entitlement: snapshot.entitlement, period: .today,
            sessionGap: settings.sessionGapMinutes * 60, dailyBudget: settings.dailyBudget,
            previousCycles: cycles, calendar: calendar
        )
        let lastUpdated = samples.max { $0.timestamp < $1.timestamp }?.date
        let projectionSource: String?
        switch metrics.projectionSource {
        case .linear?: projectionSource = "linear"
        case .previousCycle?: projectionSource = "previousCycle"
        case nil: projectionSource = nil
        }
        return UsageReport(
            generated: now,
            login: snapshot.login,
            plan: snapshot.plan,
            stale: lastUpdated.map { now.timeIntervalSince($0) > staleAfter } ?? true,
            lastUpdated: lastUpdated,
            cycle: Cycle(
                used: round(metrics.cycleUsed),
                entitlement: round(metrics.entitlement),
                remaining: round(metrics.remaining),
                percent: round(metrics.cycleBudget.percent),
                resetDate: snapshot.resetDate,
                projectedAtReset: metrics.projectedAtReset.map { round($0) },
                projectionSource: projectionSource,
                exhaustionDate: metrics.exhaustionDate,
                paceDifference: round(metrics.paceDifference),
                previousCycleUsed: metrics.previousCycle.map { round($0.used) }
            ),
            today: Today(
                credits: round(metrics.periodTotal),
                usd: round(metrics.periodTotal / 100, places: 4),
                budget: metrics.dailyBudget.map { budget in
                    Budget(
                        limit: round(budget.limit), spent: round(budget.spent),
                        percent: round(budget.percent), state: budget.state
                    )
                }
            ),
            yesterday: Yesterday(credits: round(metrics.yesterdayTotal)),
            burn: Burn(lastHour: round(metrics.burnLastHour), last15Minutes: round(metrics.burnLast15Minutes)),
            activeSession: metrics.activeSession.map { session in
                Session(
                    start: session.start, end: session.end, credits: round(session.credits),
                    minutes: Int(max(0, now.timeIntervalSince(session.start)) / 60)
                )
            },
            streak: Streak(current: metrics.stats.currentStreak, longest: metrics.stats.longestStreak)
        )
    }

    /// JSON com chaves ordenadas e datas ISO 8601; `prettyPrinted` a menos que `pretty` seja false.
    public func jsonData(pretty: Bool = true) throws -> Data {
        try Self.encoder(pretty: pretty).encode(self)
    }

    /// Encoder do relatório (também usado pelo CLI para o `{"error": ...}`).
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decode(_ data: Data) throws -> UsageReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UsageReport.self, from: data)
    }

    /// Evita ruído de ponto flutuante no JSON (`963.5999999999999`).
    private static func round(_ value: Double, places: Int = 2) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }
}
