#!/bin/bash
# Hosting Platform — Interactive Setup
# Generates inventory/hosts.yml and group_vars/all.yml from user input.
# Run this ONCE before the first deployment. All secrets are generated
# locally and never leave this machine.
#
# Usage: cd ansible && bash setup.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default="${3:-}"
    local value

    if [ -n "$default" ]; then
        echo -en "${BOLD}${prompt_text}${NC} [${default}]: "
        read -r value
        value="${value:-$default}"
    else
        echo -en "${BOLD}${prompt_text}${NC}: "
        read -r value
        while [ -z "$value" ]; do
            echo -en "  ${RED}Required.${NC} ${prompt_text}: "
            read -r value
        done
    fi
    printf -v "$var_name" '%s' "$value"
}

prompt_optional() {
    local var_name="$1"
    local prompt_text="$2"
    local default="${3:-}"
    local value

    if [ -n "$default" ]; then
        echo -en "${prompt_text} [${default}]: "
        read -r value
        value="${value:-$default}"
    else
        echo -en "${prompt_text} (leave empty to skip): "
        read -r value
    fi
    printf -v "$var_name" '%s' "$value"
}

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  Hosting Platform — Initial Setup${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo "This script generates your inventory and configuration files."
echo "All secrets are generated locally — nothing is transmitted."
echo ""

# ============================================================================
# Prerequisites check
# ============================================================================

info "Checking prerequisites..."

MISSING=""
command -v openssl  >/dev/null 2>&1 || MISSING="$MISSING openssl"
command -v wg       >/dev/null 2>&1 || MISSING="$MISSING wireguard-tools"
command -v ansible  >/dev/null 2>&1 || MISSING="$MISSING ansible"
command -v python3  >/dev/null 2>&1 || MISSING="$MISSING python3"

if [ -n "$MISSING" ]; then
    warn "Missing required tools:$MISSING"
    echo ""
    echo -en "${BOLD}Install missing dependencies now? (Y/n):${NC} "
    read -r install_deps
    if [ "$install_deps" != "n" ] && [ "$install_deps" != "N" ]; then
        if command -v apt-get >/dev/null 2>&1; then
            info "Installing via apt..."
            sudo apt-get update -qq
            # Map tool names to package names
            PKGS=""
            for tool in $MISSING; do
                case "$tool" in
                    wireguard-tools) PKGS="$PKGS wireguard-tools" ;;
                    ansible)        PKGS="$PKGS ansible" ;;
                    openssl)        PKGS="$PKGS openssl" ;;
                    python3)        PKGS="$PKGS python3" ;;
                esac
            done
            sudo apt-get install -y $PKGS
        elif command -v brew >/dev/null 2>&1; then
            info "Installing via Homebrew..."
            for tool in $MISSING; do
                brew install "$tool"
            done
        elif command -v pacman >/dev/null 2>&1; then
            info "Installing via pacman..."
            PKGS=""
            for tool in $MISSING; do
                case "$tool" in
                    python3) PKGS="$PKGS python" ;;
                    *)       PKGS="$PKGS $tool" ;;
                esac
            done
            sudo pacman -S --noconfirm $PKGS
        else
            error "No supported package manager found (apt, brew, pacman)."
            echo "  Install manually:$MISSING"
            echo "  See docs/BOOTSTRAP.md for instructions."
            exit 1
        fi
        # Verify installation succeeded
        STILL_MISSING=""
        command -v openssl  >/dev/null 2>&1 || STILL_MISSING="$STILL_MISSING openssl"
        command -v wg       >/dev/null 2>&1 || STILL_MISSING="$STILL_MISSING wireguard-tools"
        command -v ansible  >/dev/null 2>&1 || STILL_MISSING="$STILL_MISSING ansible"
        command -v python3  >/dev/null 2>&1 || STILL_MISSING="$STILL_MISSING python3"
        if [ -n "$STILL_MISSING" ]; then
            error "Failed to install:$STILL_MISSING"
            exit 1
        fi
        ok "Dependencies installed"
    else
        error "Cannot continue without:$MISSING"
        echo "  See docs/BOOTSTRAP.md for manual installation instructions."
        exit 1
    fi
fi
ok "All prerequisites found"
echo ""

# ============================================================================
# Check for existing files
# ============================================================================

if [ -f "inventory/hosts.yml" ] || [ -f "group_vars/all.yml" ]; then
    warn "Configuration files already exist!"
    echo "  inventory/hosts.yml: $([ -f inventory/hosts.yml ] && echo 'EXISTS' || echo 'missing')"
    echo "  group_vars/all.yml:  $([ -f group_vars/all.yml ] && echo 'EXISTS' || echo 'missing')"
    echo ""
    echo -en "${BOLD}Overwrite existing files? (y/N):${NC} "
    read -r overwrite
    if [ "$overwrite" != "y" ] && [ "$overwrite" != "Y" ]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

# ============================================================================
# Gather information
# ============================================================================

echo -e "${BOLD}--- Domain & General ---${NC}"
echo ""
prompt DOMAIN "Primary domain (e.g., example.com)"
prompt TIMEZONE "Timezone" "UTC"
echo ""

echo -e "${BOLD}--- Server ns1 (Primary) ---${NC}"
echo ""
prompt NS1_IPV4 "ns1 public IPv4 address"
prompt_optional NS1_IPV6 "ns1 public IPv6 address"
prompt NS1_LOCATION "ns1 location" "location_a"
echo ""

echo -e "${BOLD}--- Server ns2 (Secondary) ---${NC}"
echo ""
prompt NS2_IPV4 "ns2 public IPv4 address"
prompt_optional NS2_IPV6 "ns2 public IPv6 address"
prompt NS2_LOCATION "ns2 location" "location_b"
echo ""

echo -e "${BOLD}--- SSH ---${NC}"
echo ""
prompt SSH_KEY_PATH "Path to bootstrapping SSH key" "$HOME/hosting-platform.key"
if [ ! -f "$SSH_KEY_PATH" ]; then
    warn "SSH key not found at $SSH_KEY_PATH — you'll need it for Phase 1"
fi
prompt SSH_PORT "SSH port" "22"
echo ""

echo -e "${BOLD}--- Backup ---${NC}"
echo ""
echo "  Restic encrypted backups to SFTP or S3-compatible storage."
echo "  Leave empty to disable backups for now. You can enable later."
echo ""
echo "  1) SFTP (Hetzner Storage Box, rsync.net, any SSH server)"
echo "  2) S3   (AWS S3, MinIO, Wasabi, Backblaze B2)"
echo "  3) Skip (configure later)"
echo ""
echo -en "${BOLD}Backup target [1/2/3]:${NC} "
read -r BACKUP_CHOICE
BACKUP_CHOICE="${BACKUP_CHOICE:-3}"

BACKUP_BACKEND="sftp"
BACKUP_ENABLED="false"
SFTP_USER=""
SFTP_HOST=""
SFTP_PATH="backups"
SFTP_PORT="22"
BACKUP_SSH_KEY=""
S3_ENDPOINT=""
S3_BUCKET=""
S3_PATH=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_REGION=""

case "$BACKUP_CHOICE" in
    1)
        BACKUP_BACKEND="sftp"
        BACKUP_ENABLED="true"
        echo ""
        prompt SFTP_USER "SFTP user (e.g., u123456-sub1)"
        prompt SFTP_HOST "SFTP hostname (e.g., u123456.your-storagebox.de)"
        prompt_optional SFTP_PATH "SFTP base path" "backups"
        prompt_optional SFTP_PORT "SFTP port (23 for Hetzner Storage Box)" "22"
        prompt_optional BACKUP_SSH_KEY "SSH key for backup SFTP (separate from bootstrap key)" ""
        if [ -z "$BACKUP_SSH_KEY" ]; then
            warn "No backup SSH key specified. Generate one with: ssh-keygen -t ed25519 -f ~/.ssh/backup-sftp.key"
        fi
        ;;
    2)
        BACKUP_BACKEND="s3"
        BACKUP_ENABLED="true"
        echo ""
        prompt S3_ENDPOINT "S3 endpoint (e.g., s3.eu-central-1.amazonaws.com)"
        prompt S3_BUCKET "S3 bucket name"
        prompt_optional S3_PATH "Path prefix inside bucket" ""
        prompt S3_ACCESS_KEY "S3 access key"
        prompt S3_SECRET_KEY "S3 secret key"
        prompt_optional S3_REGION "S3 region (some providers require this)" ""
        ;;
    *)
        info "Backups disabled — configure later in group_vars/all.yml"
        ;;
esac
echo ""

echo -e "${BOLD}--- Organization ---${NC}"
echo ""
prompt ORG_NAME "Organization name (shown in Zitadel console)" "Hosting Platform"
prompt ADMIN_EMAIL "Admin email address" "admin@${DOMAIN}"
echo ""

# ============================================================================
# Generate secrets
# ============================================================================

info "Generating secrets..."

PG_SUPERUSER_PASS=$(openssl rand -base64 22)
PG_REPMGR_PASS=$(openssl rand -base64 22)
PG_NETBIRD_PASS=$(openssl rand -base64 22)
PG_NETBIRD_DEX_PASS=$(openssl rand -base64 22)
PG_NETBIRD_EVENTS_PASS=$(openssl rand -base64 22)
PG_GATUS_PASS=$(openssl rand -base64 22)
PDNS_API_KEY=$(openssl rand -base64 48)

ok "All secrets generated locally"
echo ""

# ============================================================================
# Write inventory/hosts.yml
# ============================================================================

info "Writing inventory/hosts.yml..."

mkdir -p inventory

cat > inventory/hosts.yml << INVENTORY_EOF
---
# Hosting Platform — Server Inventory
# Generated by setup.sh on $(date -Iseconds)
# This file is gitignored — never commit it.

all:
  vars:
    ansible_user: root
    ansible_python_interpreter: /usr/bin/python3

  children:
    dns_servers:
      hosts:
        ns1:
          ansible_host: ${NS1_IPV4}
          public_ipv6: ${NS1_IPV6:-}
          hostname: ns1.${DOMAIN}
          location: ${NS1_LOCATION}
          wireguard_ip: 10.100.0.1
        ns2:
          ansible_host: ${NS2_IPV4}
          public_ipv6: ${NS2_IPV6:-}
          hostname: ns2.${DOMAIN}
          location: ${NS2_LOCATION}
          wireguard_ip: 10.100.0.2

    netbird_peers:
      hosts:
        ns1:
        ns2:

    backup_targets:
      hosts:
        ns1:
        ns2:
INVENTORY_EOF

ok "inventory/hosts.yml written"

# ============================================================================
# Write group_vars/all.yml
# ============================================================================

info "Writing group_vars/all.yml..."

mkdir -p group_vars

cat > group_vars/all.yml << 'ALLVARS_HEADER'
---
# Hosting Platform — Global Variables
# Generated by setup.sh — this file is gitignored.
# Secrets are stored here and in .generated_secrets/ (also gitignored).

ALLVARS_HEADER

cat >> group_vars/all.yml << ALLVARS_EOF
# OS & System
timezone: ${TIMEZONE}

# SSH & Security
ssh_port: ${SSH_PORT}
ssh_break_glass_enabled: true
ansible_ssh_private_key_file: "{{ playbook_dir }}/.generated_secrets/ssh/{{ inventory_hostname }}"

# Domain
platform_domain: ${DOMAIN}

# PostgreSQL HA
postgresql_superuser_password: "${PG_SUPERUSER_PASS}"
postgresql_repmgr_password: "${PG_REPMGR_PASS}"
postgresql_netbird_password: "${PG_NETBIRD_PASS}"
postgresql_netbird_dex_password: "${PG_NETBIRD_DEX_PASS}"
postgresql_netbird_events_password: "${PG_NETBIRD_EVENTS_PASS}"
postgresql_gatus_password: "${PG_GATUS_PASS}"

# PowerDNS
powerdns_api_key: "${PDNS_API_KEY}"

# Zitadel IAM
zitadel_domain: "auth.{{ platform_domain }}"
zitadel_org_name: "${ORG_NAME}"
zitadel_admin_username: "admin"
zitadel_admin_email: "${ADMIN_EMAIL}"

# NetBird VPN Mesh
netbird_management_url: "https://vpn.{{ platform_domain }}"
netbird_setup_key: ""

# Gatus Monitoring
gatus_domain: "status.{{ platform_domain }}"

# Backup
backup_enabled: ${BACKUP_ENABLED}
backup_backend: ${BACKUP_BACKEND}
ALLVARS_EOF

if [ "$BACKUP_BACKEND" = "sftp" ] && [ "$BACKUP_ENABLED" = "true" ]; then
    cat >> group_vars/all.yml << BACKUP_EOF
backup_sftp_user: ${SFTP_USER}
backup_sftp_host: ${SFTP_HOST}
backup_sftp_path: ${SFTP_PATH}
backup_sftp_port: ${SFTP_PORT}
BACKUP_EOF
    if [ -n "$BACKUP_SSH_KEY" ]; then
        echo "restic_ssh_key_src: \"${BACKUP_SSH_KEY}\"" >> group_vars/all.yml
    fi
fi

if [ "$BACKUP_BACKEND" = "s3" ] && [ "$BACKUP_ENABLED" = "true" ]; then
    cat >> group_vars/all.yml << BACKUP_EOF
backup_s3_endpoint: ${S3_ENDPOINT}
backup_s3_bucket: ${S3_BUCKET}
backup_s3_path: "${S3_PATH}"
backup_s3_access_key: "${S3_ACCESS_KEY}"
backup_s3_secret_key: "${S3_SECRET_KEY}"
backup_s3_region: "${S3_REGION}"
BACKUP_EOF
fi

cat >> group_vars/all.yml << 'PATHS_EOF'

# Backup paths per server (/opt covers all service configs + data)
ns1_backup_paths:
  - /opt
  - /etc/restic
  - /root/.ssh
  - /etc/wireguard

ns2_backup_paths:
  - /opt
  - /etc/restic
  - /root/.ssh
  - /etc/wireguard

# Alerting (leave empty — Gatus handles alerts)
alert_webhook_url: ""
PATHS_EOF

ok "group_vars/all.yml written"

# ============================================================================
# Install Ansible Galaxy collections
# ============================================================================

info "Installing Ansible Galaxy collections..."
ansible-galaxy install -r requirements.yml --force >/dev/null 2>&1
ok "Ansible collections installed"

# ============================================================================
# Summary
# ============================================================================

echo ""
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD}  Setup Complete${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
echo "  Files created:"
echo "    inventory/hosts.yml"
echo "    group_vars/all.yml"
echo ""
echo -e "  ${YELLOW}IMPORTANT — DNS glue records:${NC}"
echo "    Configure these at your domain registrar BEFORE deploying:"
echo "      ns1.${DOMAIN} -> ${NS1_IPV4}"
echo "      ns2.${DOMAIN} -> ${NS2_IPV4}"
[ -n "${NS1_IPV6:-}" ] && echo "      ns1.${DOMAIN} -> ${NS1_IPV6} (AAAA)"
[ -n "${NS2_IPV6:-}" ] && echo "      ns2.${DOMAIN} -> ${NS2_IPV6} (AAAA)"
echo "      ${DOMAIN} NS -> ns1.${DOMAIN}, ns2.${DOMAIN}"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo "    1. Set up glue records at your registrar (if not done)"
echo "    2. Deploy Phase 1 (infrastructure backbone):"
echo "       ansible-playbook -i inventory/hosts.yml site.yml --tags phase1 \\"
echo "         -e \"ansible_ssh_private_key_file=${SSH_KEY_PATH}\""
echo ""
echo "  See docs/BOOTSTRAP.md for the full deployment guide."
echo ""
