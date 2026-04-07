# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Dangerzone is a self-hosted, single-tenant deployment system for [claude-code-ui](https://github.com/siteboon/claude-code-ui) — a Node.js web interface for Claude Code. It exposes the UI securely via Cloudflare Tunnel with Zero Trust Access, running on Ubuntu 24.04 LTS.

## Operational Commands

```bash
# Deploy/redeploy everything — also use this to fix any issue (idempotent, safe to re-run)
bash ~/dangerzone/deploy.sh

# Security compliance audit (12 categories, read-only)
bash ~/dangerzone/security-audit.sh

# Service status
systemctl status dangerzone-cloudcli dangerzone-tunnel

# Restart services
sudo systemctl restart dangerzone-cloudcli dangerzone-tunnel

# Live logs
journalctl -u dangerzone-cloudcli -f
journalctl -u dangerzone-tunnel -f
```

## Architecture

Two systemd services work in tandem:

1. **`dangerzone-cloudcli`** — runs `claude-code-ui` as `administrator` on `127.0.0.1:3000`. Spawns `claude` subprocesses per session. Systemd hardened (NoNewPrivileges, ProtectSystem=strict, ReadWritePaths whitelist).

2. **`dangerzone-tunnel`** — runs `cloudflared` as root, proxying `dangerzone.jambu.ai` → `localhost:3000` via QUIC tunnel. Requires `dangerzone-cloudcli` to be running first (Requires= dependency).

Access flow: User → `https://dangerzone.jambu.ai` → Cloudflare Zero Trust (email auth: joao@jambu.ai) → Cloudflare Tunnel → `localhost:3000` → claude-code-ui → `claude` subprocess.

Port 3000 is UFW-blocked externally; only the tunnel can reach it.

## Key File Locations

| Path | Purpose |
|------|---------|
| `/etc/systemd/system/dangerzone-cloudcli.service` | CloudCLI UI service unit |
| `/etc/systemd/system/dangerzone-tunnel.service` | Cloudflare Tunnel service unit |
| `/etc/cloudflared/config.yml` | Tunnel config (tunnel ID, hostname, ingress) |
| `/etc/cloudflared/<UUID>.json` | Tunnel credentials (root-owned, 600) |
| `~/dangerzone/config/tunnel.id` | Stored Cloudflare Tunnel UUID |
| `~/.cloudflared/cert.pem` | Cloudflare auth cert |
| `/var/log/cloudflared.log` | Tunnel log file |

## deploy.sh Phases

The deployment script runs 12 phases (idempotent):
- **Phase 0**: Discovers claude-code-ui binary, claude CLI, Node.js via NVM
- **Phase 1.x**: Creates directories, writes systemd unit, configures UFW
- **Phase 2.x**: Downloads/installs cloudflared, creates/reuses Cloudflare Tunnel, writes tunnel service
- **Final**: Configures logrotate, removes temporary sudo credentials

The script caches sudo credentials in `~/dangerzone/.sudo_pass` during deployment and deletes it on completion.

## Environment Variables (cloudcli service)

| Variable | Value |
|----------|-------|
| `PORT` | 3000 |
| `HOST` | 127.0.0.1 |
| `CLAUDE_CODE_PATH` | OpenWork if `$NODE_DIR/openwork` exists (same CLI args as `claude`), else official `claude` binary — set by `deploy.sh` |
| `CLAUDE_CONFIG_DIR` | `/home/administrator/.config/claude` |
| `DANGERZONE_SESSIONS_DIR` | `/home/administrator/dangerzone/sessions` |
| `NODE_ENV` | production |
