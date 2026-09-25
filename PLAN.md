# Plano de implementação — paridade com o CodeBurn via API

Seis itens, todos calculados apenas com o que já existe: as leituras do endpoint
`copilot_internal/user` gravadas em `samples` no SQLite. Nada de arquivos locais do
Copilot, nada de dependências de terceiros, nada de XCTest. UI em pt-BR.

Referência de arquitetura (leia antes de começar qualquer item):

- `Sources/CopilotMonitorCore/MetricsEngine.swift` — lógica pura. `analyze(...)` devolve `UsageMetrics`.
- `Sources/CopilotMonitorCore/SQLiteUsageStore.swift` — tabelas `samples` e `metadata`.
- `Sources/CopilotMonitorCore/DemoData.swift` — dados sintéticos do modo demo.
- `Sources/CopilotMonitor/MonitorModel.swift` — estado, polling, preferências, notificações.
- `Sources/CopilotMonitor/MonitorViews.swift` — popover (`MonitorPopoverView`) e `PreferencesView`.
- `Sources/CopilotMonitor/AppDelegate.swift` — status item, popover, menu de contexto.
- `Sources/CopilotMonitor/main.swift` — entrada do app.
- `Sources/CopilotMonitorSelfTest/main.swift` — asserts (helper `check(_:_:)`).

## Regras válidas para todos os itens

1. Lógica nova vai em `CopilotMonitorCore` como função pura, com assert no self-test.
   A camada de app só formata e exibe.
2. `MetricsEngine.analyze` continua compilando para quem chama hoje: parâmetros novos têm
   valor padrão; campos novos em `UsageMetrics` são adicionados ao `init` existente.
3. Ao terminar cada item: `swift build` sem erros e sem warnings novos,
   `swift run CopilotMonitorSelfTest` passando, e o modo demo
   (`COPILOT_MONITOR_DEMO=1`) exibindo a feature com dados sintéticos. Ajuste
   `DemoData` quando a feature precisar de dados que ele ainda não gera.
4. Textos de UI em pt-BR, números formatados com `MonitorModel.number(_:)`, dólares com o
   formatter já existente (`1 cr = US$ 0,01`).
5. Não faça commit. O usuário revisa o diff e decide.
6. Não altere a largura do popover (380 pt). Seções novas entram no `ScrollView` existente.
7. Não invente métricas por modelo, projeto ou repositório: a API não expõe isso.

## Item 0 (pré-requisito do item 1): cache de métricas no modelo

Hoje `MonitorModel.metrics`, `metrics(for:)`, `peakIsActive` e `evaluateNotifications`
recalculam `MetricsEngine.analyze` ou `MetricsEngine.deltas` em cada acesso, e a view
acessa `metrics` várias vezes por render. Com os itens abaixo o cálculo fica mais pesado.

- Adicionar em `MonitorModel` um cache `[MetricsCacheKey: UsageMetrics]` onde a chave é
  `(period, periodOffset, samplesVersion, sessionGapMinutes, minuteBucket)` e
  `minuteBucket = Int(Date().timeIntervalSince1970 / 60)`.
- `samplesVersion` é um `Int` incrementado sempre que `samples` muda (append no `refresh`,
  carga inicial, reset do demo).
- Limpar o cache quando `samplesVersion`, `sessionGapMinutes` ou as configurações de
  orçamento (item 2) mudarem. Um cache com no máximo ~8 entradas basta; descarte tudo
  quando passar disso.
- `peakIsActive` e `evaluateNotifications` passam a usar `metrics.deltas` em vez de
  recalcular `MetricsEngine.deltas(samples:)`.

Aceite: comportamento idêntico ao atual; self-test inalterado passa.

## Item 1: estatísticas do Trend e do Stats

### Core

Novos tipos em `MetricsEngine.swift`:

```swift
public struct TrendStats: Sendable, Equatable {
    public let total: Double            // soma de observed + duringAbsence dos buckets do período
    public let averagePerBucket: Double // total / buckets decorridos (ver abaixo)
    public let peak: UsageBucket?       // bucket com maior (observed + duringAbsence); nil se total == 0
    public let activeBuckets: Int       // buckets com total > 0
    public let previousTotal: Double?   // total do mesmo período com offset − 1; nil se não há deltas lá
    public let deltaPercent: Double?    // (total − previousTotal) / previousTotal × 100; nil se previousTotal é nil ou 0
}

public struct PeriodStats: Sendable, Equatable {
    public let activeDays: Int               // dias do período com créditos > 0
    public let elapsedDays: Int              // dias do período já decorridos (até hoje inclusive), mínimo 1
    public let mostActiveWeekday: Int?       // Calendar.weekday (1 = domingo … 7 = sábado) com maior soma no período
    public let mostActiveWeekdayCredits: Double
    public let peakDay: UsageBucket?         // dia com maior total no período (buckets diários mesmo quando o gráfico é por hora)
    public let sessionCount: Int
    public let averagePerSession: Double     // 0 se não há sessões
    public let costliestSession: InferredSession?
    public let currentStreak: Int            // ver regra abaixo
    public let longestStreak: Int            // ver regra abaixo
}
```

Regras:

- **Buckets decorridos**: para `.today` com `periodOffset == 0`, horas desde o início do dia
  até agora, arredondando para cima, mínimo 1. Para períodos diários com offset 0, dias de
  `selectedStart` até hoje inclusive. Para `periodOffset < 0`, o tamanho inteiro do período.
- **Período anterior**: `dateRange(period, offset: periodOffset − 1, ...)`, mesma função já
  existente. Some `amount` de todos os deltas nesse intervalo (inclusive `duringAbsence`).
- **Streaks** são calculadas sobre TODOS os deltas carregados, não só o período. Agrupe por
  dia local; dia ativo = total > 0. `currentStreak` começa em hoje; se hoje ainda não tem
  uso, começa em ontem; conta para trás enquanto houver dia ativo consecutivo. `longestStreak`
  é a maior sequência de dias consecutivos ativos no histórico carregado (um dia sem
  leitura quebra a sequência).
- `analyze` passa a devolver `trend: TrendStats` e `stats: PeriodStats` em `UsageMetrics`.

### UI (`MonitorPopoverView`)

- Logo abaixo do gráfico, uma linha com três mini-estatísticas no mesmo estilo dos KPIs
  (caption cinza + valor). Para `Hoje`: `Média/h`, `Pico` (`38 cr às 14h`), `vs ontem`.
  Para os demais: `Média/dia`, `Pico` (`312 cr · 12 set`), `vs 7d anteriores` /
  `vs 30d anteriores` / `vs ciclo anterior`. O delta mostra `+12%` em laranja quando
  positivo, `−8%` em verde quando negativo, `—` quando nil.
- Nova seção recolhível `Estatísticas` entre `Sessões inferidas` e o heatmap, aberta por
  padrão, com linhas `label … valor` (`StatRow`):
  - `Dias ativos` → `18 de 24` (ocultar em `Hoje`)
  - `Dia mais ativo` → `quarta · 1.240 cr` (ocultar em `Hoje`; nome via `Calendar` com locale `pt_BR`)
  - `Maior dia` → `312 cr · 12 set` (ocultar em `Hoje`)
  - `Sessões` → `14 · média 38 cr`
  - `Sessão mais cara` → `09:12–11:40 · 210 cr` (com data abreviada quando o período não é `Hoje`)
  - `Sequência atual` → `5 dias`; `Maior sequência` → `12 dias` (`—` quando 0)

### Self-test

`testTrendAndStats`: série sintética de 10 dias com um dia de pico conhecido, um dia sem
uso no meio, e uma janela anterior com total conhecido. Verificar `peak`, `deltaPercent`,
`activeDays`, `mostActiveWeekday`, `currentStreak` e `longestStreak` (monte a série para
que a maior sequência seja anterior à atual, por exemplo 4 dias, lacuna, 2 dias).

## Item 2: orçamento diário com três estados

### Core

```swift
public enum BudgetState: String, Sendable { case ok, warning, over }

public struct BudgetStatus: Sendable, Equatable {
    public let limit: Double
    public let spent: Double
    public let state: BudgetState
    public var percent: Double { limit > 0 ? spent / limit * 100 : 0 }
    public init(limit: Double, spent: Double, warningFraction: Double = 0.8)
    // state: spent >= limit → over; spent >= limit × warningFraction → warning; senão ok
}

public enum DailyBudgetSetting: Sendable, Equatable {
    case off
    case automatic          // = (remaining + gasto de hoje) / dias úteis até o reset
    case manual(Double)
}
```

O automático usa o saldo no início do dia (`remaining + spentToday`), não o `remaining`
atual, para o limite ficar estável ao longo do dia. Se usasse o `remaining` atual, o limite
encolheria a cada crédito gasto e marcaria "estourou" antes da hora.

- `analyze(..., dailyBudget: DailyBudgetSetting = .off)` devolve em `UsageMetrics`:
  `dailyBudget: BudgetStatus?` (nil quando `.off` ou quando o automático não é calculável)
  e `cycleBudget: BudgetStatus` (limit = entitlement, spent = cycleUsed).
- `spent` do orçamento diário = total de hoje (todos os deltas de hoje, inclusive ausência),
  independente do período selecionado no popover.

### Modelo e persistência

- UserDefaults: `dailyBudgetMode` (`"off" | "auto" | "manual"`, padrão `"auto"`) e
  `dailyBudgetCredits` (Double). Expor `@Published var dailyBudgetSetting`.
- Persistir também em `metadata` do SQLite, chave `settings`, um JSON com
  `{"dailyBudgetMode", "dailyBudgetCredits", "sessionGapMinutes", "peakThreshold"}`.
  Gravar na inicialização e sempre que qualquer um mudar. O item 6 lê isso no modo CLI.
- `statusColor`: laranja também quando `dailyBudget?.state == .over`.
- Novo `StatusFormat.todayVsBudget` com título `Hoje / orçamento`, texto `84 / 120`.
  Se o orçamento estiver desligado, cai para o formato `todayAndPercent`.
- Notificação (respeita `notificationsEnabled`): quando o estado vira `over`, uma vez por
  dia, chave `budget-notified-<yyyy-MM-dd>`. Título `Orçamento diário estourado`, corpo
  `Você usou X de Y cr hoje.`

### UI

- Cabeçalho: abaixo do subtítulo `@login · plano`, uma linha quando há orçamento:
  `Hoje 84 / 120 cr do orçamento` em cinza no estado ok, em laranja com ícone
  `exclamationmark.triangle.fill` no `warning` (`80% do orçamento diário`), e
  `Orçamento diário de 120 cr estourado · 131 cr` em laranja no `over`.
- Preferências, nova seção `Orçamento diário`: Picker `Desligado / Automático (dias úteis
  até o reset) / Manual`, campo numérico visível só no manual, e uma caption com o valor
  resolvido (`Hoje: 120 cr`).

### Self-test

`testBudgetStates`: 79 → ok, 80 → warning, 100 → over, limite 0 → over não dispara
divisão por zero (`percent == 0`). `analyze` com `.automatic` devolve `limit ==
(remaining + spentToday) / diasÚteis`; com `.off` devolve nil.

## Item 3: sessão ativa no cabeçalho

### Core

```swift
public static func activeSession(from deltas: [UsageDelta], now: Date, gapLimit: TimeInterval) -> InferredSession?
```

Última sessão de `sessions(from:gapLimit:)` cujo `end` está a no máximo `gapLimit` de
`now`. `analyze` devolve `activeSession: InferredSession?` calculado sobre TODOS os deltas
(não só o período), com `gapLimit = sessionGap`.

### UI

- Cabeçalho, logo abaixo do subtítulo: um círculo verde de 6 pt e o texto
  `Sessão ativa · 23 min · 84 cr` (duração = `Date()` − `start`). Sem sessão ativa, nada.
- Em `Sessões inferidas`, a sessão ativa mostra `agora` no lugar da hora de fim e o mesmo
  círculo verde.
- Tooltip do status item (`toolTip` no `AppDelegate.updateStatusItem`) passa a incluir
  `Sessão ativa · X cr` quando houver.

### Demo

`DemoData.make` precisa gerar consumo nos últimos 10 minutos antes de `now` (por exemplo
`+4` a cada 5 min) para a sessão ativa aparecer no modo demo.

### Self-test

`testActiveSession`: com `now` 5 min após o último delta positivo → não nil e créditos
corretos; com `now` 20 min depois → nil.

## Item 4: projeção com fallback do ciclo anterior e comparação entre ciclos

### Persistência

Nova tabela em `SQLiteUsageStore`:

```sql
CREATE TABLE IF NOT EXISTS cycles(
    reset_date TEXT PRIMARY KEY,
    entitlement REAL NOT NULL,
    used REAL NOT NULL,
    closed_ts INTEGER NOT NULL
);
```

Métodos: `upsertCycle(_ summary: CycleSummary, closedAt: Date)`, `cycles() -> [CycleSummary]`
ordenado por `reset_date`, e `backfillCycles(excluding currentResetDate: String)` que deriva
ciclos fechados a partir de `samples` (última leitura de cada `reset_date` diferente do
atual) e faz upsert sem sobrescrever registros já existentes.

### Core

```swift
public struct CycleSummary: Sendable, Equatable, Codable {
    public let resetDate: String     // mesma chave usada em UsageSample.resetDate
    public let entitlement: Double
    public let used: Double
    public var overage: Double { max(0, used - entitlement) }
}

public enum ProjectionSource: Sendable, Equatable { case linear, previousCycle }
```

Tornar `GitHubResponseParser.parseDate` público (ou mover para um helper público em Core)
para interpretar `resetDate` do ciclo anterior.

`analyze(..., previousCycles: [CycleSummary] = [])`:

- `previousCycle` = o de maior `resetDate` estritamente menor que a chave do ciclo atual
  (comparação de string funciona para os formatos ISO usados).
- **Fallback**: `minimumElapsedFraction = 0.03` sobre `(cycleEnd − paceStart)`. Se a fração
  decorrida for menor que isso, ou se `currentUsed − usedAtPaceStart == 0`, então
  `projectedAtReset = previousCycle.used / previousCycle.entitlement × entitlement`
  (nil se não há ciclo anterior ou entitlement anterior é 0), `projectionSource =
  .previousCycle`, `exhaustionDate = nil`. Caso contrário, projeção linear atual e
  `projectionSource = .linear`. `projectedAtResetLast24Hours` não muda.
- **Comparação no mesmo ponto**: `prevEnd = parseDate(previousCycle.resetDate)`,
  `prevStart = prevEnd − 1 mês`, `target = prevStart + (now − cycleStart)`.
  `previousCycleAtSamePoint` = `used` da última amostra com `resetDate ==
  previousCycle.resetDate` e `date <= target`; nil se não há amostras do ciclo anterior.
  `deltaVsPreviousCyclePercent = (currentUsed − prevAt) / prevAt × 100` quando `prevAt > 0`.
- Campos novos em `UsageMetrics`: `projectionSource: ProjectionSource?`,
  `previousCycle: CycleSummary?`, `previousCycleAtSamePoint: Double?`,
  `deltaVsPreviousCyclePercent: Double?`.

### Modelo

- Carregar `store.cycles()` na inicialização (modo real: chamar `backfillCycles` antes).
- No `refresh`, quando `newSnapshot.resetDateKey != snapshot.resetDateKey`, fazer upsert do
  ciclo antigo com `used`/`entitlement` do snapshot antigo e recarregar `cycles`. (A
  notificação fica no item 6.)
- Passar `previousCycles` para `analyze`.

### UI (seção Ritmo)

- Se `projectionSource == .previousCycle`: `Ciclo recém-iniciado · ciclo anterior fechou em X cr`
  (ou `Ciclo recém-iniciado · sem ciclo anterior registrado`). Senão, mantém
  `Projeção no reset: X cr`.
- Linha nova: `Neste ponto do ciclo anterior: X cr (+12%)` quando `previousCycleAtSamePoint`
  existir; senão, se `previousCycle` existir, `Ciclo anterior: X / Y cr`.
- Card `Ciclo` dos KPIs ganha caption `anterior: X cr` quando houver.

### Demo

`DemoData.make` passa a gerar dois ciclos: amostras desde 45 dias atrás, com a chave do
ciclo anterior (`resetDate − 1 mês`) antes de `cycleStart` e `used` zerando em `cycleStart`.
A tupla de retorno ganha `cycles: [CycleSummary]` com o ciclo anterior fechado; o modelo em
modo demo faz upsert deles. `testDemoData` continua passando.

### Self-test

`testProjectionFallbackAndCycleComparison`: ciclo com 1% decorrido e `previousCycles`
preenchido → `projectionSource == .previousCycle`, `projectedAtReset` igual ao anterior
escalado, `exhaustionDate == nil`. Segundo cenário com amostras do ciclo anterior tais que
no mesmo ponto `used == 50` e o atual é `60` → `deltaVsPreviousCyclePercent == 20`.
O teste existente `testPaceProjectionAndWeekdays` continua passando (50% decorrido).

## Item 5: calendário de contribuição e sparkline

### Core

```swift
public struct DailyTotal: Sendable, Equatable {
    public let date: Date       // início do dia local
    public let credits: Double
}

public static func dailyTotals(deltas: [UsageDelta], days: Int, endingAt now: Date, calendar: Calendar) -> [DailyTotal]
// zero-filled, ordenado, último elemento = hoje, exatamente `days` elementos

public static func contributionLevel(value: Double, maxValue: Double) -> Int
// 0 se value <= 0 ou maxValue <= 0; razão < 0,25 → 1; < 0,5 → 2; < 0,75 → 3; senão 4

public struct ContributionStats: Sendable, Equatable {
    public let activeDays: Int
    public let averageActiveDay: Double   // total / activeDays, 0 se nenhum
    public let peak: DailyTotal?
    public let currentStreak: Int         // mesma regra do item 1
}
public static func contributionStats(_ days: [DailyTotal]) -> ContributionStats
```

`analyze` devolve `sparkline: [DailyTotal]` (14 dias) e `calendarDays: [DailyTotal]`
(91 dias). Ambos calculados sobre todos os deltas, não só o período.

### UI

- **Sparkline** no cabeçalho, abaixo do número grande, 90 × 22 pt, com Swift Charts:
  `AreaMark` com gradiente da cor de destaque para transparente, `LineMark` com
  `.interpolationMethod(.catmullRom)`, `PointMark` no último ponto. Eixos ocultos.
  `.help("Últimos 14 dias")`.
- **Calendário**: a seção `Atividade · últimos 30 dias` vira `Atividade` com um Picker
  segmentado pequeno `Calendário | Por hora`. `Por hora` é o heatmap atual.
  `Calendário`: 13 colunas (semanas, da mais antiga à atual) × 7 linhas (segunda a domingo),
  células de 9 pt com canto 1 pt, cores por nível: vazio `secondary.opacity(0.12)`,
  níveis 1–4 `accentColor.opacity(0.25 / 0.45 / 0.7 / 1.0)`. Dias futuros da semana atual
  ficam invisíveis. Rótulos `S`, `Q`, `S` à esquerda nas linhas de segunda, quarta e sexta;
  abreviação do mês acima da coluna em que o mês muda. `.help("12 set · 312 cr")` por célula.
- Abaixo do calendário, quatro mini-estatísticas: `Dias ativos`, `Média/dia ativo`,
  `Pico` (`312 cr · 12 set`), `Sequência` (`5d`).
- A preferência de qual modo está selecionado pode ficar em `@State` (não precisa persistir).

### Self-test

`testDailyTotalsAndContribution`: `dailyTotals` devolve exatamente `days` elementos, soma
correta por dia local, zeros nos dias sem leitura; `contributionLevel` nos limiares
0,24 / 0,25 / 0,5 / 0,75 / 1,0; `contributionStats` com dois dias ativos e um pico.

## Item 6: notificação de novo ciclo e modo CLI

### Notificações (em `MonitorModel.refresh`, antes de sobrescrever `snapshot`; nunca em demo)

Compare `newSnapshot` com o `snapshot` anterior quando ambos existirem:

- `resetDateKey` mudou → upsert do ciclo antigo (item 4) e notificação
  `Novo ciclo do Copilot` / `Ciclo anterior fechou em X de Y cr. Agora: Z cr até DD/MM.`
  Uma vez por chave nova: `cycle-notified-<resetKey>`.
- Mesma chave e `entitlement` mudou → `Créditos do plano mudaram` / `De X para Y cr por ciclo.`
  Chave `entitlement-notified-<resetKey>-<Y>`.
- Mesma chave e `used` caiu mais de 1 → `Quota zerada antes do reset` /
  `O contador caiu de X para Y cr.` Chave `early-reset-<resetKey>-<yyyy-MM-dd>`.

Todas respeitam `notificationsEnabled` e usam o `notify(title:body:)` existente.

### Modo CLI

`main.swift` inspeciona `CommandLine.arguments.dropFirst()` antes de criar o
`NSApplication`. Se houver `--json`, `--check`, `--help` ou `-h`, executa `CLIRunner.run(_:)`
e sai com o código devolvido; senão segue o fluxo atual.

- Novo arquivo `Sources/CopilotMonitorCore/Report.swift` com um `UsageReport: Codable`
  e `UsageReport.make(samples:snapshot:cycles:settings:now:)`. Estrutura:

  ```
  generated, login, plan, stale (Bool: lastUpdated > 5 min),
  lastUpdated,
  cycle: { used, entitlement, remaining, percent, resetDate, projectedAtReset,
           projectionSource, exhaustionDate, paceDifference, previousCycleUsed },
  today: { credits, usd, budget: { limit, spent, percent, state } | null },
  yesterday: { credits },
  burn: { lastHour, last15Minutes },
  activeSession: { start, end, credits, minutes } | null,
  streak: { current, longest }
  ```

  Datas em ISO 8601, chaves ordenadas, `prettyPrinted` a menos que `--compact`.
- Novo arquivo `Sources/CopilotMonitor/CLI.swift` (`enum CLIRunner`) que só faz I/O:
  resolve o caminho do banco igual ao `AppDelegate` (respeitando `COPILOT_MONITOR_DEMO=1`),
  abre `SQLiteUsageStore`, lê `lastResponse` e `settings` de `metadata`, amostras dos
  últimos 60 dias e `cycles()`, monta o `UsageReport` e imprime.
  - `--json`: sempre sai com 0. Em erro imprime `{"error": "mensagem"}`.
  - `--check`: imprime uma linha por orçamento no formato
    `diário: 84 / 120 cr (70%) · OK` e `ciclo: 964 / 4000 cr (24%) · OK`, com estados
    `OK` / `ATENÇÃO` / `ESTOUROU`. Sai com 1 se algum está `ESTOUROU`, 2 se não há dados,
    0 caso contrário.
  - `--help`: uso em pt-BR com os três modos e o caminho completo do binário dentro do `.app`.
- `SQLiteUsageStore.init` chama `sqlite3_busy_timeout(database, 2000)` para o leitor CLI e
  o app escritor coexistirem.
- README: seção `Linha de comando` com exemplos:
  `build/CopilotMonitor.app/Contents/MacOS/CopilotMonitor --json | jq .today` e um
  script de exemplo que usa `--check` antes de lançar um agente.

### Self-test

`testUsageReport`: `UsageReport.make` com amostras sintéticas gera JSON contendo as chaves
`cycle`, `today`, `burn`, `streak`, e `today.budget.state` coerente com o `settings`
passado.

## Ordem e verificação

Implementar na ordem 0, 1, 2, 3, 4, 5, 6. Após cada item:

```sh
swift build 2>&1 | grep -E "error|warning" ; swift run CopilotMonitorSelfTest
```

Ao final de tudo: `./build.sh` e README atualizado com as features novas (estatísticas,
orçamento diário, sessão ativa, comparação entre ciclos, calendário, notificações de ciclo,
modo CLI).
