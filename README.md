# Copilot Monitor
<img src ="sample.png"/>

App de barra de menus para acompanhar os créditos de uso do Copilot pela API do GitHub. Os dados ficam em `~/Library/Application Support/CopilotMonitor/usage.sqlite`; nenhum log local do Copilot é lido.

## Recursos

- Estatísticas do período: média, pico e variação contra o período anterior, dias ativos, dia mais ativo, sessões e sequências de dias.
- Orçamento diário (automático pelos dias úteis até o reset, ou manual) com três estados: ok, atenção a partir de 80% e estourado.
- Sessão ativa no cabeçalho e no tooltip da barra.
- Comparação com o ciclo anterior no mesmo ponto; no início de um ciclo, a projeção usa o ciclo anterior como referência.
- Calendário de atividade das últimas 13 semanas e sparkline dos últimos 14 dias.
- Notificações de novo ciclo, mudança nos créditos do plano e quota zerada antes do reset, além das de quota, projeção, orçamento e pico.

## Compilar

Requer macOS 14+, Swift 5.10 e Command Line Tools. Execute `./build.sh`; o app será criado em `build/CopilotMonitor.app`. O primeiro acesso usa `gh auth token` (com `gh` em `/opt/homebrew/bin` ou `/usr/local/bin`); um token alternativo pode ser salvo no Keychain nas Preferências.

## Linha de comando

O mesmo binário lê o histórico gravado pelo app e sai, sem abrir a interface nem acessar a rede:

- `--json`: relatório em JSON (ciclo, hoje com orçamento, ontem, ritmo, sessão ativa, sequência). Sempre sai com 0; em erro imprime `{"error": "..."}`.
- `--compact`: com `--json`, o JSON sai numa linha só.
- `--check`: orçamento diário e do ciclo com `OK`, `ATENÇÃO` ou `ESTOUROU`. Sai com 1 se algum estourou, 2 se não há dados e 0 caso contrário.
- `--help`: uso completo.

```sh
build/CopilotMonitor.app/Contents/MacOS/CopilotMonitor --json | jq .today
```

Para só lançar um agente se ainda houver orçamento:

```sh
#!/bin/sh
build/CopilotMonitor.app/Contents/MacOS/CopilotMonitor --check || exit 1
exec ./meu-agente.sh "$@"
```

## Teste e demonstração

`swift run CopilotMonitorSelfTest` executa os asserts da lógica pura. Para abrir a interface com dados sintéticos e sem chamadas de rede, execute:

```sh
COPILOT_MONITOR_DEMO=1 .build/debug/CopilotMonitor
```

O modo demo usa `usage-demo.sqlite`, sem alterar o banco normal. A linha de comando também respeita `COPILOT_MONITOR_DEMO=1`.
