#!/usr/bin/env bash
# Testes de scripts/lib/dotenv.sh. Uso: scripts/tests/dotenv_test.sh
set -Euo pipefail

cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=scripts/lib/dotenv.sh
source scripts/lib/dotenv.sh

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
env_file="$tmp/.env"
marker="$tmp/executado"

# Valores que quebrariam (ou executariam código) com `source`.
cat > "$env_file" <<ENV
# comentário
POSTGRES_DB=crm
SMTP_PASSWORD=abcd efgh ijkl mnop
INJECAO=\$(touch $marker)
CRASES=\`touch $marker\`
DUPLAS="valor com # cerquilha"
SIMPLES='com \$dolar'
COMENTARIO=14 # dias
export EXPORTADA=sim
CRLF=windows$(printf '\r')
REPETIDA=primeira
REPETIDA=segunda
VAZIA=
  ESPACO_INICIAL = 7
ENV

fails=0
check() {
  local name=$1 expected=$2 got
  got=$(dotenv_get "$name" "${3-}" "$env_file")
  if [[ "$got" == "$expected" ]]; then
    echo "ok   $name"
  else
    echo "FALHA $name: esperado [$expected], obtido [$got]"
    fails=$((fails + 1))
  fi
}

check POSTGRES_DB crm
check SMTP_PASSWORD "abcd efgh ijkl mnop"
check INJECAO "\$(touch $marker)"
check CRASES "\`touch $marker\`"
check DUPLAS "valor com # cerquilha"
check SIMPLES "com \$dolar"
check COMENTARIO 14
check EXPORTADA sim
check CRLF windows
check REPETIDA segunda
check VAZIA padrao padrao
check AUSENTE padrao padrao
check ESPACO_INICIAL 7

if [[ -e "$marker" ]]; then
  echo "FALHA: o .env foi executado"
  fails=$((fails + 1))
fi

if dotenv_get 'X;rm' "" "$env_file" 2>/dev/null; then
  echo "FALHA: chave inválida aceita"; fails=$((fails + 1))
else
  echo "ok   chave inválida recusada"
fi

if (( fails > 0 )); then
  echo "$fails falha(s)"
  exit 1
fi
echo "todos os testes passaram"
