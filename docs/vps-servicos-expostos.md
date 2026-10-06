# Correção — vaultwarden e n8n expostos na internet

Encontrado em 2026-10-06: o vaultwarden (`0.0.0.0:8080`) e o n8n (`0.0.0.0:5678`) respondiam HTTP 200 a partir da internet. **Portas publicadas pelo Docker ignoram o UFW**, então a regra `8080 DENY` não tinha efeito.

Objetivo: publicar os dois somente em `127.0.0.1` e acessá-los apenas pelo Nginx com HTTPS.

Fazer **antes** de `vps-hostinger.md`. Todos os comandos rodam na VPS com o seu usuário administrativo.

> **Status: aplicado em 2026-10-06.** Vaultwarden e n8n publicados só em `127.0.0.1`; portas 8080 e 5678 sem resposta externa; n8n com `N8N_ENCRYPTION_KEY` no `.env` e volume `n8n_data`; regra `DENY 8080` removida do UFW. Backups em `/root/backups-2026-10-06/`. Pendente com o responsável: passo 6 (higiene pós-exposição).

---

## Passo 0 — Diagnóstico (só leitura)

```sh
# Pasta do compose de cada serviço (vazio = criado com "docker run")
docker inspect vaultwarden --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}'
docker inspect n8n-n8n-1  --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}'

# Onde ficam os dados do vaultwarden (precisa existir um mount em /data)
docker inspect vaultwarden --format '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}}{{println}}{{end}}'

# O Nginx já tem domínios apontando para eles? (-R segue os symlinks de sites-enabled)
sudo grep -RnE "proxy_pass .*:(8080|5678)" /etc/nginx/sites-enabled/

# O vaultwarden usa banco externo? (mostra só tipo, host e nome do banco)
sudo grep '^DATABASE_URL=' /PASTA/DO/VAULTWARDEN/.env | sed -E 's#^DATABASE_URL=([a-z]+)://[^@]*@([^/]+)/(.*)$#\1 host=\2 db=\3#'

# O n8n guarda a chave de criptografia só dentro do container?
docker inspect n8n-n8n-1 --format '{{range .Mounts}}{{.Destination}}{{println}}{{end}}' | grep -q /home/node/.n8n && echo "n8n com volume" || echo "n8n SEM volume para /home/node/.n8n"
docker inspect n8n-n8n-1 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -q '^N8N_ENCRYPTION_KEY=' && echo "chave via env" || echo "chave NAO definida via env"

# Como o n8n gera as URLs de webhook (filtrado para não mostrar segredos)
docker inspect n8n-n8n-1 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E '^(WEBHOOK_URL|N8N_HOST|N8N_PROTOCOL|N8N_EDITOR_BASE_URL)='

# IP da VPN WireGuard, se houver
ip -4 addr show wg0 2>/dev/null | grep inet
```

Interpretação:

| Resultado | O que fazer |
|---|---|
| O `grep` do Nginx encontrou os dois | Caso simples: passos 1, 2, 3, 5 e 6 |
| O Nginx não encontrou | Hoje o acesso é por `http://IP:porta`. Faça também o **passo 4** antes de fechar as portas, ou você perde o acesso |
| O acesso é só pela VPN | Veja a alternativa no fim do passo 2 |
| 🔴 O vaultwarden **não tem** mount em `/data` | **Pare.** Recriar o container apagaria o cofre. Peça ajuda antes de continuar |
| O vaultwarden foi criado com `docker run` | Rode o comando do fim do passo 2 e converta para compose antes de mudar a porta |
| O vaultwarden usa `DATABASE_URL` apontando para o Postgres do n8n | Os dados do cofre ficam **nesse Postgres**: o backup principal é o `pg_dumpall` do passo 1, e o serviço `postgres` do n8n nunca deve ser recriado ou removido junto com o n8n |
| 🔴 O n8n está **sem volume** em `/home/node/.n8n` e sem `N8N_ENCRYPTION_KEY` | A chave que cifra as credenciais existe só dentro do container. Recriá-lo sem preservar a chave deixa **todas as credenciais ilegíveis**. Siga o passo 3 completo (chave no `.env` + volume) |

---

## Passo 1 — Backups (obrigatório)

```sh
# Vaultwarden: troque /CAMINHO/DO/DATA pelo "Source" do mount em /data
sudo tar -czf ~/vaultwarden-backup-$(date +%F).tar.gz -C /CAMINHO/DO/DATA .
ls -lh ~/vaultwarden-backup-*.tar.gz

# n8n: ajuste o usuário se não for "postgres"
docker exec n8n-postgres-1 pg_dumpall -U postgres > ~/n8n-backup-$(date +%F).sql
ls -lh ~/n8n-backup-*.sql
```

---

## Passo 2 — Vaultwarden só em loopback

Com compose:

```sh
cd /PASTA/DO/COMPOSE/DO/VAULTWARDEN
sudo cp docker-compose.yml docker-compose.yml.bak     # ou compose.yaml
sudo nano docker-compose.yml
```

Troque `- "8080:80"` por:

```yaml
    ports:
      - "127.0.0.1:8080:80"
```

```sh
docker compose up -d      # recria o container; os dados ficam no volume
```

Se foi criado com `docker run`, colete os parâmetros (sem expor os valores das variáveis) para montar um compose equivalente:

```sh
docker inspect vaultwarden --format 'image={{.Config.Image}} restart={{.HostConfig.RestartPolicy.Name}} ports={{json .HostConfig.PortBindings}} mounts={{range .Mounts}}{{.Source}}->{{.Destination}} {{end}} env_keys={{range .Config.Env}}{{printf "%.25s" .}} | {{end}}'
```

Alternativa só para quem acessa pela VPN: use o IP do `wg0` no lugar de `127.0.0.1` (ex.: `"10.8.0.1:8080:80"`). Desvantagem: se o `wg0` não estiver ativo quando o Docker iniciar, o container não sobe.

---

## Passo 3 — n8n só em loopback (preservando a chave de criptografia)

```sh
D=/root/backups-$(date +%F)
cd /PASTA/DO/COMPOSE/DO/N8N
sudo install -d -m 700 $D
sudo cp -a docker-compose.yml $D/n8n-docker-compose.yml.bak
sudo cp -a .env $D/n8n.env.bak
sudo docker cp n8n-n8n-1:/home/node/.n8n $D/n8n-home          # chave, storage e logs

# Chave para o .env (sem exibir), se ainda não existir
sudo grep -q '^N8N_ENCRYPTION_KEY=' .env || \
  printf '\nN8N_ENCRYPTION_KEY=%s\n' "$(sudo cat $D/n8n-home/config | python3 -c 'import sys,json; print(json.load(sys.stdin)["encryptionKey"])')" | sudo tee -a .env >/dev/null

# Volume persistente já preenchido com o conteúdo atual (uid/gid do usuário node = 1000)
sudo docker volume create --label com.docker.compose.project=n8n --label com.docker.compose.volume=n8n_data n8n_n8n_data
sudo docker run --rm -v n8n_n8n_data:/dst -v $D/n8n-home:/src:ro alpine:3 sh -c 'cp -a /src/. /dst/ && chown -R 1000:1000 /dst'

sudo nano docker-compose.yml
```

No serviço `n8n`:

```yaml
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      # ... variáveis existentes ...
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}

    volumes:
      - n8n_data:/home/node/.n8n
```

E no fim do arquivo, junto de `postgres_data:`:

```yaml
volumes:
  postgres_data:
  n8n_data:
```

Recriar **somente** o n8n (o Postgres, que pode conter o banco do vaultwarden, não é tocado):

```sh
sudo docker compose config -q && echo CONFIG_OK
sudo docker compose up -d --no-deps n8n
sleep 15
sudo docker logs --since 2m n8n-n8n-1 2>&1 | grep -iE "mismatch|encryption|error" | head   # não deve haver "Mismatching encryption keys"
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:5678/healthz                       # esperado: 200
```

⚠️ Se `WEBHOOK_URL` aponta para `http://IP:5678`, os webhooks externos param de funcionar. Ajuste para o domínio HTTPS do passo 4 (ex.: `WEBHOOK_URL=https://n8n.lnmengenharia.com/`), rode `docker compose up -d` e atualize as URLs nos serviços que chamam esses webhooks.

---

## Passo 4 — Site HTTPS no Nginx (só se ainda não existir)

No DNS, crie registros A para os subdomínios (ex.: `cofre.lnmengenharia.com` e `n8n.lnmengenharia.com`) apontando para o IP da VPS.

`/etc/nginx/sites-available/vaultwarden.conf`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name cofre.lnmengenharia.com;
    client_max_body_size 128m;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

`/etc/nginx/sites-available/n8n.conf`: mesmo conteúdo, com `server_name n8n.lnmengenharia.com;` e `proxy_pass http://127.0.0.1:5678;`.

```sh
sudo ln -s /etc/nginx/sites-available/vaultwarden.conf /etc/nginx/sites-enabled/
sudo ln -s /etc/nginx/sites-available/n8n.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx          # se nginx -t falhar, NÃO recarregue
sudo certbot --nginx -d cofre.lnmengenharia.com -d n8n.lnmengenharia.com --redirect
```

No compose do vaultwarden, defina `DOMAIN=https://cofre.lnmengenharia.com` e rode `docker compose up -d`. Nos apps e extensões do Bitwarden, troque a URL do servidor para o novo domínio.

---

## Passo 5 — Verificação

Do **seu computador** (fora da VPS):

```sh
curl -m 5 -s -o /dev/null -w "%{http_code}\n" http://IP_DA_VPS:8080          # esperado: 000
curl -m 5 -s -o /dev/null -w "%{http_code}\n" http://IP_DA_VPS:5678          # esperado: 000
curl -s -o /dev/null -w "%{http_code}\n" https://cofre.lnmengenharia.com     # esperado: 200
curl -s -o /dev/null -w "%{http_code}\n" https://n8n.lnmengenharia.com       # esperado: 200
```

Na VPS:

```sh
docker ps --format 'table {{.Names}}\t{{.Ports}}'      # deve mostrar 127.0.0.1:8080 e 127.0.0.1:5678
sudo ufw delete deny 8080/tcp                           # regra sem efeito sobre o Docker
```

---

## Passo 6 — Higiene pós-exposição

Vaultwarden:
- [ ] Cofre web → Configurações → Minha conta → **Desconectar todas as sessões**.
- [ ] Trocar a senha mestra se o acesso por `http://IP:8080` foi usado em redes públicas.
- [ ] Confirmar `SIGNUPS_ALLOWED=false`.
- [ ] Se `ADMIN_TOKEN` estiver definido, trocá-lo (o `/admin` também estava exposto).
- [ ] Revisar acessos: `docker logs vaultwarden 2>&1 | grep -iE "login|admin" | tail -50`, procurando IPs que você não reconhece.

n8n:
- [ ] Settings → Users: confirmar que não há usuários desconhecidos.
- [ ] Ativar 2FA e trocar a senha.
- [ ] Atualizar a imagem: `docker compose pull && docker compose up -d`.
- [ ] Revisar as credenciais salvas nos workflows; revogar e regerar tokens se houver suspeita.

---

## Desfazer (se algo der errado)

```sh
cd /PASTA/DO/COMPOSE
sudo cp $D/<servico>-docker-compose.yml.bak docker-compose.yml && sudo cp $D/<servico>.env.bak .env
sudo docker compose up -d --no-deps <servico>        # n8n: o volume n8n_data já contém a chave original
sudo rm /etc/nginx/sites-enabled/vaultwarden.conf /etc/nginx/sites-enabled/n8n.conf
sudo nginx -t && sudo systemctl reload nginx
```
