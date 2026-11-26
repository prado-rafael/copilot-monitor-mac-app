/// Limiares da quota real do ciclo, independentes do orçamento diário e da projeção.
public enum CycleQuotaAlert: Int, CaseIterable {
    case warning = 85
    case critical = 90
    case urgent = 95
    case exhausted = 100

    /// Só o maior limiar alcançado; quedas no mesmo ciclo não rearmam avisos já superados.
    public static func reached(at percent: Double, after lastNotifiedThreshold: Int = 0) -> Self? {
        guard percent.isFinite else { return nil }
        return allCases.last { $0.rawValue > lastNotifiedThreshold && percent >= Double($0.rawValue) }
    }
}
