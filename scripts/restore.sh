#!/usr/bin/env bash
# Restaura um backup no PostgreSQL de produção. DESTRUTIVO: substitui os dados atuais.
#
# Uso: scripts/restore.sh backups/crm-AAAAMMDDTHHMMSSZ-rotulo.dump --yes
set -Eeuo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib/dotenv.sh
source scripts/lib/dotenv.sh

file="${1:-}"
[[ -f "$file" ]] || { echo "uso: $0 <arquivo.dump> --yes" >&2; exit 1; }
[[ "${2:-}" == "--yes" ]] || { echo "confirme com --yes (os dados atuais serão substituídos)" >&2; exit 1; }

# O .env nunca é executado (ver scripts/lib/dotenv.sh).
BACKEND_TAG=$(dotenv_get BACKEND_TAG "" .deploy/current.env)
FRONTEND_TAG=$(dotenv_get FRONTEND_TAG "" .deploy/current.env)
[[ -n "$BACKEND_TAG" && -n "$FRONTEND_TAG" ]] || { echo "tags ausentes em .deploy/current.env" >&2; exit 1; }
export BACKEND_TAG FRONTEND_TAG
COMPOSE=(docker compose -f compose.prod.yaml --env-file .env)

echo "backup de segurança do estado atual antes de restaurar"
scripts/backup.sh pre-restore

echo "parando API para restaurar"
"${COMPOSE[@]}" stop api

# Usuário e banco vêm do ambiente do próprio container do postgres.
# shellcheck disable=SC2016
"${COMPOSE[@]}" exec -T postgres \
  sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner' \
  < "$file"

"${COMPOSE[@]}" up -d --wait api
echo "restauração concluída a partir de $file"
