import CopilotMonitorCore
import Foundation

/// Modo linha de comando: lê o banco gravado pelo app, imprime e sai, sem abrir a interface nem
/// acessar a rede. Só faz I/O; os números vêm de `UsageReport.make`.
@MainActor
enum CLIRunner {
    /// Opções que fazem `main.swift` desviar para o CLI antes de criar o `NSApplication`.
    static let triggers: Set<String> = ["--json", "--check", "--help", "-h"]

    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains { triggers.contains($0) }
    }

    /// Executa o modo pedido e devolve o código de saída. Precedência: ajuda, `--check`, `--json`.
    static func run(_ arguments: [String]) -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        if arguments.contains("--check") { return check() }
        return json(pretty: !arguments.contains("--compact"))
    }

    // MARK: - Modos

    /// `--json`: sai sempre com 0; em erro imprime `{"error": "mensagem"}`.
    private static func json(pretty: Bool) -> Int32 {
        let data: Data
        do {
            data = try load().report.jsonData(pretty: pretty)
        } catch {
            data = (try? UsageReport.encoder(pretty: pretty).encode(["error": error.localizedDescription]))
                ?? Data(#"{"error": "falha ao gerar o JSON"}"#.utf8)
        }
        print(String(decoding: data, as: UTF8.self))
        return 0
    }

    /// `--check`: uma linha por orçamento. Sai com 1 se algum estourou, 2 sem dados, 0 caso contrário.
    private static func check() -> Int32 {
        let loaded: Loaded
        do {
            loaded = try load()
        } catch {
            printError(error.localizedDescription)
            return 2
        }
        let report = loaded.report
        let cycle = report.cycle.budget
        if let daily = report.today.budget {
            print(budgetLine("diário", spent: daily.spent, limit: daily.limit, percent: daily.percent, state: daily.state))
        } else {
            print(loaded.settings.dailyBudget == .off ? "diário: desligado" : "diário: sem dias úteis até o reset")
        }
        print(budgetLine("ciclo", spent: cycle.spent, limit: cycle.limit, percent: cycle.percent, state: cycle.state))
        if report.stale, let lastUpdated = report.lastUpdated {
            let minutes = (report.generated.timeIntervalSince(lastUpdated) / 60).rounded(.down)
            printError("aviso: última leitura há \(MonitorModel.number(minutes)) min; o Copilot Monitor está aberto?")
        }
        return [report.today.budget?.state, cycle.state].contains(.over) ? 1 : 0
    }

    /// `diário: 84 / 120 cr (70%) · OK`. Percentual arredondado para baixo, como no popover:
    /// `100%` só aparece quando o orçamento de fato estourou.
    private static func budgetLine(
        _ label: String, spent: Double, limit: Double, percent: Double, state: BudgetState
    ) -> String {
        let status: String
        switch state {
        case .ok: status = "OK"
        case .warning: status = "ATENÇÃO"
        case .over: status = "ESTOUROU"
        }
        let values = "\(MonitorModel.number(spent)) / \(MonitorModel.number(limit)) cr"
        return "\(label): \(values) (\(MonitorModel.number(percent.rounded(.down)))%) · \(status)"
    }

    // MARK: - Leitura

    private struct Loaded {
        let report: UsageReport
        let settings: MonitorSettings
    }

    private struct NoData: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Lê o mesmo banco do app. No demo, semeia com `DemoData.seed` (como o app faz ao abrir); no modo
    /// real, o snapshot vem da última resposta da API gravada em `metadata` e um banco inexistente não
    /// é criado.
    private static func load(now: Date = Date()) throws -> Loaded {
        let demo = MonitorDatabase.isDemo
        let url = try MonitorDatabase.url(demo: demo)
        guard demo || FileManager.default.fileExists(atPath: url.path) else {
            throw NoData("sem dados: \(url.path) não existe. Abra o Copilot Monitor para começar a coletar.")
        }
        let store = try SQLiteUsageStore(url: url)
        let snapshot: UsageSnapshot?
        if demo {
            snapshot = try DemoData.seed(store, now: now)
        } else if let raw = try store.metadata(forKey: "lastResponse") {
            do {
                snapshot = try GitHubResponseParser.parse(raw)
            } catch {
                throw NoData("a última resposta gravada não pôde ser interpretada: \(error.localizedDescription)")
            }
        } else {
            snapshot = nil
        }
        let settings: MonitorSettings = try store.metadata(forKey: MonitorSettings.metadataKey)
            .flatMap { try? JSONDecoder().decode(MonitorSettings.self, from: $0) } ?? .defaults
        let since = now.addingTimeInterval(-Double(MetricsEngine.historyDays) * 86400)
        let samples = try store.samples(since: Int64(since.timeIntervalSince1970))
        guard let snapshot else {
            throw NoData("sem dados: o Copilot Monitor ainda não gravou nenhuma resposta da API.")
        }
        guard !samples.isEmpty else {
            throw NoData("sem dados: nenhuma leitura nos últimos \(MetricsEngine.historyDays) dias.")
        }
        let report = UsageReport.make(
            samples: samples, snapshot: snapshot, cycles: try store.cycles(), settings: settings, now: now
        )
        return Loaded(report: report, settings: settings)
    }

    /// Mensagem em stderr, depois do que já foi impresso em stdout (que é bufferizado num pipe).
    private static func printError(_ message: String) {
        fflush(stdout)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static let usage = """
        Copilot Monitor: créditos de uso do Copilot na barra de menus.

        Uso:
          build/CopilotMonitor.app/Contents/MacOS/CopilotMonitor [--json [--compact] | --check | --help]

        Sem opções, abre o app na barra de menus. Com uma das opções abaixo, lê o histórico já
        gravado pelo app, imprime e sai, sem abrir a interface nem acessar a rede.

        Opções:
          --json       Relatório de uso em JSON (datas ISO 8601, chaves ordenadas). Sai sempre
                       com 0; em caso de erro imprime {"error": "mensagem"}.
          --compact    Com --json, imprime o JSON numa linha só.
          --check      Orçamento diário e do ciclo, cada um com OK, ATENÇÃO ou ESTOUROU.
                       Sai com 1 se algum estourou, 2 se não há dados e 0 caso contrário.
          --help, -h   Mostra esta ajuda.

        Dados: ~/Library/Application Support/CopilotMonitor/usage.sqlite
        Com COPILOT_MONITOR_DEMO=1, usa usage-demo.sqlite, semeado com dados sintéticos.

        Exemplos:
          build/CopilotMonitor.app/Contents/MacOS/CopilotMonitor --json | jq .today
          build/CopilotMonitor.app/Contents/MacOS/CopilotMonitor --check && ./meu-agente.sh
        """
}
