import Foundation

public enum DemoData {
    /// Dois ciclos: amostras desde 45 dias atrás, com a chave do ciclo anterior (`resetDate − 1 mês`)
    /// antes de `cycleStart` e `used` zerando em `cycleStart`. `cycles` traz o ciclo anterior fechado.
    /// O reset é meia-noite UTC daqui a 7 dias, como `quota_reset_date_utc` da API, e os limites de ciclo
    /// saem de `MetricsEngine.cycleRange` (UTC); `calendar` só define os padrões por dia e hora locais.
    public static func make(
        now: Date = Date(), calendar: Calendar = .current
    ) -> (samples: [UsageSample], snapshot: UsageSnapshot, cycles: [CycleSummary]) {
        let utc = MetricsEngine.cycleCalendar
        let resetDate = utc.date(byAdding: .day, value: 7, to: utc.startOfDay(for: now))!
        let cycleStart = MetricsEngine.cycleRange(resetDate: resetDate).start
        let previousCycleStart = MetricsEngine.cycleRange(resetDate: resetDate, offset: -1).start
        let assignedDate = Self.assignedDate(forReset: resetDate)
        let key = resetKey(resetDate)
        let previousKey = resetKey(cycleStart)
        // Alinha na grade de 5 min para que os filtros por minuto abaixo casem independentemente da hora de abertura.
        var timestamp = Int64(now.addingTimeInterval(-45 * 86400).timeIntervalSince1970) / 300 * 300
        let end = Int64(now.timeIntervalSince1970)
        // O histórico começa no meio do ciclo anterior: ~100 cr por dia já decorrido dele.
        let firstDate = Date(timeIntervalSince1970: TimeInterval(timestamp))
        var used = (max(0, firstDate.timeIntervalSince(previousCycleStart)) / 86400 * 100).rounded()
        var inPreviousCycle = firstDate < cycleStart
        var previousCycleUsed: Double?
        var samples = [UsageSample(
            timestamp: timestamp, used: used, entitlement: 4000, overage: 0,
            resetDate: inPreviousCycle ? previousKey : key
        )]
        var index = 0
        while timestamp + 300 <= end {
            timestamp += 300
            index += 1
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            if inPreviousCycle && date >= cycleStart {
                // Reset: o ciclo anterior fecha com o último `used` e o contador recomeça.
                previousCycleUsed = used
                used = 0
                inPreviousCycle = false
            }
            let parts = calendar.dateComponents([.day, .hour, .minute, .weekday], from: date)
            let day = parts.day ?? 0
            let hour = parts.hour ?? 0
            let minute = parts.minute ?? 0
            // Sem lacunas na última meia hora, para a sessão ativa não cair em "durante ausência".
            let recent = date > now.addingTimeInterval(-1800)
            if !recent && day % 4 == 0 && hour == 12 && [0, 5, 10].contains(minute) { continue }
            var increment = 0.0
            // Intensidade por dia da semana, para o calendário e a sparkline terem níveis variados:
            // segunda a quinta manhã e tarde, sexta só a tarde, sábado só a manhã, domingo uma hora.
            let morning = hour >= 9 && hour < 12
            let afternoon = hour >= 14 && hour < 18
            let active: Bool
            switch parts.weekday {
            case 1: active = hour == 10
            case 6: active = afternoon
            case 7: active = morning
            default: active = morning || afternoon
            }
            // Ciclo anterior ~20% mais leve (média 2,4 contra 3), para a comparação no mesmo ponto ter diferença visível.
            // Módulo ímpar: a cada 10 min `index` avança 2 e percorre todos os restos, sem depender da hora de início.
            if active && minute % 10 == 0 {
                increment = inPreviousCycle ? [1, 2, 2, 3, 4][index % 5] : Double(1 + index % 5)
            }
            if abs(date.timeIntervalSince(now.addingTimeInterval(-2 * 3600))) < 150 { increment += 55 }
            // Consumo nos últimos 10 min (+4 a cada leitura de 5 min) para haver sessão ativa no demo.
            if date > now.addingTimeInterval(-600) { increment += 4 }
            used += increment
            samples.append(UsageSample(
                timestamp: timestamp, used: used, entitlement: 4000,
                overage: max(0, used - 4000), resetDate: inPreviousCycle ? previousKey : key
            ))
        }
        let snapshot = UsageSnapshot(
            login: "demo-user", plan: "business", assignedDate: assignedDate,
            resetDate: resetDate, resetDateKey: key, entitlement: 4000,
            quotaRemaining: 4000 - used, used: used, overage: max(0, used - 4000),
            timestamp: now, rawJSON: Data("{\"demo\":true}".utf8)
        )
        let cycles = previousCycleUsed.map { [CycleSummary(resetDate: previousKey, entitlement: 4000, used: $0)] } ?? []
        return (samples, snapshot, cycles)
    }

    /// Prepara o banco do modo demo, igual para o app e para o CLI: regrava as amostras quando o banco
    /// está vazio, quando a última leitura tem mais de 10 min (numa reabertura depois disso a sessão ativa do
    /// demo já teria expirado) ou quando ela é de outra chave de ciclo (o reset do demo avança à meia-noite
    /// UTC), grava o ciclo anterior fechado e devolve o snapshot da última amostra gravada, com a chave dela
    /// (nil só se o banco continuar vazio).
    @discardableResult
    public static func seed(
        _ store: SQLiteUsageStore, now: Date = Date(), calendar: Calendar = .current
    ) throws -> UsageSnapshot? {
        let seeded = make(now: now, calendar: calendar)
        let base = seeded.snapshot
        let stale = try store.latestSample().map {
            now.timeIntervalSince($0.date) > 600 || $0.resetDate != base.resetDateKey
        } ?? true
        if stale {
            try store.removeAllSamples()
            try store.append(contentsOf: seeded.samples)
        }
        for cycle in seeded.cycles {
            try store.upsertCycle(cycle, closedAt: GitHubResponseParser.parseDate(cycle.resetDate) ?? now)
        }
        guard let last = try store.latestSample() else { return nil }
        // Datas do ciclo pela chave das amostras gravadas, para o snapshot nunca divergir delas.
        let resetDate = GitHubResponseParser.parseDate(last.resetDate) ?? base.resetDate
        return UsageSnapshot(
            login: base.login, plan: base.plan, assignedDate: assignedDate(forReset: resetDate),
            resetDate: resetDate, resetDateKey: last.resetDate, entitlement: last.entitlement,
            quotaRemaining: last.entitlement - last.used, used: last.used, overage: last.overage,
            timestamp: last.date, rawJSON: base.rawJSON
        )
    }

    /// Atribuição do demo: 2 dias depois do início do ciclo que termina em `resetDate`.
    private static func assignedDate(forReset resetDate: Date) -> Date {
        let cycleStart = MetricsEngine.cycleRange(resetDate: resetDate).start
        return MetricsEngine.cycleCalendar.date(byAdding: .day, value: 2, to: cycleStart)!
    }

    private static func resetKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
