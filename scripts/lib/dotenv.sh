# shellcheck shell=bash
# Leitura segura do .env: nunca executa o arquivo (sem source/eval).
#
# Por quê: `source .env` interpreta os valores como shell. Uma senha com espaço
# ou `$` quebra o script e pode vazar um pedaço do segredo na mensagem de erro
# (aconteceu no deploy de 2026-10-08). O docker compose lê o .env com as próprias
# regras; aqui seguimos as mesmas para os casos usados:
#   CHAVE=valor          valor até o fim da linha, sem " #comentário" final
#   CHAVE="valor"        aspas removidas
#   CHAVE='valor'        aspas removidas
#   export CHAVE=valor   aceito
# A última ocorrência vence. Os valores nunca são impressos em caso de erro.

# dotenv_get CHAVE [padrão] [arquivo]
dotenv_get() {
  local key=$1 default=${2-} file=${3:-.env} line value found=0
  [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "dotenv_get: chave inválida" >&2; return 2; }
  [[ -r $file ]] || { echo "dotenv_get: $file não encontrado" >&2; return 2; }

  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=(.*)$ ]] || continue
    value=${BASH_REMATCH[2]}
    value=${value#"${value%%[![:space:]]*}"}
    if [[ $value =~ ^\"(.*)\"[[:space:]]*(#.*)?$ || $value =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then
      value=${BASH_REMATCH[1]}
    else
      value=${value%%[[:space:]]#*}
      value=${value%"${value##*[![:space:]]}"}
    fi
    found=1
  done < "$file"

  if (( found )) && [[ -n $value ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$default"
  fi
}
