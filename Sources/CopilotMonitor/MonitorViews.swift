import AppKit
import Charts
import CopilotMonitorCore
import ServiceManagement
import SwiftUI
import UserNotifications

struct MonitorPopoverView: View {
    @ObservedObject var model: MonitorModel
    @State private var showActivity = false
    @State private var activityMode: ActivityMode = .calendar
    @State private var showStats = true

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
                    statistics(metrics)
                    activitySection(metrics)
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
                if metrics?.activeSession != nil {
                    // Atualiza a duração a cada minuto mesmo sem nova leitura (demo, offline, intervalo longo).
                    TimelineView(.everyMinute) { _ in
                        if let session = model.metrics?.activeSession { activeSessionLine(session) }
                    }
                }
                if let budget = metrics?.dailyBudget { budgetLine(budget) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(MonitorModel.number(model.currentUsed)) cr")
                        .font(.system(.title3, design: .rounded, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color(nsColor: model.statusColor))
                }
                if let days = metrics?.sparkline, !days.isEmpty { sparkline(days) }
            }
        }
    }

    /// Créditos por dia dos últimos 14 dias: área em gradiente, linha suave e ponto em hoje.
    private func sparkline(_ days: [DailyTotal]) -> some View {
        let maxCredits = days.map(\.credits).max() ?? 0
        return Chart {
            ForEach(days, id: \.date) { day in
                AreaMark(x: .value("Dia", day.date), y: .value("Créditos", day.credits))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(
                        colors: [Color.accentColor.opacity(0.4), Color.accentColor.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    ))
                LineMark(x: .value("Dia", day.date), y: .value("Créditos", day.credits))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            if let today = days.last {
                PointMark(x: .value("Dia", today.date), y: .value("Créditos", today.credits))
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(16)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        // Folga no topo para o ponto de hoje não ser cortado quando é o máximo.
        .chartYScale(domain: 0...max(1, maxCredits * 1.15))
        .frame(width: 90, height: 22)
        .help("Últimos 14 dias")
    }

    /// `● Sessão ativa · 23 min · 84 cr`, com duração = agora − início.
    private func activeSessionLine(_ session: InferredSession) -> some View {
        HStack(spacing: 5) {
            activeDot
            Text("Sessão ativa · \(activeDuration(Date().timeIntervalSince(session.start))) · \(MonitorModel.number(session.credits)) cr")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private var activeDot: some View {
        Circle().fill(Color.green).frame(width: 6, height: 6)
    }

    /// `23 min`, `1h 05 min`.
    private func activeDuration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        guard minutes >= 60 else { return "\(minutes) min" }
        return String(format: "%dh %02d min", minutes / 60, minutes % 60)
    }

    /// Orçamento diário em três estados: ok (cinza), warning (laranja com ícone), over (laranja).
    @ViewBuilder
    private func budgetLine(_ budget: BudgetStatus) -> some View {
        let spent = MonitorModel.number(budget.spent)
        let limit = MonitorModel.number(budget.limit)
        let summary = "Hoje \(spent) / \(limit) cr do orçamento"
        switch budget.state {
        case .ok:
            Text(summary)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        case .warning:
            Label(
                "\(MonitorModel.number(budget.percent.rounded(.down)))% do orçamento diário",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption).foregroundStyle(.orange)
            .lineLimit(1).minimumScaleFactor(0.8)
            .help(summary)
        case .over:
            Text("Orçamento diário de \(limit) cr estourado · \(spent) cr")
                .font(.caption).foregroundStyle(.orange)
                .lineLimit(1).minimumScaleFactor(0.8)
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
                if let previous = metrics.previousCycle {
                    Text("anterior: \(MonitorModel.number(previous.used)) cr")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
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
                if metrics.projectionSource == .previousCycle {
                    if let previous = metrics.previousCycle {
                        Text("Ciclo recém-iniciado · ciclo anterior fechou em \(MonitorModel.number(previous.used)) cr")
                            .help(metrics.projectedAtReset.map {
                                "Projeção no reset pelo ciclo anterior: \(MonitorModel.number($0)) cr"
                            } ?? "")
                    } else {
                        Text("Ciclo recém-iniciado · sem ciclo anterior registrado")
                    }
                } else if let projected = metrics.projectedAtReset {
                    Text("Projeção no reset: \(MonitorModel.number(projected)) cr")
                } else {
                    Text("Projeção no reset: sem taxa suficiente")
                }
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(.secondary)
            if let previousAt = metrics.previousCycleAtSamePoint {
                (Text("Neste ponto do ciclo anterior: \(MonitorModel.number(previousAt)) cr")
                    + previousCycleDeltaText(metrics.deltaVsPreviousCyclePercent))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let previous = metrics.previousCycle {
                Text("Ciclo anterior: \(MonitorModel.number(previous.used)) / \(MonitorModel.number(previous.entitlement)) cr")
                    .font(.caption).foregroundStyle(.secondary)
            }
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

    /// ` (+12%)` com a cor do delta; vazio quando não há percentual.
    private func previousCycleDeltaText(_ percent: Double?) -> Text {
        guard percent != nil else { return Text("") }
        return Text(" (\(deltaText(percent)))").foregroundStyle(deltaColor(percent))
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
            trendStats(metrics)
        }
    }

    private func trendStats(_ metrics: UsageMetrics) -> some View {
        let trend = metrics.trend
        let hourly = metrics.isHourlyChart
        return HStack(spacing: 8) {
            miniStat(
                title: hourly ? "Média/h" : "Média/dia",
                value: "\(MonitorModel.number(trend.averagePerBucket)) cr"
            )
            miniStat(title: "Pico", value: trend.peak.map { peakText($0, hourly: hourly) } ?? "—")
            miniStat(
                title: comparisonTitle, value: deltaText(trend.deltaPercent),
                color: deltaColor(trend.deltaPercent)
            )
        }
    }

    private func miniStat(title: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(value)
                .font(.system(.subheadline, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var comparisonTitle: String {
        switch model.selectedPeriod {
        case .today: return "vs ontem"
        case .sevenDays: return "vs 7d anteriores"
        case .thirtyDays: return "vs 30d anteriores"
        case .cycle: return "vs ciclo anterior"
        }
    }

    private func peakText(_ bucket: UsageBucket, hourly: Bool) -> String {
        let credits = "\(MonitorModel.number(bucket.total)) cr"
        if hourly { return "\(credits) às \(Calendar.current.component(.hour, from: bucket.date))h" }
        return "\(credits) · \(Self.shortDay(bucket.date))"
    }

    private func deltaText(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        let rounded = percent.rounded()
        if rounded > 0 { return "+\(MonitorModel.number(rounded))%" }
        if rounded < 0 { return "−\(MonitorModel.number(-rounded))%" }
        return "0%"
    }

    private func deltaColor(_ percent: Double?) -> Color {
        guard let rounded = percent?.rounded() else { return .secondary }
        if rounded > 0 { return .orange }
        if rounded < 0 { return .green }
        return .primary
    }

    private func sessions(_ metrics: UsageMetrics) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Sessões inferidas")
            if metrics.sessions.isEmpty {
                Text("Nenhuma sessão neste período.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                // A sessão do período que termina junto com a sessão ativa é a que está em andamento.
                let activeEnd = metrics.activeSession?.end
                let hasActive = activeEnd != nil && metrics.sessions.contains { $0.end == activeEnd }
                ForEach(Array(metrics.sessions.reversed().enumerated()), id: \.offset) { _, session in
                    let isActive = hasActive && session.end == activeEnd
                    HStack {
                        if hasActive {
                            // Reserva o espaço do círculo nas demais linhas para manter o alinhamento.
                            if isActive { activeDot } else { Color.clear.frame(width: 6, height: 6) }
                        }
                        Text("\(session.start.formatted(date: .omitted, time: .shortened))–\(isActive ? "agora" : session.end.formatted(date: .omitted, time: .shortened))")
                            .font(.caption.monospacedDigit())
                        Text("· \(duration(isActive ? Date().timeIntervalSince(session.start) : session.duration))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(MonitorModel.number(session.credits)) cr").font(.caption.monospacedDigit())
                    }
                }
            }
        }
    }

    private func statistics(_ metrics: UsageMetrics) -> some View {
        let stats = metrics.stats
        let isToday = model.selectedPeriod == .today
        return VStack(alignment: .leading, spacing: 5) {
            collapsibleHeader("Estatísticas", isExpanded: $showStats)
            if showStats {
                if !isToday {
                    StatRow(label: "Dias ativos", value: "\(stats.activeDays) de \(stats.elapsedDays)")
                    StatRow(label: "Dia mais ativo", value: stats.mostActiveWeekday.map {
                        "\(Self.weekdayName($0)) · \(MonitorModel.number(stats.mostActiveWeekdayCredits)) cr"
                    } ?? "—")
                    StatRow(label: "Maior dia", value: stats.peakDay.map {
                        "\(MonitorModel.number($0.total)) cr · \(Self.shortDay($0.date))"
                    } ?? "—")
                }
                StatRow(label: "Sessões", value: stats.sessionCount > 0
                        ? "\(stats.sessionCount) · média \(MonitorModel.number(stats.averagePerSession)) cr"
                        : "0")
                StatRow(label: "Sessão mais cara", value: stats.costliestSession.map {
                    sessionText($0, withDate: !isToday)
                } ?? "—")
                StatRow(label: "Sequência atual", value: streakText(stats.currentStreak))
                StatRow(label: "Maior sequência", value: streakText(stats.longestStreak))
            }
        }
    }

    private func sessionText(_ session: InferredSession, withDate: Bool) -> String {
        let range = "\(Self.clockTime(session.start))–\(Self.clockTime(session.end))"
        let credits = "\(MonitorModel.number(session.credits)) cr"
        return withDate ? "\(Self.shortDay(session.start)) \(range) · \(credits)" : "\(range) · \(credits)"
    }

    private func streakText(_ days: Int) -> String {
        switch days {
        case 0: return "—"
        case 1: return "1 dia"
        default: return "\(days) dias"
        }
    }

    private func collapsibleHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.wrappedValue.toggle() }
        } label: {
            HStack {
                sectionTitle(title)
                Spacer()
                Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
                    .font(.caption)
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func activitySection(_ metrics: UsageMetrics) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            collapsibleHeader("Atividade", isExpanded: $showActivity)
            if showActivity {
                HStack {
                    Picker("Modo", selection: $activityMode) {
                        ForEach(ActivityMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    Spacer()
                    Text(activityMode == .calendar ? "últimas 13 semanas" : "últimos 30 dias")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                switch activityMode {
                case .calendar: contributionCalendar(metrics.calendarDays)
                case .hourly: heatmap
                }
            }
        }
    }

    /// 13 semanas (colunas, da mais antiga à atual) × 7 dias (linhas, segunda a domingo) e mini-estatísticas.
    private func contributionCalendar(_ days: [DailyTotal]) -> some View {
        let grid = ContributionGrid(days: days, weeks: 13, calendar: .current)
        let maxCredits = grid.visibleDays.map(\.credits).max() ?? 0
        let stats = MetricsEngine.contributionStats(grid.visibleDays)
        let cell = ContributionGrid.cellSize
        let spacing = ContributionGrid.spacing
        let labelWidth: CGFloat = 10
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: spacing) {
                HStack(spacing: spacing) {
                    Color.clear.frame(width: labelWidth, height: 1)
                    ForEach(grid.monthLabels.indices, id: \.self) { week in
                        // Largura de uma célula; o texto transborda para a direita sobre as colunas seguintes.
                        Text(grid.monthLabels[week] ?? "")
                            .font(.system(size: 8)).foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(width: cell, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: spacing) {
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { row in
                            Text(["S", "", "Q", "", "S", "", ""][row])
                                .font(.system(size: 8)).foregroundStyle(.secondary)
                                .frame(width: labelWidth, height: cell)
                        }
                    }
                    ForEach(grid.columns.indices, id: \.self) { week in
                        VStack(spacing: spacing) {
                            ForEach(0..<7, id: \.self) { row in
                                contributionCell(grid.columns[week][row], maxCredits: maxCredits)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                miniStat(title: "Dias ativos", value: "\(stats.activeDays)")
                miniStat(title: "Média/dia ativo", value: "\(MonitorModel.number(stats.averageActiveDay)) cr")
                miniStat(title: "Pico", value: stats.peak.map {
                    "\(MonitorModel.number($0.credits)) cr · \(Self.shortDay($0.date))"
                } ?? "—")
                miniStat(title: "Sequência", value: stats.currentStreak > 0 ? "\(stats.currentStreak)d" : "—")
            }
        }
    }

    /// Célula de 9 pt com a cor do nível; dias futuros ocupam o espaço mas ficam invisíveis.
    @ViewBuilder
    private func contributionCell(_ day: DailyTotal?, maxCredits: Double) -> some View {
        let size = ContributionGrid.cellSize
        if let day {
            RoundedRectangle(cornerRadius: 1)
                .fill(contributionColor(MetricsEngine.contributionLevel(value: day.credits, maxValue: maxCredits)))
                .frame(width: size, height: size)
                .help("\(Self.shortDay(day.date)) · \(MonitorModel.number(day.credits)) cr")
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    /// Vazio `secondary.opacity(0.12)`; níveis 1–4 `accentColor.opacity(0.25 / 0.45 / 0.7 / 1.0)`.
    private func contributionColor(_ level: Int) -> Color {
        let opacities = [0.25, 0.45, 0.7, 1.0]
        guard level > 0 else { return Color.secondary.opacity(0.12) }
        return Color.accentColor.opacity(opacities[min(level, opacities.count) - 1])
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
                        Text("Reset \(reset.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Locale(identifier: "pt_BR"), timeZone: TimeZone(secondsFromGMT: 0)!)))")
                            .help("O GitHub reseta a quota à meia-noite UTC.")
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

    /// `12 set`
    private static func shortDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date).replacingOccurrences(of: ".", with: "")
    }

    /// `09:12`
    private static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// `quarta` para Calendar.weekday == 4.
    private static func weekdayName(_ weekday: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "pt_BR")
        let symbols = calendar.weekdaySymbols
        guard symbols.indices.contains(weekday - 1) else { return "—" }
        return symbols[weekday - 1].replacingOccurrences(of: "-feira", with: "")
    }
}

/// Modo da seção `Atividade`; não é persistido.
private enum ActivityMode: String, CaseIterable, Identifiable {
    case calendar, hourly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .calendar: return "Calendário"
        case .hourly: return "Por hora"
        }
    }
}

/// Disposição dos dias do calendário em semanas de segunda a domingo, terminando na semana atual.
private struct ContributionGrid {
    static let cellSize: CGFloat = 9
    static let spacing: CGFloat = 3

    /// `columns[semana][linha]`, linha 0 = segunda; nil nos dias futuros da semana atual.
    let columns: [[DailyTotal?]]
    /// Abreviação do mês (`set`) nas colunas cuja segunda-feira está num mês diferente da coluna anterior.
    let monthLabels: [String?]
    /// Dias que aparecem na grade (até hoje): base da escala de cores e das mini-estatísticas.
    let visibleDays: [DailyTotal]

    /// `days`: dias contíguos e ordenados, último = hoje (`UsageMetrics.calendarDays`).
    init(days: [DailyTotal], weeks: Int, calendar: Calendar) {
        guard let today = days.last, weeks > 0 else {
            columns = []
            monthLabels = []
            visibleDays = []
            return
        }
        // Calendar.weekday: 1 = domingo … 7 = sábado → linha 0 = segunda … 6 = domingo.
        let todayRow = (calendar.component(.weekday, from: today.date) + 5) % 7
        let slots = (weeks - 1) * 7 + todayRow + 1
        let visible = Array(days.suffix(slots))
        // Células antes do primeiro dia disponível (0 com os 91 dias de `calendarDays`).
        let leading = slots - visible.count
        let columns = (0..<weeks).map { week in
            (0..<7).map { row -> DailyTotal? in
                let index = week * 7 + row - leading
                return visible.indices.contains(index) ? visible[index] : nil
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "LLL"
        var labels: [String?] = []
        var previousMonth: Int?
        for column in columns {
            let first = column.compactMap { $0 }.first
            let month = first.map { calendar.component(.month, from: $0.date) }
            if let first, let month, let previousMonth, month != previousMonth {
                labels.append(formatter.string(from: first.date).replacingOccurrences(of: ".", with: ""))
            } else {
                labels.append(nil)
            }
            if month != nil { previousMonth = month }
        }
        self.columns = columns
        monthLabels = labels
        visibleDays = visible
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.caption)
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

            Section("Orçamento diário") {
                Picker("Modo", selection: Binding(
                    get: { model.dailyBudgetMode },
                    set: { model.setDailyBudgetMode($0) }
                )) {
                    ForEach(DailyBudgetMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                if model.dailyBudgetMode == .manual {
                    HStack {
                        Text("Limite")
                        TextField("120", value: Binding(
                            get: { model.dailyBudgetCredits },
                            set: { model.setDailyBudgetCredits($0) }
                        ), format: .number)
                        .frame(width: 70)
                        Text("cr por dia").foregroundStyle(.secondary)
                    }
                }
                if let caption = budgetCaption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
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

    /// Valor resolvido do orçamento de hoje (`Hoje: 120 cr`); nil quando desligado.
    private var budgetCaption: String? {
        guard model.dailyBudgetMode != .off else { return nil }
        if let limit = model.metrics(for: .today)?.dailyBudget?.limit {
            return "Hoje: \(MonitorModel.number(limit)) cr"
        }
        return model.snapshot == nil ? "Hoje: aguardando a primeira leitura" : "Hoje: sem dias úteis até o reset"
    }
}

extension Notification.Name {
    static let openMonitorPreferences = Notification.Name("CopilotMonitor.openPreferences")
}
