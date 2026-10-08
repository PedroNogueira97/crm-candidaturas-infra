#!/usr/bin/env bash
# Backup do PostgreSQL de produção em ./backups (formato custom do pg_dump).
#
# Uso: scripts/backup.sh [rótulo]
# Cron sugerido (diário, 03:00): 0 3 * * * /opt/crm-candidaturas/scripts/backup.sh daily >> /opt/crm-candidaturas/backups/backup.log 2>&1
set -Eeuo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/dotenv.sh
source scripts/lib/dotenv.sh

label="${1:-manual}"
[[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "rótulo inválido" >&2; exit 1; }

# O .env nunca é executado (ver scripts/lib/dotenv.sh); só a retenção é lida dele.
retention_days=$(dotenv_get BACKUP_RETENTION_DAYS 14)
[[ "$retention_days" =~ ^[0-9]+$ ]] || { echo "BACKUP_RETENTION_DAYS inválido no .env" >&2; exit 1; }

# Tags só são necessárias para o compose validar o arquivo; o backup usa apenas o postgres.
if [[ -f .deploy/current.env ]]; then
  BACKEND_TAG=$(dotenv_get BACKEND_TAG "" .deploy/current.env)
  FRONTEND_TAG=$(dotenv_get FRONTEND_TAG "" .deploy/current.env)
fi
export BACKEND_TAG="${BACKEND_TAG:-none}" FRONTEND_TAG="${FRONTEND_TAG:-none}"

mkdir -p backups
chmod 700 backups
file="backups/crm-$(date -u +%Y%m%dT%H%M%SZ)-$label.dump"

# Usuário e banco vêm do ambiente do próprio container do postgres.
# shellcheck disable=SC2016
docker compose -f compose.prod.yaml --env-file .env exec -T postgres \
  sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom --no-owner' \
  > "$file"
chmod 600 "$file"

[[ -s "$file" ]] || { echo "backup vazio: $file" >&2; rm -f "$file"; exit 1; }

find backups -name 'crm-*.dump' -type f -mtime +"$retention_days" -delete
echo "backup criado: $file ($(du -h "$file" | cut -f1))"
