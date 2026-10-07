#!/usr/bin/env bash
# Gera o snippet do Nginx que restaura o IP real dos clientes vindos da Cloudflare.
#
# Uso: scripts/update-cloudflare-ips.sh [arquivo-de-saída]
#   Padrão: nginx/cloudflare-real-ip.conf (versionado). Instalação na VPS: docs/vps-hostinger.md.
#
# Só os endereços da Cloudflare podem definir o IP do cliente via CF-Connecting-IP; quem acessa
# a VPS direto continua com o próprio IP e um cabeçalho forjado é ignorado.
set -Eeuo pipefail

out="${1:-$(dirname "$0")/../nginx/cloudflare-real-ip.conf}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

fetch() {
  curl -fsS --max-time 20 "https://www.cloudflare.com/$1"
}

v4="$(fetch ips-v4)"
v6="$(fetch ips-v6)"

{
  echo "# Gerado por scripts/update-cloudflare-ips.sh em $(date -u +%Y-%m-%d)."
  echo "# Fonte: https://www.cloudflare.com/ips-v4 e /ips-v6. Não editar à mão."
  count=0
  for cidr in $v4 $v6; do
    if [[ ! "$cidr" =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]]; then
      echo "Faixa inesperada na resposta da Cloudflare: $cidr" >&2
      exit 1
    fi
    echo "set_real_ip_from $cidr;"
    count=$((count + 1))
  done
  if ((count < 10)); then
    echo "Poucas faixas recebidas ($count); abortando." >&2
    exit 1
  fi
  echo "real_ip_header CF-Connecting-IP;"
} >"$tmp"

install -m 644 "$tmp" "$out"
echo "Gravado: $out ($(grep -c '^set_real_ip_from' "$out") faixas)"
