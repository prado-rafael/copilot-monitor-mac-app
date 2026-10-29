import Foundation

public enum UsageAnomalyReason: String, Sendable {
    case invalidValues, quotaCollapse, counterDecrease, suddenIncrease, staleResponse, olderCycle

    public var message: String {
        switch self {
        case .invalidValues: return "A API retornou valores de quota inválidos."
        case .quotaCollapse: return "O contador e a quota zeraram inesperadamente no mesmo ciclo."
        case .counterDecrease: return "A queda do contador no mesmo ciclo aguarda confirmação."
        case .suddenIncrease: return "Um salto incomum no consumo aguarda confirmação."
        case .staleResponse: return "A API retornou uma leitura anterior à última leitura válida."
        case .olderCycle: return "A API retornou um ciclo anterior ao atual."
        }
    }
}

public enum UsageReadingDecision: Equatable, Sendable {
    case accepted
    case quarantined(UsageAnomalyReason)
}

/// Mantém a última referência confiável. Só respostas novas (200), nunca polls 304, devem passar
/// por `evaluate`. Não impõe um teto de consumo: saltos legítimos podem ser confirmados, inclusive overage.
public struct UsageReadingValidator: Sendable {
    public private(set) var lastAccepted: UsageSample?
    private var lastAPITimestamp: Date?
    private var pending: (sample: UsageSample, apiTimestamp: Date, reason: UsageAnomalyReason)?

    public init(lastAccepted: UsageSample? = nil, apiTimestamp: Date? = nil) {
        self.lastAccepted = lastAccepted
        lastAPITimestamp = apiTimestamp
    }

    public mutating func evaluate(_ sample: UsageSample, apiTimestamp: Date) -> UsageReadingDecision {
        guard sample.used.isFinite, sample.entitlement.isFinite, sample.used >= 0, sample.entitlement >= 0 else {
            return .quarantined(.invalidValues)
        }
        if let lastAPITimestamp, apiTimestamp < lastAPITimestamp {
            return .quarantined(.staleResponse)
        }
        guard let previous = lastAccepted else { return accept(sample, apiTimestamp: apiTimestamp) }
        if sample.resetDate != previous.resetDate {
            if let old = GitHubResponseParser.parseDate(previous.resetDate),
               let new = GitHubResponseParser.parseDate(sample.resetDate), new <= old {
                return .quarantined(.olderCycle)
            }
            return accept(sample, apiTimestamp: apiTimestamp)
        }
        // Placeholders 0/0 ou 0/1 não ficam confiáveis só porque foram repetidos por horas.
        if Self.isQuotaCollapse(sample, after: previous) { return .quarantined(.quotaCollapse) }

        let reason: UsageAnomalyReason?
        if sample.used < previous.used - 1 {
            reason = .counterDecrease
        } else if sample.used - previous.used > max(1000, previous.entitlement * 0.25)
                    * max(1, Double(sample.timestamp - previous.timestamp) / 600) {
            reason = .suddenIncrease
        } else {
            reason = nil
        }
        guard let reason else { return accept(sample, apiTimestamp: apiTimestamp) }
        if let pending, pending.reason == reason, pending.sample.resetDate == sample.resetDate,
           sample.timestamp - pending.sample.timestamp >= 60,
           apiTimestamp.timeIntervalSince(pending.apiTimestamp) >= 60,
           sample.used >= pending.sample.used - 1,
           abs(sample.used - pending.sample.used) <= max(1000, pending.sample.used * 0.1) {
            return accept(sample, apiTimestamp: apiTimestamp)
        }
        // Releituras do mesmo payload não renovam o início da janela de confirmação.
        if pending == nil || pending?.reason != reason ||
            abs(sample.used - (pending?.sample.used ?? 0)) > max(1000, sample.used * 0.1) {
            pending = (sample, apiTimestamp, reason)
        }
        return .quarantined(reason)
    }

    private mutating func accept(_ sample: UsageSample, apiTimestamp: Date) -> UsageReadingDecision {
        lastAccepted = sample
        lastAPITimestamp = apiTimestamp
        pending = nil
        return .accepted
    }

    private static func isQuotaCollapse(_ sample: UsageSample, after previous: UsageSample) -> Bool {
        sample.resetDate == previous.resetDate && previous.entitlement > 1 && previous.used > 1
            && sample.used == 0 && sample.entitlement <= 1
    }

    /// Migração retrospectiva conservadora: identifica apenas o placeholder observado, em contexto.
    /// Zero no início de um ciclo, planos de quota baixa e mudanças normais de entitlement são válidos.
    public static func historicalPlaceholders(in samples: [UsageSample]) -> [Int] {
        var previous: UsageSample?
        var result: [Int] = []
        for (index, sample) in samples.enumerated() {
            if let previous, isQuotaCollapse(sample, after: previous) {
                result.append(index)
            } else {
                previous = sample
            }
        }
        return result
    }
}
