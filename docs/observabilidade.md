# Observabilidade — contrato de logs

Base criada na Entrega 3.3 (2026-10-07). Cada serviço escreve **uma linha JSON por evento no stdout**. O Docker guarda esses logs localmente, e uma ferramenta de observabilidade (prevista: **Grafana Cloud**) só precisa coletá-los, sem mudar o código.

## Fluxo de uma requisição

```
Cloudflare → Nginx do host → Caddy (crm-proxy) → API (crm-api) / web (crm-web)
```

- **`X-Request-ID`:** em produção, o Nginx define o id (Entrega 3.4). Sem ele (ambiente local), o Caddy gera um UUID. A API aceita o id recebido quando ele tem até 64 caracteres `[A-Za-z0-9-]`; caso contrário, gera outro. O id volta na resposta (`X-Request-ID`) e aparece no log do Caddy (campo `request_id`) e no da API. Para investigar um erro relatado, basta pedir o id ao usuário ou pegá-lo no DevTools.
- **IP do cliente:** o Nginx restaura o IP real a partir do `CF-Connecting-IP`, aceitando só as faixas da Cloudflare (Entrega 3.4). O Caddy repassa esse IP à API.

## Campos da API (`service: crm-api`)

| Campo | Exemplo | Observação |
|---|---|---|
| `timestamp` | `2026-10-07T13:00:00.123Z` | UTC, ISO 8601, milissegundos |
| `level` | `info` | `debug`, `info`, `warning`, `error`, `critical` |
| `service` | `crm-api` | |
| `env` | `production` | `APP_ENV` |
| `version` | `sha-85b8aab…` | `APP_VERSION`, a tag da imagem em execução |
| `logger` | `crm_api.http` | módulo de origem |
| `event` | `http.request` | nome estável, ver catálogo; logs de bibliotecas aparecem como `log` |
| `message` | `Requisição concluída` | texto para leitura humana |
| `request_id` | `9f1c…` | presente em tudo o que acontece dentro de uma requisição |
| `client.ip` | `200.1.2.3` | IP real do cliente (dado pessoal, ver retenção) |
| `user_id` | `42` | id interno pseudônimo; nunca o e-mail |
| `http.method`, `http.route`, `http.status_code`, `duration_ms` | `GET`, `/api/v1/applications/{application_id}`, `200`, `12.4` | rota como **template**, sem valores nem query |
| `error.type`, `error.stack` | `builtins.RuntimeError` | só os frames; a mensagem da exceção fica de fora, porque pode conter dados |

Os nomes seguem as convenções semânticas do OpenTelemetry quando há equivalente.

## Catálogo de eventos

| Evento | Nível | Campos extras |
|---|---|---|
| `app.startup`, `app.shutdown` | info | — |
| `http.request` | info; warning para 403; error para 5xx | método, rota, status, duração, `user_id` |
| `http.unhandled_error` | error | `error.*`; o cliente recebe 500 com o `request_id` |
| `security.origin_rejected` | warning | — (requisição com cookie vinda de outra origem) |
| `auth.login.succeeded` | info | `user_id` |
| `auth.login.failed` | warning | `reason` (nunca o e-mail tentado) |
| `auth.logout` | info | — |
| `import.preview` | info | `total`, `valid`, `invalid`, `duplicates` |
| `import.preview.rejected` | info | — (arquivo inválido; nome e conteúdo ficam fora) |
| `import.completed` | info | `created`, `skipped` |
| `export.completed` | info | `format`, `count` |
| `admin.*` | info | espelho do log de auditoria da área admin (Entrega 3.6) |

Healthchecks (`/health`, `/ready`) só geram `http.request` quando falham. Os bem-sucedidos rodam a cada 15 s e seriam só ruído.

Para criar um evento novo: `log_event(logger, logging.INFO, "dominio.acao", "Mensagem", campo=valor)` (`crm_api/logging_config.py`), registrar o evento nesta tabela e testar que nenhum dado pessoal aparece.

## Regras de LGPD

- **Nunca registrar:** e-mail, senha, nome, cookie, token, cabeçalhos `Authorization`/`Cookie`, query string, `Referer`, corpo de requisição ou de resposta, conteúdo de candidatura ou de planilha, nome de arquivo enviado.
- **O Caddy** troca a query da URI por `?[removido]` e apaga o `Referer` do log. `Cookie` e `Authorization` já são ocultados por padrão.
- **Clientes HTTP** (`httpx`, `urllib3`) ficam em `warning`, porque em `info` registram URLs completas.
- **Testes** em `crm-candidaturas-backend/tests/test_logging.py` garantem que login com falha, busca e erros não vazam dados.
- **Retenção:**
  - IP e demais campos: **14 dias** na ferramenta de observabilidade (a retenção do Grafana Cloud).
  - Na VPS, os logs são um buffer limitado por tamanho (`json-file`, 5 MB × 2 por serviço): cerca de 15 dias no tráfego de outubro de 2026, menos com mais tráfego. Eles somem quando o container é recriado (todo deploy).

## Consultas úteis na VPS

```sh
cd /opt/crm-candidaturas
set -a; . .deploy/current.env; set +a
dc() { docker compose -f compose.prod.yaml --env-file .env "$@"; }

# Erros da API na última hora
dc logs --no-log-prefix --since 1h api | jq -c 'select(.level == "error")'

# Tudo de uma requisição (API + Caddy) pelo id
ID=coloque-o-id-aqui
dc logs --no-log-prefix api proxy | grep "$ID" | jq -c .

# Logins recusados por IP nas últimas 24 h
dc logs --no-log-prefix --since 24h api \
  | jq -r 'select(.event == "auth.login.failed") | ."client.ip"' | sort | uniq -c | sort -rn

# Rotas mais lentas
dc logs --no-log-prefix --since 24h api \
  | jq -r 'select(.event == "http.request") | "\(.duration_ms)\t\(."http.route")"' | sort -rn | head
```

Na máquina local (`crm-candidaturas-infra`), use `docker compose logs --no-log-prefix api`. O compose local usa `LOG_FORMAT=json`; para rodar a API fora do Docker, `LOG_FORMAT=text` deixa a saída legível.

## Próxima etapa: plugar o Grafana Cloud

Planejada no `TASKS.md` ("Observabilidade — próxima etapa"). Em resumo:
1. **Coleta:** um container do **Grafana Alloy** no `compose.prod.yaml`, com limite de memória, lendo os logs dos containers do projeto `crm-candidaturas` pelo socket do Docker (`loki.source.docker`). O estágio `loki.process` faz o parse do JSON e promove a labels **somente** `service`, `env` e `level`. Labels de alta cardinalidade (`request_id`, `user_id`, IP) continuam como campos do log.
2. **Credenciais:** token do Grafana Cloud no `/opt/crm-candidaturas/.env`, nunca no Git.
3. **Servidor:** métricas de host e de containers pelo próprio Alloy (CPU, memória, disco, swap, reinícios).
4. **Alertas:** taxa de 5xx, disco acima de 85%, container reiniciando, backup diário que falhou, uptime de `/api/health`.
5. **LGPD:** registrar a Grafana Labs como operador no inventário de dados (Entrega 4).
