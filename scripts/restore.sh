#!/usr/bin/env bash
# Restaura um backup no PostgreSQL de produção. DESTRUTIVO: substitui os dados atuais.
#
# Uso: scripts/restore.sh backups/crm-AAAAMMDDTHHMMSSZ-rotulo.dump --yes
set -Eeuo pipefail

cd "$(dirname "$0")/.."

file="${1:-}"
[[ -f "$file" ]] || { echo "uso: $0 <arquivo.dump> --yes" >&2; exit 1; }
[[ "${2:-}" == "--yes" ]] || { echo "confirme com --yes (os dados atuais serão substituídos)" >&2; exit 1; }

set -a
# shellcheck disable=SC1091
source .env
set +a
# shellcheck disable=SC1091
source .deploy/current.env
export BACKEND_TAG FRONTEND_TAG
COMPOSE=(docker compose -f compose.prod.yaml --env-file .env)

echo "backup de segurança do estado atual antes de restaurar"
scripts/backup.sh pre-restore

echo "parando API para restaurar"
"${COMPOSE[@]}" stop api

"${COMPOSE[@]}" exec -T postgres \
  pg_restore -U "${POSTGRES_USER:-crm}" -d "${POSTGRES_DB:-crm}" --clean --if-exists --no-owner \
  < "$file"

"${COMPOSE[@]}" up -d --wait api
echo "restauração concluída a partir de $file"
