# Infra — CRM de Candidaturas

Execução local com Docker, produção na VPS Hostinger e deploy via GitHub Actions para o CRM "Desempregado sim, Desorganizado não".

Os repositórios da aplicação continuam independentes:

- `crm-candidaturas-backend` — API FastAPI (imagem `ghcr.io/pedronogueira97/crm-candidaturas-backend`)
- `crm-candidaturas-frontend` — TanStack Start (imagem `ghcr.io/pedronogueira97/crm-candidaturas-frontend`)

## Arquitetura

```text
Internet ──► Nginx do host (80/443, HTTPS via certbot) ──► Caddy (127.0.0.1:8081)
               ├── /api/*      ──► api  (FastAPI :8000) ──► postgres (:5432, rede interna)
               ├── /api/health ──► api /ready (inclui banco)
               └── /*          ──► web  (Node :3000)
```

Frontend e API ficam na mesma origem, então não há CORS entre domínios e o cookie de sessão funciona com `SameSite`. O frontend é compilado com `VITE_API_BASE_URL=/api/v1`, e a mesma imagem serve qualquer domínio.

| Arquivo | Uso |
|---|---|
| `compose.yaml` | Ambiente local: constrói as imagens a partir dos clones vizinhos |
| `compose.prod.yaml` | Produção: imagens do GHCR com tags imutáveis (`sha-<commit>`) |
| `Caddyfile` | Roteamento interno e cabeçalhos de segurança |
| `nginx/crm-candidatura.conf` | Site no Nginx do host (VPS compartilhada) |
| `scripts/deploy.sh` | Pull → backup → migration → subida com health check → rollback automático |
| `scripts/backup.sh` / `scripts/restore.sh` | Backup e restauração do PostgreSQL |
| `scripts/bootstrap-admin.sh` | Cria a conta do administrador (uma vez) |
| `.github/workflows/deploy.yml` | Deploy na VPS via SSH |
| `docs/vps-hostinger.md` | Preparação da VPS e configuração do GitHub |

## Ambiente local

Requisitos: Docker com Compose v2. Clone os três repositórios lado a lado:

```text
crm-candidaturas-backend/
crm-candidaturas-frontend/
crm-candidaturas-infra/
```

```sh
cd crm-candidaturas-infra
cp .env.example .env          # troque senhas e chaves (openssl rand -hex 32)
docker compose up -d --build  # postgres, migration, api, web e proxy
docker compose run --rm api python scripts/bootstrap_user.py   # cria a conta do .env
```

Acesse `http://localhost:8080` (porta configurável em `HTTP_PORT`). Comandos úteis:

```sh
docker compose logs -f api web          # logs
docker compose up -d --build api web    # reconstruir após mudar o código
docker compose down                     # parar (mantém o banco)
docker compose down -v                  # parar e APAGAR o banco local
```

O banco local não é exposto no host. Para acessá-lo: `docker compose exec postgres psql -U crm crm`.

## Fluxo de deploy

1. Push em `main` no backend ou frontend → CI (lint, testes, `pip-audit`/`npm audit`, scan Trivy da imagem).
2. Com a CI verde, a imagem é publicada no GHCR como `sha-<commit>` e `main`.
3. O repositório da aplicação dispara `repository_dispatch` (`deploy`) neste repositório com `{service, tag}`.
4. `deploy.yml` envia compose, Caddyfile e scripts para a VPS e executa `scripts/deploy.sh --<service> <tag>`.
5. `deploy.sh` faz backup do banco, aplica as migrations e sobe os serviços aguardando os health checks. Se algum falhar, volta para as tags anteriores.

Deploy manual, rollback ou reaplicação de configuração: **Actions → Deploy produção → Run workflow**, informando as tags desejadas (vazio = manter a atual). As tags em execução ficam em `/opt/crm-candidaturas/.deploy/current.env` e o histórico em `.deploy/history.log`.

> Rollback reverte as imagens, mas **não reverte migrations**. Migrations devem ser compatíveis com a versão anterior da aplicação; se não for possível, restaure o backup pré-deploy criado automaticamente em `backups/`.

## Backups

- `deploy.sh` cria um backup antes de cada migration (`backups/crm-<data>-pre-deploy-<tag>.dump`).
- Backup diário via cron (ver `docs/vps-hostinger.md`), com retenção de `BACKUP_RETENTION_DAYS` dias (padrão 14).
- Restaurar: `scripts/restore.sh backups/<arquivo>.dump --yes` (faz um backup do estado atual antes).
- Os backups ficam na própria VPS. Copie-os periodicamente para fora do servidor (pendente de definir destino).

## Primeiro deploy

Siga `docs/vps-hostinger.md`. Resumo:

1. Preparar a VPS (usuário `deploy`, swap, Nginx do host) e criar `/opt/crm-candidaturas/.env` a partir de `.env.production.example`.
2. Configurar secrets no GitHub (este repo e os repos da aplicação).
3. Apontar o DNS `crm-candidatura.lnmengenharia.com` para o IP da VPS e emitir o certificado com certbot.
4. Rodar a CI do backend e do frontend (push em `main`) ou o deploy manual com as duas tags.
5. Na VPS: `scripts/bootstrap-admin.sh` e remover `INITIAL_USER_PASSWORD` do `.env`.
