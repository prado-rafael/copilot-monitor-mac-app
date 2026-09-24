import Foundation

public enum GitHubResponseParser {
    public static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageParseError.invalidJSON
        }
        let login = root["login"] as? String ?? "GitHub"
        let plan = root["copilot_plan"] as? String ?? "Copilot"
        guard let assigned = root["assigned_date"] as? String, let assignedDate = parseDate(assigned) else {
            throw UsageParseError.missingField("assigned_date")
        }
        guard let resetKey = (root["quota_reset_date_utc"] as? String) ?? (root["quota_reset_date"] as? String),
              let resetDate = parseDate(resetKey) else {
            throw UsageParseError.missingField("quota_reset_date_utc")
        }
        guard let snapshots = root["quota_snapshots"] as? [String: Any] else {
            throw UsageParseError.missingField("quota_snapshots")
        }

        let quota: [String: Any]?
        if let premium = snapshots["premium_interactions"] as? [String: Any] {
            quota = premium
        } else {
            quota = snapshots.values
                .compactMap { $0 as? [String: Any] }
                .first { !boolValue($0["unlimited"]) }
        }
        guard let quota else { throw UsageParseError.missingQuotaSnapshot }
        guard let entitlement = numberValue(quota["entitlement"]) else {
            throw UsageParseError.missingField("quota_snapshots.*.entitlement")
        }
        let quotaRemaining = numberValue(quota["quota_remaining"]) ?? numberValue(quota["remaining"])
        let reportedUsed = numberValue(quota["credits_used"])
        guard let used = quotaRemaining.map({ entitlement - $0 }) ?? reportedUsed else {
            throw UsageParseError.missingField("quota_remaining ou credits_used")
        }
        let timestamp = (quota["timestamp_utc"] as? String).flatMap(parseDate) ?? now
        return UsageSnapshot(
            login: login, plan: plan, assignedDate: assignedDate, resetDate: resetDate,
            resetDateKey: resetKey, entitlement: entitlement,
            quotaRemaining: quotaRemaining ?? max(0, entitlement - used), used: used,
            overage: max(0, used - entitlement),
            timestamp: timestamp, rawJSON: data
        )
    }

    private static func numberValue(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func boolValue(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private static func parseDate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: string) { return date }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: string)
    }
}
