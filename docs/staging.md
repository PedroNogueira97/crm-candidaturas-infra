# Staging — `staging-crm.lnmengenharia.com`

Ambiente de validação antes da produção, na mesma VPS. Decisões de 2026-10-08 (`TASKS.md`, seção "Staging — plano"): Cloudflare Access (S1a), Mailpit protegido pelo Access (S2a), Google desligado (S3a) e reaproveitamento dos segredos de deploy do environment `production` (S5a).

## Desenho

```text
Cloudflare (Access) ──► Nginx do host (443, certbot) ──┬─► /mailpit/ ──► Mailpit (127.0.0.1:8026)
                                                       └─► /*        ──► Caddy (127.0.0.1:8082) ──► api / web / postgres
```

- Diretório `/opt/crm-candidaturas-staging`, dono `deploy`, com `.env`, banco, volume e backups próprios.
- O mesmo `compose.prod.yaml` e os mesmos scripts da produção. O `.env` (modelo: `.env.staging.example`) muda o nome do projeto Docker (`crm-candidaturas-staging`), as portas, os limites de memória e liga o Mailpit (`COMPOSE_PROFILES=mailpit`).
- Stripe em modo de **teste** (`sk_test_...`) com `BILLING_ENABLED=true`; cadastro aberto (`SIGNUP_ENABLED=true`); Google desligado.
- Memória (VPS de 3,8 GB compartilhada): API 256 MB, web 192 MB, Postgres 256 MB, Caddy 64 MB, Mailpit 64 MB.

## Branches e deploy

| Branch | Publica a imagem | Deploy |
|---|---|---|
| `staging` (backend e frontend) | `sha-<commit>` e `:staging` | **Deploy staging** (`deploy-staging.yml`) em `/opt/crm-candidaturas-staging` |
| `main` | `sha-<commit>` e `:main` | **Deploy produção** (`deploy.yml`), como antes |

Fluxo:

1. `feature/*` → PR para `staging` (squash). O merge publica no staging.
2. Validado no staging → PR `staging` → `main` com **merge commit** (não squash), para os dois branches não divergirem.
3. Depois de cada release, conferir `git diff origin/staging origin/main` vazio. Hotfix direto na `main` precisa voltar para `staging` (`git merge origin/main`).

Os arquivos deste repositório (compose, Caddyfile, scripts) vão para o staging a partir da `main` do infra, como na produção.

## Preparação única do servidor

Como seu usuário administrativo (com `sudo`):

```sh
sudo install -d -o deploy -g deploy -m 750 /opt/crm-candidaturas-staging
```

### `.env`

Como `deploy`, a partir de `.env.staging.example` (copiado para `/opt/crm-candidaturas-staging/.env`, `chmod 600`). Gere os segredos direto no arquivo, sem exibi-los:

```sh
cd /opt/crm-candidaturas-staging
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 24)/" .env
sed -i "s/^SECRET_KEY=.*/SECRET_KEY=$(openssl rand -hex 32)/" .env
```

Preencher à mão: `ADMIN_EMAIL`, `STRIPE_SECRET_KEY` (teste) e `STRIPE_WEBHOOK_SECRET` (próxima seção).

### Webhook do Stripe (modo de teste)

No painel do Stripe, **em modo de teste**: Developers → Webhooks → Add endpoint:

- URL: `https://staging-crm.lnmengenharia.com/api/v1/billing/webhook`
- Eventos: `checkout.session.completed`, `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`, `customer.subscription.trial_will_end`, `invoice.paid`, `invoice.payment_failed`.
- Copiar o *Signing secret* (`whsec_...`) para `STRIPE_WEBHOOK_SECRET` no `.env` do staging.

O Portal do cliente é configurado pela própria API, na primeira abertura ou pelo botão "Sincronizar com o Stripe" do admin.

### Nginx e certificado

```sh
sudo cp nginx/staging-crm.conf /etc/nginx/sites-available/staging-crm.conf   # conteúdo deste repositório
sudo ln -s /etc/nginx/sites-available/staging-crm.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d staging-crm.lnmengenharia.com --redirect
```

Se `nginx -t` falhar, **não recarregue**: remova o symlink. O certificado precisa do desafio HTTP passando pela Cloudflare: emita antes de ligar o Access, ou mantenha o bypass do caminho `/.well-known/acme-challenge/` (necessário também para a renovação automática).

### Cloudflare Access

Zero Trust → Access → Applications → **Add an application → Self-hosted**:

1. **Staging CRM**: domínio `staging-crm.lnmengenharia.com`, sem caminho. Policy *Allow*, Include → *Emails* com os e-mails autorizados. Sessão de 24 h.
2. **Staging CRM — webhook Stripe**: domínio `staging-crm.lnmengenharia.com`, caminho `api/v1/billing/webhook`. Policy *Bypass*, Include → *Everyone*. O endpoint confere a assinatura do Stripe sozinho.
3. **Staging CRM — certbot**: domínio `staging-crm.lnmengenharia.com`, caminho `.well-known/acme-challenge`. Policy *Bypass*, Include → *Everyone*.

O Access aplica a aplicação de caminho mais específico. Conferir:

- `curl -sI https://staging-crm.lnmengenharia.com/` → `302` para `*.cloudflareaccess.com`;
- `curl -s -o /dev/null -w '%{http_code}' -X POST https://staging-crm.lnmengenharia.com/api/v1/billing/webhook` → `400` (chegou à API, assinatura inválida).

## Primeiro deploy

O `deploy.sh` precisa das duas tags na primeira vez. Depois que o backend e o frontend publicarem as imagens a partir do branch `staging`: **Actions → Deploy staging → Run workflow**, com as duas tags `sha-<commit>`. Os deploys seguintes são disparados sozinhos.

Não há bootstrap de conta: crie a sua pelo cadastro (o e-mail de confirmação chega no Mailpit, em `/mailpit/`). Com `ADMIN_EMAIL` igual a ela, ela vira admin na próxima subida da API (`scripts/deploy.sh` sem argumentos reaplica).

## Operação

```sh
cd /opt/crm-candidaturas-staging
docker compose -f compose.prod.yaml ps                       # o .env já escolhe o projeto do staging
docker compose -f compose.prod.yaml logs -f --tail=100 api
docker stats --no-stream                                     # memória de todos os projetos
scripts/deploy.sh                                            # reaplicar as tags atuais
```

Zerar o banco do staging: `docker compose -f compose.prod.yaml down -v` e reaplicar o deploy. **Nunca** rode isso em `/opt/crm-candidaturas`.
