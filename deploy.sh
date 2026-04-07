#!/bin/bash
# Dangerzone Deploy - SPEC-001 (idempotent, re-runnable)
# Usage: bash ~/dangerzone/deploy.sh
set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
DANGERZONE_DIR="/home/administrator/dangerzone"
LOG_DIR="$DANGERZONE_DIR/logs"
LOG="$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log"
TUNNEL_NAME="dangerzone"
CF_HOSTNAME="dangerzone.jambu.ai"
PASS_FILE="$DANGERZONE_DIR/.sudo_pass"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

# ── Helpers ─────────────────────────────────────────────────────────────────
ok()     { echo "  ✓ $1"; }
skip()   { echo "  ↷ $1 (já feito)"; }
warn()   { echo "  ⚠ $1"; }
fail()   { echo "  ✗ ERRO: $1"; exit 1; }
banner() { echo; echo "══════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════"; }

# ── Sudo setup (only prompt if no cached pass) ───────────────────────────────
banner "Autenticação Sudo"
if [[ -f "$PASS_FILE" ]] && cat "$PASS_FILE" | sudo -S true 2>/dev/null; then
    SUDOPASS=$(cat "$PASS_FILE")
    skip "Senha já cacheada"
else
    read -r -s -p "  Senha sudo: " SUDOPASS; echo ""
    echo "$SUDOPASS" | sudo -S true 2>/dev/null || fail "Senha inválida"
    echo "$SUDOPASS" > "$PASS_FILE"
    chmod 600 "$PASS_FILE"
    ok "Autenticado"
fi

# Temporário NOPASSWD para esta sessão
if ! sudo grep -q "99-dangerzone-deploy" /etc/sudoers.d/99-dangerzone-deploy 2>/dev/null; then
    echo "$SUDOPASS" | sudo -S bash -c \
        'echo "administrator ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-dangerzone-deploy && chmod 440 /etc/sudoers.d/99-dangerzone-deploy'
fi
ok "NOPASSWD configurado para este deploy"

# ── Phase 0: Environment ─────────────────────────────────────────────────────
banner "Phase 0 — Ambiente"

CLAUDE_UI_BIN=$(which claude-code-ui 2>/dev/null \
    || find /home/administrator/.nvm -name "claude-code-ui" 2>/dev/null | head -1 \
    || echo "")
[[ -z "$CLAUDE_UI_BIN" ]] && fail "claude-code-ui não encontrado. Rode: npm install -g @siteboon/claude-code-ui"

NODE_DIR=$(dirname "$CLAUDE_UI_BIN")
# Prefer OpenWork when present (same as ~/.bashrc: claude() { command openwork "$@"; }).
# claude-code-ui spawns CLAUDE_CODE_PATH directly — no shell functions/aliases apply.
if [[ -x "$NODE_DIR/openwork" ]]; then
    CLAUDE_BIN="$NODE_DIR/openwork"
elif command -v openwork >/dev/null 2>&1; then
    CLAUDE_BIN=$(command -v openwork)
else
    CLAUDE_BIN=$(PATH="$NODE_DIR:/home/administrator/.local/bin:$PATH" which claude 2>/dev/null \
        || echo "/home/administrator/.local/bin/claude")
fi
[[ ! -x "$CLAUDE_BIN" ]] && fail "claude/OpenWork binary não encontrado em $CLAUDE_BIN"

ok "claude-code-ui : $CLAUDE_UI_BIN"
ok "claude (spawn)  : $CLAUDE_BIN"
ok "node dir       : $NODE_DIR"
ok "OS             : $(lsb_release -rs)"

# ── Phase 1.1: Dirs ──────────────────────────────────────────────────────────
banner "Phase 1.1 — Diretórios"
mkdir -p "$DANGERZONE_DIR"/{logs,config,sessions,projects}
ok "~/dangerzone/{logs,config,sessions,projects} prontos"

# ── Phase 1.2: Systemd service (CloudCLI) ────────────────────────────────────
banner "Phase 1.2 — Serviço systemd dangerzone-cloudcli"

NEED_CLOUDCLI_RESTART=false

if [[ ! -f /etc/systemd/system/dangerzone-cloudcli.service ]]; then
    echo "  Escrevendo unit file..."
    sudo tee /etc/systemd/system/dangerzone-cloudcli.service > /dev/null << UNIT
[Unit]
Description=Dangerzone CloudCLI UI (Single Tenant)
Documentation=https://github.com/siteboon/claude-code-ui
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=administrator
Group=administrator
WorkingDirectory=/home/administrator

Environment="NODE_ENV=production"
Environment="PORT=3000"
Environment="HOST=127.0.0.1"
Environment="HOME=/home/administrator"
Environment="CLAUDE_CODE_PATH=${CLAUDE_BIN}"
Environment="CLAUDE_CLI_PATH=${CLAUDE_BIN}"
Environment="CLAUDE_CONFIG_DIR=/home/administrator/.claude"
Environment="DANGERZONE_SESSIONS_DIR=/home/administrator/dangerzone/sessions"
Environment="LOG_LEVEL=info"
Environment="PATH=${NODE_DIR}:/home/administrator/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

ExecStart=${CLAUDE_UI_BIN}
ExecReload=/bin/kill -HUP \$MAINPID

Restart=always
RestartSec=5
StartLimitInterval=60s
StartLimitBurst=3

ProtectSystem=strict
ProtectHome=false
ReadWritePaths=/home/administrator /tmp /run/sudo

[Install]
WantedBy=multi-user.target
UNIT
    sudo chmod 644 /etc/systemd/system/dangerzone-cloudcli.service
    ok "Unit file escrito"
    NEED_CLOUDCLI_RESTART=true
else
    skip "Unit file já existe"
fi

# Keep CLAUDE_CODE_PATH / CLAUDE_CLI_PATH in sync (e.g. after installing OpenWork)
CLOUDCLI_UNIT=/etc/systemd/system/dangerzone-cloudcli.service
if [[ -f "$CLOUDCLI_UNIT" ]]; then
    OLD_CODE=$(grep -m1 '^Environment="CLAUDE_CODE_PATH=' "$CLOUDCLI_UNIT" 2>/dev/null | sed 's/^Environment="CLAUDE_CODE_PATH=//;s/"$//' || true)
    OLD_CLI=$(grep -m1 '^Environment="CLAUDE_CLI_PATH=' "$CLOUDCLI_UNIT" 2>/dev/null | sed 's/^Environment="CLAUDE_CLI_PATH=//;s/"$//' || true)
    if [[ "$OLD_CODE" != "$CLAUDE_BIN" ]] || [[ "$OLD_CLI" != "$CLAUDE_BIN" ]]; then
        echo "  Atualizando CLAUDE_CODE_PATH no serviço: ${OLD_CODE:-?} → $CLAUDE_BIN"
        sudo sed -i \
            -e "s|^Environment=\"CLAUDE_CODE_PATH=.*|Environment=\"CLAUDE_CODE_PATH=${CLAUDE_BIN}\"|" \
            -e "s|^Environment=\"CLAUDE_CLI_PATH=.*|Environment=\"CLAUDE_CLI_PATH=${CLAUDE_BIN}\"|" \
            "$CLOUDCLI_UNIT"
        NEED_CLOUDCLI_RESTART=true
        sudo systemctl daemon-reload
    fi
fi

# Garantir que todos os dirs do ReadWritePaths existam antes de iniciar
echo "  Criando diretórios necessários para o serviço..."
mkdir -p \
    /home/administrator/dangerzone \
    /home/administrator/.config/claude \
    /home/administrator/.claude \
    /home/administrator/projects
ok "Diretórios do ReadWritePaths presentes"

if ! systemctl is-enabled --quiet dangerzone-cloudcli.service 2>/dev/null; then
    sudo systemctl daemon-reload
    sudo systemctl enable dangerzone-cloudcli.service
    ok "Serviço habilitado"
fi

_start_cloudcli() {
    sudo systemctl daemon-reload
    sudo systemctl reset-failed dangerzone-cloudcli.service 2>/dev/null || true
    sudo systemctl restart dangerzone-cloudcli.service 2>/dev/null || true
    echo "  Aguardando inicialização (10s)..." >&2
    sleep 10
}

_show_cloudcli_logs() {
    echo ""
    echo "  ── journal logs ────────────────────────────"
    sudo journalctl -u dangerzone-cloudcli.service --no-pager -n 50 2>&1 || true
    echo "  ────────────────────────────────────────────"
    echo ""
}

_test_binary_direct() {
    echo "  Testando binário diretamente (5s)..."
    timeout 5 env \
        NODE_ENV=production PORT=3000 HOST=127.0.0.1 \
        CLAUDE_CODE_PATH="$CLAUDE_BIN" \
        PATH="${NODE_DIR}:/home/administrator/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        "$CLAUDE_UI_BIN" 2>&1 | head -30 || true
}

if ! systemctl is-active --quiet dangerzone-cloudcli.service 2>/dev/null || [[ "$NEED_CLOUDCLI_RESTART" == true ]]; then
    _start_cloudcli
fi

CL_STATUS=$(sudo systemctl is-active dangerzone-cloudcli.service 2>/dev/null || true)

if [[ "$CL_STATUS" == "active" ]]; then
    ok "Serviço ativo"
else
    warn "Status: $CL_STATUS — removendo restrições de segurança (Node.js compat) e tentando novamente..."
    _show_cloudcli_logs
    sudo sed -i \
        '/LockPersonality\|RestrictRealtime\|MemoryDenyWriteExecute\|NoNewPrivileges\|ProtectKernel\|ProtectControl\|RestrictSUID\|RestrictNames/d' \
        /etc/systemd/system/dangerzone-cloudcli.service
    _start_cloudcli

    CL_STATUS=$(sudo systemctl is-active dangerzone-cloudcli.service 2>/dev/null || true)
    if [[ "$CL_STATUS" == "active" ]]; then
        ok "Serviço ativo após remoção de restrições"
    else
        warn "Ainda falhando. Testando binário diretamente:"
        _test_binary_direct
        _show_cloudcli_logs
        fail "dangerzone-cloudcli não iniciou — veja os logs acima"
    fi
fi

# ── Phase 1.3: Port 3000 ─────────────────────────────────────────────────────
banner "Phase 1.3 — Porta 3000"
# Wait up to 20s for port to bind
for i in {1..4}; do
    if ss -tlnp 2>/dev/null | grep -q ":3000"; then
        PORT_INFO=$(ss -tlnp | grep :3000 | awk '{print $4}')
        ok "Escutando em $PORT_INFO"
        break
    fi
    [[ $i -lt 4 ]] && echo "  Aguardando porta... ($((i*5))s)" && sleep 5
done
if ! ss -tlnp 2>/dev/null | grep -q ":3000"; then
    warn "Porta 3000 não detectada após 20s"
    sudo journalctl -u dangerzone-cloudcli.service --no-pager -n 20
fi
curl -s --max-time 5 http://127.0.0.1:3000 > /dev/null 2>&1 \
    && ok "HTTP respondendo em localhost:3000" \
    || warn "Sem resposta HTTP em localhost:3000 (pode ser normal na startup)"

# ── Phase 1.4: Firewall ──────────────────────────────────────────────────────
banner "Phase 1.4 — UFW Firewall"
UFW_STATUS=$(sudo ufw status | head -1)
if echo "$UFW_STATUS" | grep -q "active"; then
    # Check if our rules exist
    if sudo ufw status | grep -q "22/tcp" && sudo ufw status | grep -q "3000/tcp"; then
        skip "UFW já configurado"
    else
        warn "UFW ativo mas regras incompletas — reconfigurando..."
        sudo ufw --force reset
        sudo ufw default deny incoming
        sudo ufw default allow outgoing
        sudo ufw allow 22/tcp comment 'SSH'
        sudo ufw allow 51820/udp comment 'WireGuard VPN'
        sudo ufw deny 3000/tcp comment 'CloudCLI localhost only'
        sudo ufw --force enable
        ok "UFW reconfigurado"
    fi
else
    sudo ufw --force reset
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow 22/tcp comment 'SSH'
    sudo ufw allow 51820/udp comment 'WireGuard VPN'
    sudo ufw deny 3000/tcp comment 'CloudCLI localhost only'
    sudo ufw --force enable
    ok "UFW configurado"
fi
sudo ufw status verbose

# ── Phase 2.1: cloudflared ───────────────────────────────────────────────────
banner "Phase 2.1 — cloudflared"
if command -v cloudflared &>/dev/null; then
    skip "Já instalado: $(cloudflared --version)"
else
    echo "  Baixando cloudflared..."
    CF_VERSION=$(curl -fsSL https://api.github.com/repos/cloudflare/cloudflared/releases/latest \
        | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    wget -q "https://github.com/cloudflare/cloudflared/releases/download/${CF_VERSION}/cloudflared-linux-amd64.deb" \
        -O /tmp/cloudflared.deb
    sudo dpkg -i /tmp/cloudflared.deb || sudo apt-get install -f -y
    ok "cloudflared $(cloudflared --version) instalado"
fi

# Garantir log file existe com permissão correta
if [[ ! -f /var/log/cloudflared.log ]]; then
    sudo touch /var/log/cloudflared.log
    sudo chmod 644 /var/log/cloudflared.log
    ok "/var/log/cloudflared.log criado"
else
    # Ensure readable
    sudo chmod 644 /var/log/cloudflared.log
    skip "/var/log/cloudflared.log já existe"
fi

# ── Phase 2.2: Tunnel ────────────────────────────────────────────────────────
banner "Phase 2.2 — Cloudflare Tunnel"

if [[ ! -f ~/.cloudflared/cert.pem ]]; then
    warn "cloudflared não autenticado"
    echo ""
    echo "  ► AÇÃO MANUAL NECESSÁRIA:"
    echo "    cloudflared tunnel login"
    echo ""
    echo "  Após autenticar, rode este script novamente."
    # Cleanup NOPASSWD before exit
    sudo rm -f /etc/sudoers.d/99-dangerzone-deploy
    rm -f "$PASS_FILE"
    exit 0
fi
ok "cloudflared autenticado (cert.pem presente)"

# Pegar ou criar tunnel
TUNNEL_ID=""

# Primeiro: ver se já existe no arquivo salvo
if [[ -f "$DANGERZONE_DIR/config/tunnel.id" ]]; then
    SAVED_ID=$(cat "$DANGERZONE_DIR/config/tunnel.id")
    # Validar que é UUID real (36 chars com hífens)
    if [[ "$SAVED_ID" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]]; then
        TUNNEL_ID="$SAVED_ID"
        skip "TUNNEL_ID já salvo: $TUNNEL_ID"
    else
        warn "tunnel.id inválido ('$SAVED_ID') — buscando novamente"
    fi
fi

# Se não temos ID válido, buscar na lista
if [[ -z "$TUNNEL_ID" ]]; then
    TUNNEL_ID=$(cloudflared tunnel list 2>/dev/null \
        | grep -i "$TUNNEL_NAME" \
        | grep -oP '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' \
        | head -1 || true)
fi

# Se ainda não existe, criar
if [[ -z "$TUNNEL_ID" ]]; then
    echo "  Criando tunnel '$TUNNEL_NAME'..."
    TUNNEL_OUTPUT=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1)
    echo "  $TUNNEL_OUTPUT"
    # Extrair UUID do "with id <uuid>"
    TUNNEL_ID=$(echo "$TUNNEL_OUTPUT" \
        | grep -oP 'with id \K[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' \
        | head -1 || true)
fi

[[ -z "$TUNNEL_ID" ]] && fail "Não foi possível obter TUNNEL_ID. Rode: cloudflared tunnel list"

echo "$TUNNEL_ID" > "$DANGERZONE_DIR/config/tunnel.id"
ok "TUNNEL_ID=$TUNNEL_ID"

# Credenciais
TUNNEL_CREDS="$HOME/.cloudflared/${TUNNEL_ID}.json"
[[ ! -f "$TUNNEL_CREDS" ]] && fail "Credenciais não encontradas: $TUNNEL_CREDS"
sudo mkdir -p /etc/cloudflared

if [[ ! -f "/etc/cloudflared/${TUNNEL_ID}.json" ]]; then
    sudo cp "$TUNNEL_CREDS" /etc/cloudflared/
    sudo chmod 600 "/etc/cloudflared/${TUNNEL_ID}.json"
    ok "Credenciais copiadas para /etc/cloudflared/"
else
    skip "Credenciais já em /etc/cloudflared/"
fi

# config.yml
if [[ ! -f /etc/cloudflared/config.yml ]] \
    || ! grep -q "$TUNNEL_ID" /etc/cloudflared/config.yml; then
    sudo tee /etc/cloudflared/config.yml > /dev/null << EOF
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/${TUNNEL_ID}.json

logfile: /var/log/cloudflared.log
log-level: info
protocol: quic

ingress:
  - hostname: ${CF_HOSTNAME}
    service: http://localhost:3000
    originRequest:
      noTLSVerify: true
      connectTimeout: 30s
      tcpKeepAlive: 30s

  - service: http_status:404

metrics: 127.0.0.1:45678
EOF
    ok "config.yml escrito"
else
    skip "config.yml já configurado"
fi

# Validar config
sudo cloudflared tunnel ingress validate /etc/cloudflared/config.yml \
    && ok "Config válida" || warn "Validação da config falhou"

# DNS route
echo "  Verificando DNS route..."
DNS_RESULT=$(dig +short "$CF_HOSTNAME" 2>/dev/null || true)
if echo "$DNS_RESULT" | grep -qi "cloudflare\|cfargotunnel"; then
    skip "DNS já roteado ($DNS_RESULT)"
else
    cloudflared tunnel route dns "$TUNNEL_ID" "$CF_HOSTNAME" \
        && ok "DNS roteado" \
        || warn "DNS route falhou (pode já existir — verificando...)"
    sleep 3
    dig +short "$CF_HOSTNAME" | head -3 || true
fi

# ── Phase 2.3: Tunnel systemd service ───────────────────────────────────────
banner "Phase 2.3 — Serviço systemd dangerzone-tunnel"

NEED_TUNNEL_RESTART=false

# Reescreve sempre que TUNNEL_ID mudar
if [[ ! -f /etc/systemd/system/dangerzone-tunnel.service ]] \
    || ! grep -q "$TUNNEL_ID" /etc/systemd/system/dangerzone-tunnel.service \
    || grep -q "Type=notify" /etc/systemd/system/dangerzone-tunnel.service \
    || grep -q "tunnel run --config" /etc/systemd/system/dangerzone-tunnel.service; then
    sudo tee /etc/systemd/system/dangerzone-tunnel.service > /dev/null << EOF
[Unit]
Description=Cloudflare Tunnel for Dangerzone
After=network-online.target dangerzone-cloudcli.service
Wants=network-online.target
Requires=dangerzone-cloudcli.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/etc/cloudflared
ExecStart=/usr/bin/cloudflared --config /etc/cloudflared/config.yml tunnel run
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
StartLimitInterval=60s
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
EOF
    ok "dangerzone-tunnel.service escrito com ID correto"
    NEED_TUNNEL_RESTART=true
else
    skip "dangerzone-tunnel.service já configurado com ID correto"
fi

if ! systemctl is-enabled --quiet dangerzone-tunnel.service 2>/dev/null; then
    sudo systemctl daemon-reload
    sudo systemctl enable dangerzone-tunnel.service
    ok "Tunnel service habilitado"
fi

if ! systemctl is-active --quiet dangerzone-tunnel.service 2>/dev/null || [[ "$NEED_TUNNEL_RESTART" == true ]]; then
    sudo systemctl daemon-reload
    sudo systemctl reset-failed dangerzone-tunnel.service 2>/dev/null || true
    sudo systemctl restart dangerzone-tunnel.service 2>/dev/null || true
    echo "  Aguardando tunnel conectar (10s)..."
    sleep 10
fi

TN_STATUS=$(sudo systemctl is-active dangerzone-tunnel.service 2>/dev/null || true)
if [[ "$TN_STATUS" == "active" ]]; then
    ok "Tunnel service ativo"
else
    warn "Status: $TN_STATUS"
    sudo journalctl -u dangerzone-tunnel.service --no-pager -n 30
    fail "dangerzone-tunnel não iniciou"
fi

# ── Log rotation ─────────────────────────────────────────────────────────────
banner "Log Rotation"
if [[ ! -f /etc/logrotate.d/dangerzone ]]; then
    sudo mkdir -p /var/log/dangerzone
    sudo chown -R administrator:administrator /var/log/dangerzone
    sudo tee /etc/logrotate.d/dangerzone > /dev/null << 'LOGR'
/var/log/dangerzone/*.log /var/log/cloudflared.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 administrator administrator
    sharedscripts
    postrotate
        /bin/kill -HUP $(cat /var/run/syslogd.pid 2>/dev/null) 2>/dev/null || true
    endscript
}
LOGR
    ok "Logrotate configurado"
else
    skip "Logrotate já configurado"
fi

# ── Cleanup ──────────────────────────────────────────────────────────────────
sudo rm -f /etc/sudoers.d/99-dangerzone-deploy
rm -f "$PASS_FILE"
ok "Regra NOPASSWD temporária removida"

# ── Permanent sudoers rule (persistent across deploys) ───────────────────────
banner "Permissões Sudo Permanentes"
SUDOERS_FILE="/etc/sudoers.d/dangerzone-administrator"
if [[ ! -f "$SUDOERS_FILE" ]]; then
    echo 'administrator ALL=(ALL) NOPASSWD: ALL' | sudo tee "$SUDOERS_FILE" > /dev/null
    sudo chmod 440 "$SUDOERS_FILE"
    sudo visudo -c -f "$SUDOERS_FILE" 2>&1 && ok "Regra NOPASSWD permanente criada" || warn "Falha na validação do sudoers"
else
    skip "Regra NOPASSWD permanente já existe"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
banner "RESUMO FINAL"
echo ""
printf "  %-20s %s\n" "cloudcli service:"  "$(sudo systemctl is-active dangerzone-cloudcli.service 2>/dev/null)"
printf "  %-20s %s\n" "tunnel service:"    "$(sudo systemctl is-active dangerzone-tunnel.service 2>/dev/null)"
printf "  %-20s %s\n" "TUNNEL_ID:"         "$(cat $DANGERZONE_DIR/config/tunnel.id 2>/dev/null)"
printf "  %-20s %s\n" "Porta 3000:"        "$(ss -tlnp 2>/dev/null | grep :3000 | awk '{print $4}' | head -1 || echo 'não detectada')"
printf "  %-20s %s\n" "UFW:"               "$(sudo ufw status | head -1)"
printf "  %-20s %s\n" "DNS:"               "$(dig +short $CF_HOSTNAME | head -1 || echo 'pendente')"
echo ""
echo "  Log: $LOG"
echo ""
echo "  ► PRÓXIMO PASSO (manual no browser):"
echo "    https://dash.cloudflare.com → Zero Trust → Access → Applications"
echo "    App: $CF_HOSTNAME | Policy: email = joao@jambu.ai"
echo ""
banner "DEPLOY COMPLETO — $(date)"
