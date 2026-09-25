import AppKit
import CopilotMonitorCore
import Foundation
import ServiceManagement
import UserNotifications

enum StatusFormat: String, CaseIterable, Identifiable {
    case todayAndPercent, dollarsToday, cyclePercent, todayVsBudget
    var id: String { rawValue }
    var title: String {
        switch self {
        case .todayAndPercent: return "Hoje · % do ciclo"
        case .dollarsToday: return "US$ hoje"
        case .cyclePercent: return "% do ciclo"
        case .todayVsBudget: return "Hoje / orçamento"
        }
    }
}

/// Modos do orçamento diário; `rawValue` é o valor gravado em `dailyBudgetMode`.
enum DailyBudgetMode: String, CaseIterable, Identifiable {
    case off, auto, manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Desligado"
        case .auto: return "Automático (dias úteis até o reset)"
        case .manual: return "Manual"
        }
    }
}

private struct MetricsCacheKey: Hashable {
    let period: UsagePeriod
    let periodOffset: Int
    let samplesVersion: Int
    let sessionGapMinutes: Double
    let dailyBudget: DailyBudgetSetting
    let minuteBucket: Int
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published private(set) var samples: [UsageSample] = [] {
        didSet {
            samplesVersion &+= 1
            metricsCache.removeAll()
        }
    }
    @Published private(set) var snapshot: UsageSnapshot? {
        didSet { metricsCache.removeAll() }
    }
    /// Ciclos fechados (tabela `cycles`), ordenados por `resetDate`.
    @Published private(set) var cycles: [CycleSummary] = [] {
        didSet { metricsCache.removeAll() }
    }
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
    @Published var peakThreshold: Double {
        didSet { persistSettings() }
    }
    @Published var sessionGapMinutes: Double {
        didSet {
            metricsCache.removeAll()
            persistSettings()
        }
    }
    @Published var dailyBudgetSetting: DailyBudgetSetting {
        didSet {
            guard dailyBudgetSetting != oldValue else { return }
            metricsCache.removeAll()
            if case let .manual(credits) = dailyBudgetSetting { dailyBudgetCredits = credits }
            let defaults = UserDefaults.standard
            defaults.set(dailyBudgetSetting.mode, forKey: "dailyBudgetMode")
            defaults.set(dailyBudgetCredits, forKey: "dailyBudgetCredits")
            persistSettings()
        }
    }
    /// Último valor manual; preservado ao alternar para desligado/automático.
    private(set) var dailyBudgetCredits: Double

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
    private var samplesVersion = 0
    private var metricsCache: [MetricsCacheKey: UsageMetrics] = [:]
    private static let metricsCacheLimit = 8
    private var lastPersistedSettings: Data?

    init(store: SQLiteUsageStore, demo: Bool) throws {
        self.store = store
        isDemo = demo
        let defaults = UserDefaults.standard
        let configuredInterval = defaults.double(forKey: "pollInterval")
        interval = configuredInterval > 0 ? configuredInterval : 60
        statusFormat = StatusFormat(rawValue: defaults.string(forKey: "statusFormat") ?? "") ?? .todayAndPercent
        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        let fallback = MonitorSettings.defaults
        peakThreshold = defaults.object(forKey: "peakThreshold") as? Double ?? fallback.peakThreshold
        sessionGapMinutes = defaults.object(forKey: "sessionGapMinutes") as? Double ?? fallback.sessionGapMinutes
        let budgetCredits = defaults.object(forKey: "dailyBudgetCredits") as? Double ?? fallback.dailyBudgetCredits
        dailyBudgetCredits = budgetCredits
        dailyBudgetSetting = DailyBudgetSetting(
            mode: defaults.string(forKey: "dailyBudgetMode"), credits: budgetCredits
        )

        // Histórico das 13 semanas do calendário de atividade.
        let historyStart = Int64(Date().addingTimeInterval(-Double(MetricsEngine.historyDays) * 86400).timeIntervalSince1970)
        if demo {
            // Mesma semeadura do CLI: regrava o histórico sintético se o banco estiver vazio ou velho.
            snapshot = try DemoData.seed(store)
            cycles = try store.cycles()
            samples = try store.samples(since: historyStart)
            lastUpdated = samples.last?.date
        } else {
            samples = try store.samples(since: historyStart)
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
            // Ciclos fechados enquanto o app não gravava a tabela `cycles` saem das amostras.
            if let currentKey = snapshot?.resetDateKey ?? samples.last?.resetDate {
                try store.backfillCycles(excluding: currentKey)
            }
            cycles = try store.cycles()
        }
        persistSettings()
    }

    deinit {
        pollingTask?.cancel()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    var metrics: UsageMetrics? { cachedMetrics(period: selectedPeriod, offset: periodOffset) }

    var currentUsed: Double { snapshot?.used ?? 0 }
    var currentEntitlement: Double { snapshot?.entitlement ?? 0 }
    var cyclePercent: Double {
        guard currentEntitlement > 0 else { return 0 }
        return currentUsed / currentEntitlement * 100
    }

    var statusTitle: String {
        guard snapshot != nil else { return "—" }
        let today = metrics(for: .today)
        let todayAndPercent = "\(Self.number(today?.periodTotal ?? 0)) · \(Self.number(cyclePercent))%"
        switch statusFormat {
        case .todayAndPercent:
            return todayAndPercent
        case .dollarsToday:
            return "\(Self.dollars(today?.periodTotal ?? 0)) hoje"
        case .cyclePercent:
            return "\(Self.number(cyclePercent))% do ciclo"
        case .todayVsBudget:
            guard let budget = today?.dailyBudget else { return todayAndPercent }
            return "\(Self.number(budget.spent)) / \(Self.number(budget.limit))"
        }
    }

    var statusColor: NSColor {
        guard let metrics else { return .secondaryLabelColor }
        if currentEntitlement > 0 && currentUsed >= currentEntitlement { return .systemRed }
        // O fallback do ciclo anterior não acende o laranja no primeiro dia de um ciclo novo.
        let projectedOver = metrics.projectionSource == .linear && (metrics.projectedAtReset ?? 0) > currentEntitlement
        if projectedOver || peakIsActive || metrics.dailyBudget?.state == .over {
            return .systemOrange
        }
        return .labelColor
    }

    var dailyBudgetMode: DailyBudgetMode { DailyBudgetMode(rawValue: dailyBudgetSetting.mode) ?? .auto }

    var peakIsActive: Bool {
        guard let deltas = metrics?.deltas else { return false }
        let cutoff = Date().addingTimeInterval(-600)
        return deltas
            .filter { $0.sample.date > cutoff && !$0.duringAbsence }
            .reduce(0) { $0 + $1.amount } >= peakThreshold
    }

    func metrics(for period: UsagePeriod) -> UsageMetrics? { cachedMetrics(period: period, offset: 0) }

    /// `analyze` memoizado por período, offset, versão das amostras, intervalo de sessão, orçamento e minuto corrente.
    private func cachedMetrics(period: UsagePeriod, offset: Int) -> UsageMetrics? {
        guard let snapshot else { return nil }
        let now = Date()
        let key = MetricsCacheKey(
            period: period, periodOffset: offset, samplesVersion: samplesVersion,
            sessionGapMinutes: sessionGapMinutes, dailyBudget: dailyBudgetSetting,
            minuteBucket: Int(now.timeIntervalSince1970 / 60)
        )
        if let cached = metricsCache[key] { return cached }
        let computed = MetricsEngine.analyze(
            samples: samples, now: now, assignedDate: snapshot.assignedDate, resetDate: snapshot.resetDate,
            entitlement: snapshot.entitlement, period: period, periodOffset: offset,
            sessionGap: sessionGapMinutes * 60, dailyBudget: dailyBudgetSetting,
            previousCycles: cycles
        )
        if metricsCache.count >= Self.metricsCacheLimit { metricsCache.removeAll() }
        metricsCache[key] = computed
        return computed
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
            if let previous = snapshot {
                if previous.resetDateKey != newSnapshot.resetDateKey { recordClosedCycle(previous) }
                evaluateSnapshotChange(from: previous, to: newSnapshot)
            }
            self.snapshot = newSnapshot
            lastUpdated = Date()
            errorMessage = nil
            failures = 0
            samples.append(sample)
            // 91 dias a 60 s ≈ 131 mil leituras: o calendário de 13 semanas cabe inteiro.
            samples = Array(samples.suffix(150_000))
            evaluateNotifications()
        } catch {
            failures = min(failures + 1, 4)
            errorMessage = error.localizedDescription
        }
    }

    /// Grava o ciclo que acabou de fechar e recarrega `cycles`. Falha aqui não interrompe a coleta:
    /// o ciclo volta pelo `backfillCycles` na próxima inicialização.
    private func recordClosedCycle(_ previous: UsageSnapshot) {
        let summary = CycleSummary(
            resetDate: previous.resetDateKey, entitlement: previous.entitlement, used: previous.used
        )
        try? store.upsertCycle(summary, closedAt: lastUpdated ?? Date())
        if let stored = try? store.cycles() { cycles = stored }
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

    func setDailyBudgetMode(_ mode: DailyBudgetMode) {
        if mode == .manual && dailyBudgetCredits <= 0 {
            // Sem valor manual anterior: parte do automático de hoje para não nascer estourado.
            let today = metrics(for: .today)
            dailyBudgetCredits = (today?.dailyBudget?.limit ?? today?.weekdayBudget).map { max(1, $0.rounded()) } ?? 100
        }
        dailyBudgetSetting = DailyBudgetSetting(mode: mode.rawValue, credits: dailyBudgetCredits)
    }

    func setDailyBudgetCredits(_ credits: Double) {
        dailyBudgetSetting = .manual(max(0, credits))
    }

    /// Espelha as preferências em `metadata` (chave `settings`) para leitores fora do app.
    /// UserDefaults continua sendo a fonte do app; falha aqui não interrompe nada.
    private func persistSettings() {
        let settings = MonitorSettings(
            dailyBudgetMode: dailyBudgetSetting.mode, dailyBudgetCredits: dailyBudgetCredits,
            sessionGapMinutes: sessionGapMinutes, peakThreshold: peakThreshold
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(settings), data != lastPersistedSettings else { return }
        if (try? store.setMetadata(data, forKey: MonitorSettings.metadataKey)) != nil {
            lastPersistedSettings = data
        }
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
        // Só a projeção linear: o fallback do ciclo anterior não avisa no primeiro dia de um ciclo novo.
        if let metrics, metrics.projectionSource == .linear,
           let projected = metrics.projectedAtReset, projected > snapshot.entitlement {
            let key = "projection-notified-\(Self.dayKey(Date()))"
            if !defaults.bool(forKey: key) {
                notify(title: "Projeção acima da quota", body: "No ritmo atual, o uso pode ultrapassar os créditos incluídos.")
                defaults.set(true, forKey: key)
            }
        }
        // `spent > 0` evita o aviso "0 de 0 cr" quando o automático zera com a quota esgotada.
        if let budget = metrics?.dailyBudget, budget.state == .over, budget.spent > 0 {
            let key = "budget-notified-\(Self.dayKey(Date()))"
            if !defaults.bool(forKey: key) {
                notify(
                    title: "Orçamento diário estourado",
                    body: "Você usou \(Self.number(budget.spent)) de \(Self.number(budget.limit)) cr hoje."
                )
                defaults.set(true, forKey: key)
            }
        }
        let recentPeak = (metrics?.deltas ?? [])
            .filter { $0.sample.date > Date().addingTimeInterval(-600) && !$0.duringAbsence }
            .reduce(0) { $0 + $1.amount }
        let lastPeak = defaults.double(forKey: "lastPeakNotification")
        let now = Date().timeIntervalSince1970
        if recentPeak >= peakThreshold && now - lastPeak >= 1800 {
            notify(title: "Consumo alto", body: "Consumo alto: \(Self.number(recentPeak)) cr nos últimos 10 min.")
            defaults.set(now, forKey: "lastPeakNotification")
        }
    }

    /// Compara a leitura nova com a anterior (antes de `snapshot` ser sobrescrito): novo ciclo, mudança
    /// de créditos do plano e contador zerado antes do reset. Cada aviso uma vez por chave; nunca no demo.
    private func evaluateSnapshotChange(from previous: UsageSnapshot, to current: UsageSnapshot) {
        guard notificationsEnabled, !isDemo else { return }
        let defaults = UserDefaults.standard
        func once(_ key: String, title: String, body: String) {
            guard !defaults.bool(forKey: key) else { return }
            notify(title: title, body: body)
            defaults.set(true, forKey: key)
        }
        let resetKey = current.resetDateKey
        guard previous.resetDateKey == resetKey else {
            once(
                "cycle-notified-\(resetKey)", title: "Novo ciclo do Copilot",
                body: "Ciclo anterior fechou em \(Self.number(previous.used)) de \(Self.number(previous.entitlement)) cr. "
                    + "Agora: \(Self.number(max(0, current.quotaRemaining))) cr até \(Self.resetDay(current.resetDate))."
            )
            return
        }
        if current.entitlement != previous.entitlement {
            once(
                "entitlement-notified-\(resetKey)-\(Self.keyNumber(current.entitlement))",
                title: "Créditos do plano mudaram",
                body: "De \(Self.number(previous.entitlement)) para \(Self.number(current.entitlement)) cr por ciclo."
            )
        }
        // Mesma regra de `MetricsEngine.deltas`: queda de mais de 1 cr é reset do contador.
        if current.used < previous.used - 1 {
            once(
                "early-reset-\(resetKey)-\(Self.dayKey(Date()))", title: "Quota zerada antes do reset",
                body: "O contador caiu de \(Self.number(previous.used)) para \(Self.number(current.used)) cr."
            )
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

    /// `01/10`: dia do reset em UTC, o calendário em que a API define `quota_reset_date`.
    private static func resetDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd/MM"
        return formatter.string(from: date)
    }

    /// Número estável para chaves de UserDefaults (`4000`, `1500.5`), sem separador de milhar.
    private static func keyNumber(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
