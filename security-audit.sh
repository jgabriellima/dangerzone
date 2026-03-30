#!/bin/bash
# Dangerzone Security Audit
# Usage: bash ~/dangerzone/security-audit.sh
set -uo pipefail

PASS=0; WARN=0; FAIL=0
LOG="/home/administrator/dangerzone/logs/security-audit-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

ok()   { echo "  [PASS] $1"; ((PASS++)); }
warn() { echo "  [WARN] $1"; ((WARN++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }
banner() { echo; echo "══════════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════════"; }

# Sudo setup — pede senha uma vez e configura NOPASSWD temporário
read -r -s -p "Senha sudo: " SUDOPASS; echo ""
echo "$SUDOPASS" | sudo -S true 2>/dev/null || { echo "Senha inválida"; exit 1; }
echo "$SUDOPASS" | sudo -S bash -c \
    'echo "administrator ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-audit-tmp && chmod 440 /etc/sudoers.d/99-audit-tmp'
trap 'sudo rm -f /etc/sudoers.d/99-audit-tmp' EXIT

echo ""
echo "  DANGERZONE SECURITY AUDIT — $(date)"
echo "  Host: $(hostname) | User: $(whoami) | OS: $(lsb_release -rs)"

# ── 1. Firewall ──────────────────────────────────────────────────────────────
banner "1. Firewall (UFW)"

UFW_STATUS=$(sudo ufw status | head -1)
if echo "$UFW_STATUS" | grep -q "active"; then
    ok "UFW ativo"
else
    fail "UFW INATIVO — tráfego externo sem filtragem"
fi

if sudo ufw status | grep -q "deny.*incoming\|Anywhere.*DENY"; then
    ok "Política padrão: deny incoming"
else
    warn "Política de entrada não é deny por padrão"
fi

if sudo ufw status | grep -q "3000/tcp.*DENY"; then
    ok "Porta 3000 bloqueada externamente"
else
    fail "Porta 3000 NÃO está explicitamente bloqueada no UFW"
fi

if sudo ufw status | grep -q "22/tcp.*ALLOW"; then
    ok "SSH (22/tcp) permitido"
fi

# Portas extras abertas?
EXTRA=$(sudo ufw status numbered | grep "ALLOW IN" | grep -v "22/tcp\|51820/udp" | grep -v "v6" || true)
if [[ -n "$EXTRA" ]]; then
    warn "Regras ALLOW adicionais detectadas:\n$EXTRA"
else
    ok "Nenhuma porta extra com ALLOW IN"
fi

# ── 2. Portas em escuta ───────────────────────────────────────────────────────
banner "2. Portas em Escuta"

echo "  Serviços TCP ativos:"
ss -tlnp 2>/dev/null | grep LISTEN | awk '{print "    " $4 " " $6}' || true

# Verificar CloudCLI binding
if ss -tlnp 2>/dev/null | grep ":3000" | grep -q "127.0.0.1"; then
    ok "CloudCLI (3000) bind em 127.0.0.1 APENAS"
elif ss -tlnp 2>/dev/null | grep -q ":3000"; then
    PORT_BIND=$(ss -tlnp | grep ":3000" | awk '{print $4}')
    fail "CloudCLI (3000) exposto em: $PORT_BIND — deveria ser 127.0.0.1"
else
    warn "CloudCLI não detectado na porta 3000"
fi

# Portas escutando em 0.0.0.0 (qualquer interface)
EXPOSED=$(ss -tlnp 2>/dev/null | grep LISTEN | grep "0\.0\.0\.0" | grep -v ":22 \|:51820" || true)
if [[ -n "$EXPOSED" ]]; then
    warn "Serviços escutando em 0.0.0.0 (todas interfaces):"
    echo "$EXPOSED" | awk '{print "    " $4 " " $6}'
else
    ok "Nenhum serviço inesperado exposto em 0.0.0.0"
fi

# ── 3. SSH ───────────────────────────────────────────────────────────────────
banner "3. SSH Configuration"

SSH_CFG="/etc/ssh/sshd_config"

check_ssh() {
    local key="$1" expected="$2" label="$3"
    local val
    val=$(grep -iE "^[[:space:]]*${key}[[:space:]]" "$SSH_CFG" 2>/dev/null | tail -1 | awk '{print tolower($2)}' || echo "")
    if [[ "$val" == "$expected" ]]; then
        ok "$label: $val"
    elif [[ -z "$val" ]]; then
        warn "$label: não configurado (default pode ser inseguro)"
    else
        fail "$label: $val (esperado: $expected)"
    fi
}

check_ssh "PermitRootLogin"      "no"              "PermitRootLogin"
check_ssh "PasswordAuthentication" "no"            "PasswordAuthentication"
check_ssh "PubkeyAuthentication" "yes"             "PubkeyAuthentication"
check_ssh "PermitEmptyPasswords" "no"              "PermitEmptyPasswords"
check_ssh "X11Forwarding"        "no"              "X11Forwarding"

MAX_AUTH=$(grep -iE "^[[:space:]]*MaxAuthTries" "$SSH_CFG" 2>/dev/null | awk '{print $2}' || echo "")
if [[ -n "$MAX_AUTH" ]] && (( MAX_AUTH <= 4 )); then
    ok "MaxAuthTries: $MAX_AUTH"
else
    warn "MaxAuthTries não configurado ou alto (padrão=6) — considere MaxAuthTries 3"
fi

# Authorized keys
if [[ -f ~/.ssh/authorized_keys ]]; then
    KEY_COUNT=$(wc -l < ~/.ssh/authorized_keys)
    ok "authorized_keys presente ($KEY_COUNT chave(s))"
    AUTH_PERM=$(stat -c "%a" ~/.ssh/authorized_keys)
    [[ "$AUTH_PERM" == "600" || "$AUTH_PERM" == "644" ]] && ok "Permissão authorized_keys: $AUTH_PERM" \
        || warn "Permissão authorized_keys: $AUTH_PERM (recomendado: 600)"
else
    warn "authorized_keys não encontrado"
fi

# ── 4. Usuários e Sudo ────────────────────────────────────────────────────────
banner "4. Usuários e Sudo"

# Usuários com shell de login (não serviços)
echo "  Usuários com shell de login:"
getent passwd | awk -F: '$7 ~ /bash|sh|zsh|fish/ && $3 >= 1000 {print "    " $1 " (uid=" $3 ")"}' || true

# Usuários com senha vazia
EMPTY_PASS=$(sudo awk -F: '($2 == "" || $2 == "!!" ) && $3 >= 1000 {print $1}' /etc/shadow 2>/dev/null || true)
if [[ -z "$EMPTY_PASS" ]]; then
    ok "Nenhum usuário com senha vazia"
else
    fail "Usuário(s) com senha vazia: $EMPTY_PASS"
fi

# Sudoers NOPASSWD permanentes (além do temporário de deploy)
NOPASSWD_RULES=$(sudo grep -r "NOPASSWD" /etc/sudoers /etc/sudoers.d/ 2>/dev/null | grep -v "^#\|99-dangerzone-deploy" || true)
if [[ -z "$NOPASSWD_RULES" ]]; then
    ok "Nenhuma regra NOPASSWD permanente em sudoers"
else
    warn "Regras NOPASSWD encontradas:\n$NOPASSWD_RULES"
fi

# Arquivo temporário de deploy foi limpo?
if [[ -f /etc/sudoers.d/99-dangerzone-deploy ]]; then
    fail "Arquivo NOPASSWD temporário do deploy ainda existe: /etc/sudoers.d/99-dangerzone-deploy"
    sudo rm -f /etc/sudoers.d/99-dangerzone-deploy && ok "Removido automaticamente"
else
    ok "Arquivo NOPASSWD temporário do deploy removido"
fi

# Senha sudo em arquivo?
if [[ -f /home/administrator/dangerzone/.sudo_pass ]]; then
    fail "Arquivo de senha sudo em disco: ~/dangerzone/.sudo_pass"
    rm -f /home/administrator/dangerzone/.sudo_pass && ok "Removido automaticamente"
else
    ok "Nenhum arquivo de senha sudo em disco"
fi

# ── 5. Serviços Systemd ───────────────────────────────────────────────────────
banner "5. Serviços Systemd"

# CloudCLI roda como administrator?
CLOUDCLI_USER=$(sudo systemctl show dangerzone-cloudcli.service -p User --value 2>/dev/null || echo "")
if [[ "$CLOUDCLI_USER" == "administrator" ]]; then
    ok "dangerzone-cloudcli roda como: administrator (não-root)"
else
    fail "dangerzone-cloudcli roda como: ${CLOUDCLI_USER:-root} — deveria ser administrator"
fi

# Tunnel roda como root (necessário para cloudflared)
TUNNEL_USER=$(sudo systemctl show dangerzone-tunnel.service -p User --value 2>/dev/null || echo "")
[[ "$TUNNEL_USER" == "root" ]] && ok "dangerzone-tunnel roda como root (necessário para cloudflared)" \
    || warn "dangerzone-tunnel user: $TUNNEL_USER"

# Status dos serviços
for svc in dangerzone-cloudcli dangerzone-tunnel; do
    STATUS=$(sudo systemctl is-active ${svc}.service 2>/dev/null || echo "inactive")
    [[ "$STATUS" == "active" ]] && ok "$svc: active" || warn "$svc: $STATUS"
done

# ── 6. Permissões de Arquivos Críticos ───────────────────────────────────────
banner "6. Permissões de Arquivos Críticos"

check_perm() {
    local path="$1" expected_perm="$2" label="$3"
    if [[ -e "$path" ]]; then
        local perm
        perm=$(stat -c "%a" "$path")
        if [[ "$perm" == "$expected_perm" ]]; then
            ok "$label ($path): $perm"
        else
            warn "$label ($path): $perm (recomendado: $expected_perm)"
        fi
    else
        warn "$label não encontrado: $path"
    fi
}

check_perm "/etc/cloudflared"                        "750" "Dir cloudflared"
check_perm "/etc/cloudflared/config.yml"             "644" "Tunnel config"

# Tunnel credentials devem ser 600
CREDS=$(ls /etc/cloudflared/*.json 2>/dev/null | head -1 || echo "")
if [[ -n "$CREDS" ]]; then
    check_perm "$CREDS" "600" "Tunnel credentials"
else
    warn "Nenhum credentials .json em /etc/cloudflared/"
fi

check_perm "/home/administrator/.ssh"                "700" "~/.ssh dir"
check_perm "/home/administrator/dangerzone"          "755" "~/dangerzone dir"

# ── 7. Logs de Auth Recentes ─────────────────────────────────────────────────
banner "7. Tentativas de Acesso SSH (últimas 24h)"

FAILED=$(sudo journalctl -u ssh --since "24h ago" 2>/dev/null | grep -c "Failed\|Invalid\|Disconnected" || echo "0")
ok "Tentativas falhas de SSH nas últimas 24h: $FAILED"

if (( FAILED > 50 )); then
    warn "Volume alto de tentativas falhas — considere fail2ban"
fi

# IPs que mais tentaram
echo "  Top IPs atacantes (últimas 24h):"
sudo journalctl -u ssh --since "24h ago" 2>/dev/null \
    | grep "Failed password\|Invalid user" \
    | grep -oP "from \K[\d.]+" \
    | sort | uniq -c | sort -rn | head -5 \
    | awk '{print "    " $2 " → " $1 " tentativas"}' || echo "    (nenhuma)"

# fail2ban instalado?
if command -v fail2ban-client &>/dev/null; then
    ok "fail2ban instalado"
else
    warn "fail2ban não instalado — recomendado para proteção SSH"
fi

# ── 8. Updates de Segurança ──────────────────────────────────────────────────
banner "8. Updates de Segurança"

PENDING=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || echo "0")
if (( PENDING == 0 )); then
    ok "Sistema atualizado (sem pacotes pendentes)"
else
    SECURITY=$(apt list --upgradable 2>/dev/null | grep -i "security" | wc -l || echo "0")
    if (( SECURITY > 0 )); then
        fail "$SECURITY update(s) de SEGURANÇA pendentes — rode: sudo apt upgrade -y"
    else
        warn "$PENDING update(s) pendentes (nenhum crítico de segurança)"
    fi
fi

if dpkg -l unattended-upgrades 2>/dev/null | grep -q "^ii"; then
    ok "unattended-upgrades instalado"
else
    warn "unattended-upgrades não instalado — considere: sudo apt install unattended-upgrades"
fi

# ── 9. Configurações de Kernel ────────────────────────────────────────────────
banner "9. Kernel / Sysctl"

check_sysctl() {
    local key="$1" expected="$2"
    local val
    val=$(sysctl -n "$key" 2>/dev/null || echo "unavailable")
    if [[ "$val" == "$expected" ]]; then
        ok "$key = $val"
    else
        warn "$key = $val (recomendado: $expected)"
    fi
}

check_sysctl "net.ipv4.conf.all.accept_redirects"   "0"
check_sysctl "net.ipv4.conf.all.send_redirects"     "0"
check_sysctl "net.ipv4.conf.all.rp_filter"          "1"
check_sysctl "net.ipv4.tcp_syncookies"              "1"
check_sysctl "kernel.dmesg_restrict"                "1"
check_sysctl "fs.suid_dumpable"                     "0"

# ── 10. SUID/SGID binaries não-padrão ────────────────────────────────────────
banner "10. Binários SUID/SGID Não-Padrão"

echo "  Verificando binários SUID/SGID fora de /usr e /bin..."
UNUSUAL_SUID=$(find /home /tmp /var /opt /srv /root 2>/dev/null \
    -perm /6000 -type f 2>/dev/null | head -10 || true)
if [[ -z "$UNUSUAL_SUID" ]]; then
    ok "Nenhum SUID/SGID em diretórios não-padrão"
else
    fail "SUID/SGID encontrados fora do padrão:"
    echo "$UNUSUAL_SUID" | awk '{print "    " $0}'
fi

# ── 11. World-writable dirs ───────────────────────────────────────────────────
banner "11. Diretórios World-Writable Não-Padrão"

WW=$(find /etc /home /var/www /srv /opt 2>/dev/null \
    -maxdepth 4 -type d -perm -o+w 2>/dev/null \
    | grep -v "^/tmp\|^/var/tmp\|/proc" | head -10 || true)
if [[ -z "$WW" ]]; then
    ok "Nenhum diretório world-writable em locais críticos"
else
    warn "Diretórios world-writable encontrados:"
    echo "$WW" | awk '{print "    " $0}'
fi

# ── 12. Cloudflare Access ─────────────────────────────────────────────────────
banner "12. Cloudflare Access"

echo "  Testando resposta de dangerzone.jambu.ai..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://dangerzone.jambu.ai 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "302" || "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
    ok "dangerzone.jambu.ai retorna $HTTP_CODE (acesso bloqueado — Cloudflare Access ativo)"
elif [[ "$HTTP_CODE" == "200" ]]; then
    fail "dangerzone.jambu.ai retorna 200 SEM AUTH — Cloudflare Access não configurado!"
elif [[ "$HTTP_CODE" == "000" ]]; then
    warn "Sem resposta de dangerzone.jambu.ai (tunnel pode estar inicializando)"
else
    warn "dangerzone.jambu.ai retorna $HTTP_CODE — verifique configuração"
fi

# ── Resumo ────────────────────────────────────────────────────────────────────
banner "RESUMO DA AUDITORIA"
echo ""
TOTAL=$((PASS + WARN + FAIL))
echo "  Total verificações : $TOTAL"
printf "  %-6s %s\n" "[PASS]" "$PASS"
printf "  %-6s %s\n" "[WARN]" "$WARN"
printf "  %-6s %s\n" "[FAIL]" "$FAIL"
echo ""

if (( FAIL == 0 && WARN <= 3 )); then
    echo "  ✓ Postura de segurança: BOA"
elif (( FAIL == 0 )); then
    echo "  ⚠ Postura de segurança: ACEITÁVEL — revisar os WARNs"
else
    echo "  ✗ Postura de segurança: ATENÇÃO — resolver os FAILs"
fi

echo ""
echo "  Log completo: $LOG"
banner "FIM DA AUDITORIA — $(date)"
