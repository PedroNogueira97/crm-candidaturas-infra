#!/usr/bin/env bash
# Deploy de produção na VPS. Executado pelo GitHub Actions via SSH ou manualmente.
#
# Uso: scripts/deploy.sh [--backend TAG] [--frontend TAG]
#   Sem argumentos, reaplica as tags atuais (útil após mudar Caddyfile/compose).
#   A tag omitida mantém a versão em execução daquele serviço.
#
# Passos: pull -> backup -> migration -> up --wait -> rollback automático se falhar.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

STATE_DIR=.deploy
STATE_FILE="$STATE_DIR/current.env"
COMPOSE=(docker compose -f compose.prod.yaml --env-file .env)
TAG_PATTERN='^[A-Za-z0-9._-]{1,128}$'

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { log "ERRO: $*"; exit 1; }

[[ -f .env ]] || die "arquivo .env não encontrado em $(pwd)"

new_backend=""
new_frontend=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend) new_backend="${2:-}"; shift 2 ;;
    --frontend) new_frontend="${2:-}"; shift 2 ;;
    *) die "argumento desconhecido: $1" ;;
  esac
done

mkdir -p "$STATE_DIR"
BACKEND_TAG=""
FRONTEND_TAG=""
# shellcheck disable=SC1090
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE"
prev_backend="$BACKEND_TAG"
prev_frontend="$FRONTEND_TAG"

BACKEND_TAG="${new_backend:-$prev_backend}"
FRONTEND_TAG="${new_frontend:-$prev_frontend}"

[[ -n "$BACKEND_TAG" ]] || die "nenhuma tag do backend em execução; informe --backend TAG"
[[ -n "$FRONTEND_TAG" ]] || die "nenhuma tag do frontend em execução; informe --frontend TAG"
[[ "$BACKEND_TAG" =~ $TAG_PATTERN ]] || die "tag do backend inválida"
[[ "$FRONTEND_TAG" =~ $TAG_PATTERN ]] || die "tag do frontend inválida"
export BACKEND_TAG FRONTEND_TAG
# Recria o proxy quando o Caddyfile muda (ver label crm.caddyfile-sha256 no compose.prod.yaml).
CADDYFILE_SHA256="$(sha256sum Caddyfile | cut -d" " -f1)"
export CADDYFILE_SHA256

log "backend: ${prev_backend:-<nenhum>} -> $BACKEND_TAG"
log "frontend: ${prev_frontend:-<nenhum>} -> $FRONTEND_TAG"

# DEPLOY_SKIP_PULL=1 usa imagens já presentes no host (testes locais do script).
if [[ "${DEPLOY_SKIP_PULL:-0}" != "1" ]]; then
  log "baixando imagens"
  "${COMPOSE[@]}" --profile migrate pull --quiet migrate api web proxy postgres
fi

log "garantindo PostgreSQL"
"${COMPOSE[@]}" up -d --wait postgres

if [[ -n "$prev_backend" ]]; then
  log "backup antes da migration"
  scripts/backup.sh "pre-deploy-$BACKEND_TAG"
fi

log "aplicando migrations"
"${COMPOSE[@]}" --profile migrate run --rm migrate

rollback() {
  if [[ -z "$prev_backend" || -z "$prev_frontend" ]]; then
    die "primeiro deploy falhou; não há versão anterior para rollback"
  fi
  log "falha na subida; rollback para backend=$prev_backend frontend=$prev_frontend"
  log "atenção: migrations não são revertidas; o backup pré-deploy está em ./backups"
  BACKEND_TAG="$prev_backend" FRONTEND_TAG="$prev_frontend" \
    "${COMPOSE[@]}" up -d --wait --wait-timeout 180 --remove-orphans \
    || log "rollback também falhou; intervenção manual necessária"
  exit 1
}

log "subindo serviços"
if ! "${COMPOSE[@]}" up -d --wait --wait-timeout 180 --remove-orphans; then
  rollback
fi

printf 'BACKEND_TAG=%s\nFRONTEND_TAG=%s\n' "$BACKEND_TAG" "$FRONTEND_TAG" > "$STATE_FILE"
printf '%s backend=%s frontend=%s\n' "$(date -u +%FT%TZ)" "$BACKEND_TAG" "$FRONTEND_TAG" >> "$STATE_DIR/history.log"

# Servidor compartilhado: remove apenas imagens antigas e sem uso DESTE projeto.
for repo in crm-candidaturas-backend crm-candidaturas-frontend; do
  docker image prune -a -f --filter "until=168h" \
    --filter "label=org.opencontainers.image.source=https://github.com/PedroNogueira97/$repo" \
    >/dev/null || true
done
log "deploy concluído"
