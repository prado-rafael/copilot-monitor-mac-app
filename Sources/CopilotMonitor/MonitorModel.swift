import AppKit
import CopilotMonitorCore
import Foundation
import ServiceManagement
import UserNotifications

enum StatusFormat: String, CaseIterable, Identifiable {
    case todayAndPercent, dollarsToday, cyclePercent
    var id: String { rawValue }
    var title: String {
        switch self {
        case .todayAndPercent: return "Hoje · % do ciclo"
        case .dollarsToday: return "US$ hoje"
        case .cyclePercent: return "% do ciclo"
        }
    }
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published private(set) var samples: [UsageSample] = []
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notificationError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSleeping = false
    @Published var selectedPeriod: UsagePeriod = .today
    @Published var periodOffset = 0
    @Published var interval: TimeInterval
    @Published var statusFormat: StatusFormat
    @Published var notificationsEnabled: Bool
    @Published var peakThreshold: Double
    @Published var sessionGapMinutes: Double

    let isDemo: Bool
    private let store: SQLiteUsageStore
    private let tokenResolver = TokenResolver()
    private let client = GitHubCopilotClient()
    private var etag: String?
    private var failures = 0
    private var pollingTask: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var refreshInProgress = false

    init(store: SQLiteUsageStore, demo: Bool) throws {
        self.store = store
        isDemo = demo
        let defaults = UserDefaults.standard
        let configuredInterval = defaults.double(forKey: "pollInterval")
        interval = configuredInterval > 0 ? configuredInterval : 60
        statusFormat = StatusFormat(rawValue: defaults.string(forKey: "statusFormat") ?? "") ?? .todayAndPercent
        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        peakThreshold = defaults.object(forKey: "peakThreshold") as? Double ?? 40
        sessionGapMinutes = defaults.object(forKey: "sessionGapMinutes") as? Double ?? 10

        if demo {
            let seeded = DemoData.make()
            let existing = try store.samples()
            if existing.last.map({ Date().timeIntervalSince($0.date) > 1800 }) ?? true {
                try store.removeAllSamples()
                for sample in seeded.samples { try store.append(sample) }
            }
            samples = try store.samples(since: Int64(Date().addingTimeInterval(-60 * 86400).timeIntervalSince1970))
            if let last = samples.last {
                snapshot = UsageSnapshot(
                    login: seeded.snapshot.login, plan: seeded.snapshot.plan,
                    assignedDate: seeded.snapshot.assignedDate, resetDate: seeded.snapshot.resetDate,
                    resetDateKey: seeded.snapshot.resetDateKey, entitlement: last.entitlement,
                    quotaRemaining: last.entitlement - last.used, used: last.used, overage: last.overage,
                    timestamp: last.date, rawJSON: seeded.snapshot.rawJSON
                )
                lastUpdated = last.date
            }
        } else {
            samples = try store.samples(since: Int64(Date().addingTimeInterval(-60 * 86400).timeIntervalSince1970))
            if let raw = try store.metadata(forKey: "lastResponse") {
                do {
                    snapshot = try GitHubResponseParser.parse(raw)
                } catch {
                    errorMessage = "A última resposta armazenada não pôde ser interpretada: \(error.localizedDescription)"
                }
                lastUpdated = try store.latestSample()?.date
            }
            if let data = try store.metadata(forKey: "etag") {
                etag = String(data: data, encoding: .utf8)
            }
        }
    }

    deinit {
        pollingTask?.cancel()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    var metrics: UsageMetrics? {
        guard let snapshot else { return nil }
        return MetricsEngine.analyze(
            samples: samples, assignedDate: snapshot.assignedDate, resetDate: snapshot.resetDate,
            entitlement: snapshot.entitlement, period: selectedPeriod, periodOffset: periodOffset,
            sessionGap: sessionGapMinutes * 60
        )
    }

    var currentUsed: Double { snapshot?.used ?? 0 }
    var currentEntitlement: Double { snapshot?.entitlement ?? 0 }
    var cyclePercent: Double {
        guard currentEntitlement > 0 else { return 0 }
        return currentUsed / currentEntitlement * 100
    }

    var statusTitle: String {
        guard snapshot != nil else { return "—" }
        switch statusFormat {
        case .todayAndPercent:
            return "\(Self.number(metrics(for: .today)?.periodTotal ?? 0)) · \(Self.number(cyclePercent))%"
        case .dollarsToday:
            return "\(Self.dollars(metrics(for: .today)?.periodTotal ?? 0)) hoje"
        case .cyclePercent:
            return "\(Self.number(cyclePercent))% do ciclo"
        }
    }

    var statusColor: NSColor {
        guard let metrics else { return .secondaryLabelColor }
        if currentEntitlement > 0 && currentUsed >= currentEntitlement { return .systemRed }
        if (metrics.projectedAtReset ?? 0) > currentEntitlement || peakIsActive {
            return .systemOrange
        }
        return .labelColor
    }

    var peakIsActive: Bool {
        let cutoff = Date().addingTimeInterval(-600)
        return MetricsEngine.deltas(samples: samples)
            .filter { $0.sample.date > cutoff && !$0.duringAbsence }
            .reduce(0) { $0 + $1.amount } >= peakThreshold
    }

    func metrics(for period: UsagePeriod) -> UsageMetrics? {
        guard let snapshot else { return nil }
        return MetricsEngine.analyze(
            samples: samples, assignedDate: snapshot.assignedDate, resetDate: snapshot.resetDate,
            entitlement: snapshot.entitlement, period: period, periodOffset: 0,
            sessionGap: sessionGapMinutes * 60
        )
    }

    func start() {
        guard pollingTask == nil else { return }
        if notificationsEnabled && !UserDefaults.standard.bool(forKey: "notificationPrompted") {
            requestNotificationPermission()
            UserDefaults.standard.set(true, forKey: "notificationPrompted")
        }
        let center = NSWorkspace.shared.notificationCenter
        let owner = self
        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak owner] in owner?.isSleeping = true }
        }
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak owner] in await owner?.handleWake() }
        }
        schedulePollingLoop(immediate: true)
    }

    private func schedulePollingLoop(immediate: Bool) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            if immediate { await self.refresh() }
            while !Task.isCancelled {
                let seconds = self.isSleeping ? 300 : min(600, self.interval * pow(2, Double(self.failures)))
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if !Task.isCancelled && !self.isSleeping { await self.refresh() }
            }
        }
    }

    private func handleWake() async {
        isSleeping = false
        await refresh()
    }

    func refresh() async {
        guard !isDemo, !isSleeping, !refreshInProgress else { return }
        refreshInProgress = true
        isRefreshing = true
        defer { refreshInProgress = false; isRefreshing = false }
        do {
            var token = try await tokenResolver.token()
            let result: GitHubFetchResult
            do {
                result = try await client.fetch(token: token, etag: etag)
            } catch MonitorError.unauthorized {
                tokenResolver.invalidateCLICache()
                token = try await tokenResolver.token(forceRefresh: true)
                result = try await client.fetch(token: token, etag: etag)
            }

            let newSnapshot: UsageSnapshot
            switch result {
            case let .modified(value, newETag):
                newSnapshot = value
                etag = newETag
                try store.setMetadata(value.rawJSON, forKey: "lastResponse")
                if let newETag { try store.setMetadata(Data(newETag.utf8), forKey: "etag") }
            case let .unchanged(newETag):
                guard let snapshot else { throw MonitorError.noCachedResponse }
                newSnapshot = snapshot
                etag = newETag
            }
            let sample = newSnapshot.sample()
            try store.append(sample)
            if case .unchanged = result {
                try store.setMetadata(Data(newSnapshot.rawJSON), forKey: "lastResponse")
            }
            self.snapshot = newSnapshot
            lastUpdated = Date()
            errorMessage = nil
            failures = 0
            samples.append(sample)
            samples = Array(samples.suffix(100_000))
            evaluateNotifications()
        } catch {
            failures = min(failures + 1, 4)
            errorMessage = error.localizedDescription
        }
    }

    func selectPeriod(_ period: UsagePeriod) {
        selectedPeriod = period
        periodOffset = 0
    }

    func shiftPeriod(_ direction: Int) { periodOffset += direction }

    func setInterval(_ value: TimeInterval) {
        interval = value
        UserDefaults.standard.set(value, forKey: "pollInterval")
        if pollingTask != nil { schedulePollingLoop(immediate: false) }
    }

    func setStatusFormat(_ format: StatusFormat) {
        statusFormat = format
        UserDefaults.standard.set(format.rawValue, forKey: "statusFormat")
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.notificationError = "Permissão de notificações: \(error.localizedDescription)"
                } else if !granted {
                    self?.notificationError = "Notificações desativadas nas configurações do macOS."
                } else {
                    self?.notificationError = nil
                }
            }
        }
    }

    func saveTokenOverride(_ value: String) throws {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try KeychainTokenStore.save(token.isEmpty ? nil : token)
        tokenResolver.invalidateCLICache()
    }

    func tokenOverrideExists() -> Bool { (try? KeychainTokenStore.load()) != nil }

    func setLoginItemEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

    func loginItemEnabled() -> Bool { SMAppService.mainApp.status == .enabled }

    func rawResponse() -> String {
        guard let data = snapshot?.rawJSON,
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return "Nenhuma resposta da API foi armazenada."
        }
        return String(data: pretty, encoding: .utf8) ?? "A resposta armazenada não pôde ser convertida para texto."
    }

    func offlineDescription(now: Date = Date()) -> String? {
        guard let errorMessage else { return nil }
        guard let lastUpdated else { return "offline · ainda sem leitura" }
        let minutes = max(0, Int(now.timeIntervalSince(lastUpdated) / 60))
        return "offline há \(minutes) min · \(errorMessage)"
    }

    private func evaluateNotifications() {
        guard notificationsEnabled, let snapshot else { return }
        let defaults = UserDefaults.standard
        let cycleKey = "notifiedThresholds-\(snapshot.resetDateKey)"
        var sent = Set(defaults.stringArray(forKey: cycleKey) ?? [])
        if snapshot.entitlement > 0 {
            let percent = snapshot.used / snapshot.entitlement * 100
            for threshold in [50, 80, 90, 100] where percent >= Double(threshold) && !sent.contains("\(threshold)") {
                notify(title: "Quota Copilot: \(threshold)%", body: "Você usou \(Self.number(snapshot.used)) de \(Self.number(snapshot.entitlement)) créditos.")
                sent.insert("\(threshold)")
            }
            defaults.set(Array(sent), forKey: cycleKey)
        }
        if let projected = metrics?.projectedAtReset, projected > snapshot.entitlement {
            let key = "projection-notified-\(Self.dayKey(Date()))"
            if !defaults.bool(forKey: key) {
                notify(title: "Projeção acima da quota", body: "No ritmo atual, o uso pode ultrapassar os créditos incluídos.")
                defaults.set(true, forKey: key)
            }
        }
        let recentPeak = MetricsEngine.deltas(samples: samples)
            .filter { $0.sample.date > Date().addingTimeInterval(-600) && !$0.duringAbsence }
            .reduce(0) { $0 + $1.amount }
        let lastPeak = defaults.double(forKey: "lastPeakNotification")
        let now = Date().timeIntervalSince1970
        if recentPeak >= peakThreshold && now - lastPeak >= 1800 {
            notify(title: "Consumo alto", body: "Consumo alto: \(Self.number(recentPeak)) cr nos últimos 10 min.")
            defaults.set(now, forKey: "lastPeakNotification")
        }
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor [weak self] in
                    self?.notificationError = error.localizedDescription
                }
            }
        }
    }

    static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func dollars(_ credits: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "US$"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: credits / 100)) ?? "US$ 0,00"
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
