# Runbook — VPS Hostinger (servidor compartilhado)

Preparação única do servidor de produção e das credenciais do GitHub.

A VPS já roda outros projetos (Nginx no host com 80/443, n8n, vaultwarden). Este stack **não** publica 80/443: o Caddy dele escuta só em `127.0.0.1:8081`, e o Nginx do host encaminha o domínio para lá e cuida do HTTPS (certbot).

Estado conferido em 2026-10-06: Ubuntu 24.04, Docker 29.5 / Compose v5.1, 1 vCPU, 3,8 GB de RAM sem swap. O SSH já aceita só chave, sem login de root. O UFW já está ativo com 22/80/443 liberadas. **Não reinstale o Docker, não rode `apt full-upgrade` sem janela de manutenção e não altere SSH/UFW para este projeto.**

Os comandos abaixo usam `sudo` a partir do seu usuário administrativo (o login direto como root está desativado).

## 1. Usuário de deploy

Usado apenas pelo GitHub Actions, com uma chave SSH exclusiva.

```sh
sudo adduser --disabled-password --gecos "" deploy
sudo usermod -aG docker deploy
sudo install -d -o deploy -g deploy -m 750 /opt/crm-candidaturas
sudo install -d -o deploy -g deploy -m 700 /home/deploy/.ssh
```

> O grupo `docker` dá acesso equivalente a root no servidor inteiro, incluindo os containers dos outros projetos. A chave privada do deploy deve existir somente nos secrets do GitHub.

No **seu computador** (WSL), gere a chave do deploy, sem senha:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/crm_deploy -C "github-actions-crm-deploy" -N ""
cat ~/.ssh/crm_deploy.pub
```

Na VPS, cole a chave **pública**:

```sh
echo "COLE_AQUI_A_CHAVE_PUBLICA" | sudo tee /home/deploy/.ssh/authorized_keys >/dev/null
sudo chown deploy:deploy /home/deploy/.ssh/authorized_keys
sudo chmod 600 /home/deploy/.ssh/authorized_keys
```

O `sshd_config` deste servidor restringe o login com `AllowUsers`. Inclua o `deploy` (com backup e validação antes de recarregar):

```sh
sudo cp -a /etc/ssh/sshd_config /root/sshd_config.bak
sudo sed -i 's/^AllowUsers pedro$/AllowUsers pedro deploy/' /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl reload ssh
```

Teste do seu computador: `ssh -i ~/.ssh/crm_deploy deploy@IP_DA_VPS 'docker ps --format "{{.Names}}"'`. Deve listar os containers.

## 2. Swap (recomendado)

Com 1 vCPU, 3,8 GB e nenhuma swap, um pico de memória pode fazer o kernel matar containers de qualquer projeto. Uma swap de 2 GB é segura e não reinicia nada:

```sh
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/90-swappiness.conf
sudo sysctl --system >/dev/null
free -h
```

## 3. Arquivo de ambiente

```sh
sudo -iu deploy
cd /opt/crm-candidaturas
openssl rand -hex 32   # rode duas vezes: POSTGRES_PASSWORD e SECRET_KEY
nano .env
chmod 600 .env
```

Conteúdo (modelo em `.env.production.example`):

```env
SITE_ADDRESS=crm-candidatura.lnmengenharia.com
PROXY_BIND=127.0.0.1:8081
POSTGRES_DB=crm
POSTGRES_USER=crm
POSTGRES_PASSWORD=<valor gerado 1>
SECRET_KEY=<valor gerado 2>
SESSION_MAX_AGE_SECONDS=43200
LOG_LEVEL=INFO
INITIAL_USER_EMAIL=<seu e-mail de admin>
INITIAL_USER_PASSWORD=<senha forte, mínimo 12 caracteres>
BACKUP_RETENTION_DAYS=14
```

A porta `8081` precisa estar livre (`ss -tlnp | grep 8081` sem resultado). Se não estiver, use outra e ajuste o Nginx no passo 5.

## 4. DNS

No provedor de `lnmengenharia.com`: registro **A** `crm-candidatura` → IP da VPS (e **AAAA** se a VPS tiver IPv6 e o Nginx escutar em IPv6, como hoje). Confira com `dig +short crm-candidatura.lnmengenharia.com`.

## 5. Nginx do host e certificado

O site pode ser criado antes do primeiro deploy. Até a aplicação subir, ele responde 502.

```sh
# copie o conteúdo de nginx/crm-candidatura.conf deste repositório:
sudo nano /etc/nginx/sites-available/crm-candidatura.conf
sudo ln -s /etc/nginx/sites-available/crm-candidatura.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

`nginx -t` valida antes de recarregar, e `reload` não derruba os outros sites. Se `nginx -t` falhar, **não recarregue**: remova o symlink e me envie o erro.

Certificado HTTPS (depois que o DNS resolver para a VPS):

```sh
certbot --version || sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d crm-candidatura.lnmengenharia.com --redirect
```

O certbot altera somente este site e já configura a renovação automática dos certificados.

## 6. Impressão digital do servidor

No seu computador:

```sh
ssh-keyscan -t ed25519 IP_DA_VPS
```

Guarde a linha, que vira o secret `VPS_KNOWN_HOSTS`. Confira que a chave é a mesma de `sudo cat /etc/ssh/ssh_host_ed25519_key.pub` na VPS.

## 7. GitHub

### Tokens

- **Token A, para a VPS baixar as imagens:** Settings → Developer settings → Personal access tokens (classic) → somente o escopo **`read:packages`**, com expiração.
- **Token B, para disparar o deploy:** Fine-grained token → repositório **`crm-candidaturas-infra`** apenas → **Contents: Read and write**, com expiração.

### Secrets do repositório `crm-candidaturas-infra`

Settings → Environments → **`production`** → Environment secrets:

| Secret | Valor |
|---|---|
| `VPS_HOST` | IP da VPS |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | Conteúdo de `~/.ssh/crm_deploy` (chave **privada**, com as linhas BEGIN/END) |
| `VPS_KNOWN_HOSTS` | Linha do `ssh-keyscan` |
| `GHCR_USER` | `PedroNogueira97` |
| `GHCR_READ_TOKEN` | Token A |
| `VPS_PORT` | Somente se o SSH não estiver na 22 |

Variables (opcionais): `VPS_APP_DIR` (padrão `/opt/crm-candidaturas`), `SITE_ADDRESS` e `CHECK_PUBLIC_URL=true`. Ative a última depois que o DNS e o certificado estiverem prontos; o deploy passa a conferir `https://<domínio>/api/health`.

### Secrets dos repositórios `crm-candidaturas-backend` e `crm-candidaturas-frontend`

| Secret | Valor |
|---|---|
| `INFRA_DISPATCH_TOKEN` | Token B |

## 8. Primeiro deploy

1. Push em `main` no backend e no frontend. Cada um publica a imagem e dispara um deploy. O deploy só conclui quando as duas imagens existirem; se o primeiro disparo falhar por isso, use **Actions → Deploy produção → Run workflow** informando as duas tags `sha-<commit>`.
2. Na VPS, como `deploy`:

```sh
cd /opt/crm-candidaturas
scripts/bootstrap-admin.sh
sed -i 's/^INITIAL_USER_PASSWORD=.*/INITIAL_USER_PASSWORD=/' .env
```

3. Acesse `https://crm-candidatura.lnmengenharia.com`.

## 9. Backup diário

Como `deploy`, `crontab -e`:

```cron
0 3 * * * /opt/crm-candidaturas/scripts/backup.sh daily >> /opt/crm-candidaturas/backups/backup.log 2>&1
```

O horário do cron segue o fuso do servidor (não altere o fuso: há outros projetos). Teste a restauração periodicamente: `scripts/restore.sh backups/<arquivo>.dump --yes`.

## 10. Operação

```sh
cd /opt/crm-candidaturas
cat .deploy/current.env                                      # tags em execução
set -a; source .deploy/current.env; set +a
docker compose -f compose.prod.yaml ps
docker compose -f compose.prod.yaml logs -f --tail=100 api
scripts/deploy.sh --backend sha-<commit>                     # deploy/rollback manual
```

O stack usa o projeto Docker `crm-candidaturas`: containers, rede e volumes têm esse prefixo e não interferem nos outros projetos. A limpeza de imagens do `deploy.sh` remove apenas imagens antigas deste projeto.
