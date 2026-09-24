import AppKit
import Charts
import CopilotMonitorCore
import ServiceManagement
import SwiftUI
import UserNotifications

struct MonitorPopoverView: View {
    @ObservedObject var model: MonitorModel
    @State private var showHeatmap = false

    private var metrics: UsageMetrics? { model.metrics }
    private var currencyFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "US$"
        formatter.maximumFractionDigits = 2
        return formatter
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                periodPicker
                if let metrics {
                    kpis(metrics)
                    pace(metrics)
                    burn(metrics)
                    usageChart(metrics)
                    sessions(metrics)
                    heatmapSection
                } else {
                    ContentUnavailableView(
                        "Aguardando dados do GitHub",
                        systemImage: "chart.bar",
                        description: Text(model.errorMessage ?? "A primeira leitura será feita em instantes.")
                    )
                    .frame(height: 180)
                }
                footer
            }
            .padding(16)
        }
        .frame(width: 380, height: 620)
        .background(.background)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Copilot Monitor").font(.headline)
                Text(model.snapshot.map { "@\($0.login) · \($0.plan)" } ?? (model.isDemo ? "Modo demo" : "GitHub Copilot"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Text("\(MonitorModel.number(model.currentUsed)) cr")
                    .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(nsColor: model.statusColor))
            }
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 4) {
            Button { model.shiftPeriod(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).help("Período anterior")
            ForEach(UsagePeriod.allCases, id: \.self) { period in
                Button(period.title) { model.selectPeriod(period) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(model.selectedPeriod == period ? .accentColor : .secondary)
            }
            Button { model.shiftPeriod(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain).disabled(model.periodOffset >= 0)
                .help("Próximo período")
        }
        .frame(maxWidth: .infinity)
    }

    private func kpis(_ metrics: UsageMetrics) -> some View {
        HStack(spacing: 8) {
            kpi(title: model.selectedPeriod.title, credits: metrics.periodTotal)
            kpi(title: "Ontem", credits: metrics.yesterdayTotal)
            VStack(alignment: .leading, spacing: 4) {
                Text("Ciclo").font(.caption).foregroundStyle(.secondary)
                Text("\(MonitorModel.number(metrics.cycleUsed)) / \(MonitorModel.number(metrics.entitlement))")
                    .font(.system(.subheadline, design: .rounded).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func kpi(title: String, credits: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(MonitorModel.number(credits)) cr")
                .font(.system(.subheadline, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(currencyFormatter.string(from: NSNumber(value: credits / 100)) ?? "US$ 0.00")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func pace(_ metrics: UsageMetrics) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionTitle("Ritmo do ciclo")
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(Color(nsColor: model.statusColor))
                        .frame(width: width * min(1, max(0, metrics.cycleUsed / max(1, metrics.entitlement))))
                    Rectangle().fill(.primary).frame(width: 2, height: 13)
                        .offset(x: width * min(1, max(0, metrics.expectedNow / max(1, metrics.entitlement))))
                }
            }
            .frame(height: 8)
            Text("\(MonitorModel.number(abs(metrics.paceDifference))) cr \(metrics.paceDifference >= 0 ? "acima" : "abaixo") do ritmo linear")
                .font(.caption)
            HStack(spacing: 4) {
                if let projected = metrics.projectedAtReset {
                    Text("Projeção no reset: \(MonitorModel.number(projected)) cr")
                } else {
                    Text("Projeção no reset: sem taxa suficiente")
                }
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(.secondary)
            if let projected = metrics.projectedAtResetLast24Hours {
                Text("No ritmo das últimas 24h: \(MonitorModel.number(projected)) cr no reset")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let exhaustion = metrics.exhaustionDate {
                Label("Quota pode acabar \(exhaustion.formatted(date: .abbreviated, time: .shortened))", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let budget = metrics.weekdayBudget {
                Text("Orçamento: \(MonitorModel.number(budget)) cr por dia útil até o reset")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if metrics.overage > 0 {
                Text("Excedente: \(MonitorModel.number(metrics.overage)) cr · \(currencyFormatter.string(from: NSNumber(value: metrics.overage / 100)) ?? "")")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(11)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func burn(_ metrics: UsageMetrics) -> some View {
        HStack {
            Label("Ritmo atual", systemImage: "speedometer")
            Spacer()
            Text("\(MonitorModel.number(metrics.burnLastHour)) cr/h · pico \(MonitorModel.number(metrics.burnLast15Minutes)) cr/h")
                .font(.caption.monospacedDigit())
                .foregroundStyle(model.peakIsActive ? .orange : .secondary)
        }
        .font(.caption)
    }

    private func usageChart(_ metrics: UsageMetrics) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(metrics.isHourlyChart ? "Consumo por hora" : "Consumo por dia")
            if metrics.buckets.isEmpty {
                Text("Sem leituras observadas neste período.")
                    .font(.caption).foregroundStyle(.secondary).frame(height: 110)
            } else {
                Chart {
                    ForEach(metrics.buckets, id: \.date) { bucket in
                        if bucket.observed > 0 {
                            BarMark(
                                x: .value("Data", bucket.date),
                                y: .value("Créditos", bucket.observed)
                            )
                            .foregroundStyle(Color.accentColor)
                            .position(by: .value("Tipo", "Observado"))
                        }
                        if bucket.duringAbsence > 0 {
                            BarMark(
                                x: .value("Data", bucket.date),
                                y: .value("Créditos", bucket.duringAbsence)
                            )
                            .foregroundStyle(.orange)
                            .position(by: .value("Tipo", "Durante ausência"))
                        }
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(metrics.isHourlyChart
                                     ? date.formatted(.dateTime.hour())
                                     : date.formatted(.dateTime.month(.abbreviated).day()))
                            }
                        }
                    }
                }
                .frame(height: 145)
            }
        }
    }

    private func sessions(_ metrics: UsageMetrics) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Sessões inferidas")
            if metrics.sessions.isEmpty {
                Text("Nenhuma sessão neste período.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(metrics.sessions.reversed().enumerated()), id: \.offset) { _, session in
                    HStack {
                        Text("\(session.start.formatted(date: .omitted, time: .shortened))–\(session.end.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.monospacedDigit())
                        Text("· \(duration(session.duration))").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(MonitorModel.number(session.credits)) cr").font(.caption.monospacedDigit())
                    }
                }
            }
        }
    }

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showHeatmap.toggle() }
            } label: {
                HStack {
                    sectionTitle("Atividade · últimos 30 dias")
                    Spacer()
                    Image(systemName: showHeatmap ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if showHeatmap { heatmap }
        }
    }

    private var heatmap: some View {
        let values = heatmapValues()
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text("").frame(width: 18)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 4 == 0 ? "\(hour)" : "")
                        .font(.system(size: 7)).frame(maxWidth: .infinity)
                }
            }
            ForEach(0..<7, id: \.self) { weekday in
                HStack(spacing: 2) {
                    Text(["D", "S", "T", "Q", "Q", "S", "S"][weekday])
                        .font(.system(size: 8)).frame(width: 18)
                    ForEach(0..<24, id: \.self) { hour in
                        let value = values[weekday * 24 + hour]
                        RoundedRectangle(cornerRadius: 1)
                            .fill(value == 0 ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(min(1, 0.2 + value / 20)))
                            .frame(height: 9)
                            .help("\(hour):00 · \(MonitorModel.number(value)) cr")
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Divider()
            if let status = model.offlineDescription() {
                Label(status, systemImage: "wifi.slash")
                    .font(.caption2).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            } else {
                HStack {
                    Text(model.isDemo ? "Dados sintéticos · sem acesso à rede" : updatedText)
                    Spacer()
                    if let reset = model.snapshot?.resetDate {
                        Text("Reset \(reset.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Atualizar", systemImage: "arrow.clockwise")
                }.disabled(model.isRefreshing || model.isDemo)
                Button("Abrir no GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/settings/copilot/features")!)
                }
                Button("Preferências…") { NotificationCenter.default.post(name: .openMonitorPreferences, object: nil) }
            }
            .font(.caption)
            .buttonStyle(.link)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var updatedText: String {
        guard let lastUpdated = model.lastUpdated else { return "Ainda sem atualização" }
        return "Atualizado \(lastUpdated.formatted(.relative(presentation: .named)))"
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func heatmapValues() -> [Double] {
        guard let metrics = model.metrics else { return Array(repeating: 0, count: 168) }
        var values = Array(repeating: 0.0, count: 168)
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        let calendar = Calendar.current
        for delta in metrics.deltas where delta.sample.date >= cutoff {
            let weekday = calendar.component(.weekday, from: delta.sample.date) - 1
            let hour = calendar.component(.hour, from: delta.sample.date)
            values[weekday * 24 + hour] += delta.amount
        }
        return values
    }

    private func duration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

struct PreferencesView: View {
    @ObservedObject var model: MonitorModel
    @State private var token = ""
    @State private var tokenStatus: String?
    @State private var loginItemEnabled: Bool
    @State private var loginItemError: String?

    init(model: MonitorModel) {
        self.model = model
        _loginItemEnabled = State(initialValue: model.loginItemEnabled())
    }

    var body: some View {
        Form {
            Section("Autenticação") {
                SecureField("Token override (opcional)", text: $token)
                HStack {
                    Button("Salvar no Keychain") {
                        do {
                            try model.saveTokenOverride(token)
                            token = ""
                            tokenStatus = model.tokenOverrideExists() ? "Token salvo no Keychain." : "Override removido."
                        } catch {
                            tokenStatus = "Erro ao salvar token: \(error.localizedDescription)"
                        }
                    }
                    Button("Usar `gh auth token`") {
                        do {
                            try model.saveTokenOverride("")
                            token = ""
                            tokenStatus = "O app usará o token autenticado pelo gh."
                        } catch {
                            tokenStatus = error.localizedDescription
                        }
                    }
                }
                if let tokenStatus { Text(tokenStatus).font(.caption).foregroundStyle(.secondary) }
                Text("O token não é exibido nem registrado em logs.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Coleta") {
                Picker("Intervalo", selection: Binding(
                    get: { model.interval },
                    set: { model.setInterval($0) }
                )) {
                    Text("60 segundos").tag(TimeInterval(60))
                    Text("2 minutos").tag(TimeInterval(120))
                    Text("5 minutos").tag(TimeInterval(300))
                }
                Picker("Texto na barra", selection: Binding(
                    get: { model.statusFormat },
                    set: { model.setStatusFormat($0) }
                )) {
                    ForEach(StatusFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                Toggle("Abrir no login", isOn: $loginItemEnabled)
                    .onChange(of: loginItemEnabled) { _, value in
                        do {
                            try model.setLoginItemEnabled(value)
                            loginItemError = nil
                        } catch {
                            loginItemEnabled = model.loginItemEnabled()
                            loginItemError = error.localizedDescription
                        }
                    }
                if let loginItemError { Text(loginItemError).font(.caption).foregroundStyle(.red) }
            }

            Section("Notificações") {
                Toggle("Ativar notificações", isOn: $model.notificationsEnabled)
                    .onChange(of: model.notificationsEnabled) { _, enabled in
                        UserDefaults.standard.set(enabled, forKey: "notificationsEnabled")
                        if enabled { model.requestNotificationPermission() }
                    }
                if let message = model.notificationError {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("Limite de pico")
                    TextField("40", value: $model.peakThreshold, format: .number)
                        .frame(width: 70)
                    Text("cr em 10 min").foregroundStyle(.secondary)
                }
                .onChange(of: model.peakThreshold) { _, value in UserDefaults.standard.set(value, forKey: "peakThreshold") }
                HStack {
                    Text("Agrupar sessão")
                    TextField("10", value: $model.sessionGapMinutes, format: .number)
                        .frame(width: 70)
                    Text("min").foregroundStyle(.secondary)
                }
                .onChange(of: model.sessionGapMinutes) { _, value in UserDefaults.standard.set(value, forKey: "sessionGapMinutes") }
            }
        }
        .formStyle(.grouped)
        .padding(18)
        .frame(width: 450, height: 500)
    }
}

extension Notification.Name {
    static let openMonitorPreferences = Notification.Name("CopilotMonitor.openPreferences")
}
