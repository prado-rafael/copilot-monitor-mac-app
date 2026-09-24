# Copilot Monitor — app de barra de menus (macOS)

Crie, nesta pasta, um app de barra de menus para macOS que monitora meu consumo de
**GitHub AI Credits do Copilot** — na linha do CodeBurn (gasto de hoje na barra, popover com
ritmo, projeção, gráficos e sessões), mas com **todos os dados vindos da API do GitHub**.
Eu uso o Copilot dentro de containers Docker, então ler logs/arquivos locais daria números
errados: não leia nada do disco sobre uso do Copilot.

## Ambiente

- macOS 14.6, Apple Silicon, Swift 5.10, **só Command Line Tools** (sem Xcode, sem XCTest).
- Swift Package Manager, **zero dependências de terceiros**.
- UI em pt-BR.

## Fonte de dados (única)

`GET https://api.github.com/copilot_internal/user`
Headers: `Authorization: Bearer <token>`, `Accept: application/json`. Não precisa (nem deve)
imitar headers de editor. A resposta tem `Cache-Control: max-age=60` e `ETag` — use
`If-None-Match` e trate `304` como "sem mudança".

Resposta real (resumida):

```json
{
  "login": "prado-rafael",
  "copilot_plan": "business",
  "assigned_date": "2026-09-23T09:53:58-03:00",
  "organization_list": [{ "login": "syngenta-digital", "name": "Syngenta Digital" }],
  "quota_reset_date": "2026-10-01",
  "quota_reset_date_utc": "2026-10-01T00:00:00.000Z",
  "token_based_billing": true,
  "quota_snapshots": {
    "chat":        { "unlimited": true, "entitlement": 0, "remaining": 0, "...": "..." },
    "completions": { "unlimited": true, "entitlement": 0, "remaining": 0, "...": "..." },
    "premium_interactions": {
      "quota_id": "premium_interactions",
      "entitlement": 4000,
      "quota_remaining": 3036.4,
      "remaining": 3036,
      "credits_used": 964,
      "percent_remaining": 75.9,
      "overage_count": 0,
      "overage_permitted": true,
      "unlimited": false,
      "timestamp_utc": "2026-09-24T13:01:54.218Z"
    }
  }
}
```

- Use `premium_interactions`. Se não existir, use o primeiro snapshot com `unlimited == false`.
- **`used = entitlement - quota_remaining`** (decimal, mais preciso). Fallback: `credits_used`.
- 1 crédito = US$ 0,01.
- `timestamp_utc` é só a hora da resposta — não indica quando o contador mudou.
- Parse tolerante (campos opcionais). Guarde o último JSON cru para debug.
- Endpoint interno/não documentado: se o formato mudar, o app mostra erro claro, não crasha.

## Token

1. Override manual salvo no Keychain (Preferências), se houver.
2. Senão, `gh auth token` (procurar `/opt/homebrew/bin/gh`, `/usr/local/bin/gh`), executado
   **fora da main thread**, resultado cacheado em memória. Em 401, reler uma vez e depois
   mostrar erro pedindo token.
- Nunca logar o token.

## Coleta e armazenamento

- Poll a cada 60s (configurável: 60s / 2 min / 5 min). Pausar no sleep
  (`NSWorkspace.willSleepNotification`), buscar na hora ao acordar (`didWakeNotification`).
- Erros de rede: manter os últimos dados, mostrar "offline há X min", backoff exponencial até 10 min.
- SQLite via `import SQLite3` (lib do sistema) em
  `~/Library/Application Support/CopilotMonitor/usage.sqlite`.
- Tabela `samples(ts INTEGER /*unix*/, used REAL, entitlement REAL, overage REAL, reset_date TEXT)`.
  Gravar **toda leitura bem-sucedida** (inclusive 304, repetindo os últimos valores) — isso
  também registra quando o app estava observando.

## Métricas (lógica pura, num target separado e testável)

Definições — siga exatamente:

- **Ciclo:** `cycleEnd = quota_reset_date_utc`, `cycleStart = cycleEnd − 1 mês`,
  `paceStart = max(cycleStart, assigned_date)`.
- **Delta** entre leituras consecutivas: `max(0, used_i − used_{i−1})`.
  Novo ciclo (reset_date mudou ou `used` caiu > 1): `delta_i = used_i`.
- **Baseline:** a primeira leitura de um ciclo tem `used` = "consumo antes do monitoramento" —
  entra no total do ciclo, não entra em hoje/hora/sessões.
- **Lacuna:** se `ts_i − ts_{i−1} > 10 min` (Mac dormindo/offline), o delta conta no total do
  dia de `ts_i`, mas é marcado como "durante ausência" e não entra em sessões nem no burn rate.
- **Períodos** (fuso local): hoje, ontem, 7 dias, 30 dias, ciclo.
- **Burn rate:** soma dos deltas dos últimos 60 min (cr/h) e dos últimos 15 min × 4.
- **Ritmo:** `esperadoAgora = entitlement × (now − paceStart) / (cycleEnd − paceStart)`;
  mostrar `used − esperadoAgora` ("X cr acima/abaixo do ritmo linear").
- **Projeção:** `taxa = (used − usedEmPaceStart) / horas desde paceStart` (use `used` total se
  não houver leitura em paceStart); também "no ritmo das últimas 24h".
  `projetadoNoReset = used + taxa × horasAtéReset`; se `remaining / taxa` < tempo até o reset,
  mostrar a data/hora em que acaba.
- **Orçamento por dia útil:** `remaining / nº de dias seg–sex de hoje (inclusive) até o reset`.
- **Excedente:** se `used > entitlement`, mostrar créditos e US$ acima do incluído.
- **Sessões inferidas:** sequência de deltas > 0 em que o intervalo entre deltas positivos
  consecutivos ≤ 10 min (configurável). Início = ts da leitura anterior ao primeiro delta
  positivo; fim = ts do último delta positivo; créditos = soma.

## UI

- **AppKit `NSStatusItem` + `NSPopover` hospedando SwiftUI** (não use `MenuBarExtra`: ele não
  permite texto colorido na barra). `LSUIElement` (sem ícone no Dock).
- **Barra:** SF Symbol `sparkles` + `42 · 24%` (créditos de hoje · % do ciclo), dígitos
  monoespaçados. Vermelho se `used ≥ entitlement`; laranja se `projetadoNoReset > entitlement`
  ou pico ativo; senão cor padrão. Formato configurável: `hoje · %` / `US$ hoje` / `% do ciclo`.
- **Popover (~360pt de largura)**, seções:
  1. Seletor de período (Hoje / 7d / 30d / Ciclo) — também com ← / →.
  2. KPIs: créditos + US$ do período, ontem, total do ciclo `964 / 4000`.
  3. Ritmo: barra de progresso com marcador do "esperado agora", texto de ritmo, projeção,
     data de esgotamento (se houver), orçamento por dia útil.
  4. Burn rate atual.
  5. Gráfico (Swift Charts): barras por hora (Hoje) ou por dia (demais períodos); deltas
     "durante ausência" com outra cor/hachura.
  6. Sessões inferidas do período (início–fim, duração, créditos).
  7. Heatmap dia da semana × hora (últimos 30 dias), recolhível.
  8. Rodapé: "atualizado há Xs", status/erro, botões Atualizar, Abrir no GitHub
     (`https://github.com/settings/copilot/features`), Preferências, Sair.
- Clique direito no ícone: `NSMenu` com Atualizar, Preferências, Copiar última resposta (debug), Sair.
- **Preferências** (janela SwiftUI): token override, intervalo, formato da barra,
  notificações (liga/desliga, limiar de pico), abrir no login (`SMAppService.mainApp`).

## Notificações (UserNotifications)

- 50 / 80 / 90 / 100% do ciclo — uma vez cada por ciclo (persistir em UserDefaults por ciclo).
- Projeção passou a exceder o entitlement — no máximo 1×/dia.
- **Pico:** ≥ 40 créditos (configurável) em 10 min, cooldown 30 min — "Consumo alto: 52 cr nos
  últimos 10 min" (serve pra pegar agente em loop esquecido num container).

## Estrutura

```
Package.swift                       # macOS 14, 3 targets
Sources/CopilotMonitorCore/         # modelos, parse, SQLite, métricas (sem AppKit/SwiftUI)
Sources/CopilotMonitor/             # app: status item, popover, prefs, notificações
Sources/CopilotMonitorSelfTest/     # executável com asserts (não há XCTest)
build.sh                            # swift build -c release → CopilotMonitor.app + codesign ad-hoc
README.md                           # curto, pt-BR
```

- `build.sh`: gera `CopilotMonitor.app` com `Info.plist` (`CFBundleIdentifier`
  `local.copilotmonitor`, `LSUIElement` true, `LSMinimumSystemVersion` 14.0) e assina ad-hoc
  (`codesign --force --deep --sign -`), necessário para Keychain e notificações.
- `swift run CopilotMonitorSelfTest` cobre: deltas e reset de ciclo, baseline, lacunas,
  agrupamento de sessões, ritmo/projeção/data de esgotamento, contagem de dias úteis.
- **Modo demo:** `COPILOT_MONITOR_DEMO=1` usa um banco separado com ~3 semanas de leituras
  sintéticas (sessões, lacunas, um pico) e não acessa a rede — para validar a UI.

## Critérios de aceite

1. `./build.sh` compila só com Command Line Tools e gera o `.app`.
2. `swift run CopilotMonitorSelfTest` passa.
3. Modo demo mostra todas as seções preenchidas.
4. Modo real: em até 60s o total do ciclo bate com
   `curl -s -H "Authorization: Bearer $(gh auth token)" https://api.github.com/copilot_internal/user`.
5. Histórico sobrevive a fechar/abrir o app.

## Não faça

- Ler logs/arquivos locais do Copilot/VS Code para uso.
- Adicionar dependências de terceiros.
- Loops de teste batendo na API — uma chamada manual para validar já basta.
- Inventar métricas por modelo/projeto: a API não expõe isso para membro comum da org.
