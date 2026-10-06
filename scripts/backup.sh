#!/usr/bin/env bash
# Backup do PostgreSQL de produção em ./backups (formato custom do pg_dump).
#
# Uso: scripts/backup.sh [rótulo]
# Cron sugerido (diário, 03:00): 0 3 * * * /opt/crm-candidaturas/scripts/backup.sh daily >> /opt/crm-candidaturas/backups/backup.log 2>&1
set -Eeuo pipefail

cd "$(dirname "$0")/.."

label="${1:-manual}"
[[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "rótulo inválido" >&2; exit 1; }

set -a
# shellcheck disable=SC1091
source .env
set +a

# Tags só são necessárias para o compose validar o arquivo; o backup usa apenas o postgres.
if [[ -f .deploy/current.env ]]; then
  # shellcheck disable=SC1091
  source .deploy/current.env
fi
export BACKEND_TAG="${BACKEND_TAG:-none}" FRONTEND_TAG="${FRONTEND_TAG:-none}"

mkdir -p backups
chmod 700 backups
file="backups/crm-$(date -u +%Y%m%dT%H%M%SZ)-$label.dump"

docker compose -f compose.prod.yaml --env-file .env exec -T postgres \
  pg_dump -U "${POSTGRES_USER:-crm}" -d "${POSTGRES_DB:-crm}" --format=custom --no-owner \
  > "$file"
chmod 600 "$file"

[[ -s "$file" ]] || { echo "backup vazio: $file" >&2; rm -f "$file"; exit 1; }

find backups -name 'crm-*.dump' -type f -mtime +"${BACKUP_RETENTION_DAYS:-14}" -delete
echo "backup criado: $file ($(du -h "$file" | cut -f1))"
