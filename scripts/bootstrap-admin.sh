#!/usr/bin/env bash
# Cria a conta do administrador a partir de INITIAL_USER_EMAIL e INITIAL_USER_PASSWORD do .env.
# Executar uma única vez após o primeiro deploy; depois, remover a senha do .env.
set -Eeuo pipefail

cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source .deploy/current.env
export BACKEND_TAG FRONTEND_TAG

docker compose -f compose.prod.yaml --env-file .env run --rm --no-deps api \
  python scripts/bootstrap_user.py
