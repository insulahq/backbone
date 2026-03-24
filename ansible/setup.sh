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
    eval "$var_name=\"\$value\""
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
    eval "$var_name=\"\$value\""
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
command -v wg       >/dev/null 2>&1 || MISSING="$MISSING wireguard-tools(wg)"
command -v ansible  >/dev/null 2>&1 || MISSING="$MISSING ansible"
command -v python3  >/dev/null 2>&1 || MISSING="$MISSING python3"

if [ -n "$MISSING" ]; then
    error "Missing required tools:$MISSING"
    echo "  Install them first. See docs/BOOTSTRAP.md for instructions."
    exit 1
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
prompt NS1_LOCATION "ns1 location" "hetzner_falkenstein"
echo ""

echo -e "${BOLD}--- Server ns2 (Secondary) ---${NC}"
echo ""
prompt NS2_IPV4 "ns2 public IPv4 address"
prompt_optional NS2_IPV6 "ns2 public IPv6 address"
prompt NS2_LOCATION "ns2 location" "hetzner_helsinki"
echo ""

echo -e "${BOLD}--- SSH ---${NC}"
echo ""
prompt SSH_KEY_PATH "Path to bootstrapping SSH key" "$HOME/hosting-platform.key"
if [ ! -f "$SSH_KEY_PATH" ]; then
    warn "SSH key not found at $SSH_KEY_PATH — you'll need it for Phase 1"
fi
prompt SSH_PORT "SSH port" "22"
echo ""

echo -e "${BOLD}--- Backup (Hetzner Storagebox) ---${NC}"
echo ""
echo "  Leave empty to disable backups for now. You can enable later."
prompt_optional STORAGEBOX_USER "Storagebox subaccount user"
prompt_optional STORAGEBOX_HOST "Storagebox hostname"
if [ -n "$STORAGEBOX_USER" ] && [ -n "$STORAGEBOX_HOST" ]; then
    BACKUP_ENABLED="true"
    prompt_optional STORAGEBOX_PATH "Storagebox base path" "/backups"
    prompt_optional BACKUP_SSH_KEY "SSH key for Storagebox SFTP" "$SSH_KEY_PATH"
else
    BACKUP_ENABLED="false"
    STORAGEBOX_PATH="/backups"
    BACKUP_SSH_KEY="$SSH_KEY_PATH"
fi
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
ALLVARS_EOF

if [ "$BACKUP_ENABLED" = "true" ]; then
    cat >> group_vars/all.yml << BACKUP_EOF
backup_storagebox_user: ${STORAGEBOX_USER}
backup_storagebox_host: ${STORAGEBOX_HOST}
backup_storagebox_path: ${STORAGEBOX_PATH}
restic_ssh_key_src: "${BACKUP_SSH_KEY}"
BACKUP_EOF
fi

cat >> group_vars/all.yml << 'PATHS_EOF'

# Backup paths per server
ns1_backup_paths:
  - /opt/postgresql/backups
  - /opt/powerdns
  - /opt/netbird
  - /opt/zitadel
  - /opt/gatus
  - /opt/portainer
  - /etc/restic
  - /root/.ssh
  - /etc/wireguard

ns2_backup_paths:
  - /opt/postgresql/backups
  - /opt/powerdns
  - /opt/netbird
  - /opt/zitadel
  - /opt/gatus
  - /opt/portainer
  - /etc/restic
  - /root/.ssh
  - /etc/wireguard

# Alerting (leave empty — Gatus handles alerts)
alert_webhook_url: ""
PATHS_EOF

ok "group_vars/all.yml written"

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
echo "    2. Install Ansible collections:"
echo "       ansible-galaxy install -r requirements.yml"
echo "    3. Deploy Phase 1 (infrastructure backbone):"
echo "       ansible-playbook -i inventory/hosts.yml site.yml --tags phase1 \\"
echo "         -e \"ansible_ssh_private_key_file=${SSH_KEY_PATH}\""
echo ""
echo "  See docs/BOOTSTRAP.md for the full deployment guide."
echo ""
