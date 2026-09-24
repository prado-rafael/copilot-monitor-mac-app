import Foundation

public struct UsageSnapshot: Sendable {
    public let login: String
    public let plan: String
    public let assignedDate: Date
    public let resetDate: Date
    public let resetDateKey: String
    public let entitlement: Double
    public let quotaRemaining: Double
    public let used: Double
    public let overage: Double
    public let timestamp: Date
    public let rawJSON: Data

    public init(
        login: String, plan: String, assignedDate: Date, resetDate: Date, resetDateKey: String,
        entitlement: Double, quotaRemaining: Double, used: Double, overage: Double,
        timestamp: Date, rawJSON: Data
    ) {
        self.login = login
        self.plan = plan
        self.assignedDate = assignedDate
        self.resetDate = resetDate
        self.resetDateKey = resetDateKey
        self.entitlement = entitlement
        self.quotaRemaining = quotaRemaining
        self.used = used
        self.overage = overage
        self.timestamp = timestamp
        self.rawJSON = rawJSON
    }

    public func sample(at date: Date = Date()) -> UsageSample {
        UsageSample(
            timestamp: Int64(date.timeIntervalSince1970), used: used,
            entitlement: entitlement, overage: overage, resetDate: resetDateKey
        )
    }
}

public struct UsageSample: Sendable, Equatable {
    public let timestamp: Int64
    public let used: Double
    public let entitlement: Double
    public let overage: Double
    public let resetDate: String

    public init(timestamp: Int64, used: Double, entitlement: Double, overage: Double, resetDate: String) {
        self.timestamp = timestamp
        self.used = used
        self.entitlement = entitlement
        self.overage = overage
        self.resetDate = resetDate
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }
}

public enum UsageParseError: Error, LocalizedError {
    case invalidJSON
    case missingField(String)
    case missingQuotaSnapshot

    public var errorDescription: String? {
        switch self {
        case .invalidJSON: return "A API do GitHub retornou um JSON inválido."
        case let .missingField(field): return "A resposta do GitHub não contém o campo obrigatório “\(field)”."
        case .missingQuotaSnapshot: return "A resposta não contém um snapshot de quota limitado."
        }
    }
}
