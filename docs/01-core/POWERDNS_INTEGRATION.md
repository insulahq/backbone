# PowerDNS Integration Workflow

**Document Version:** 2.0  
**Last Updated:** 2026-03-01  
**Status:** FINAL — Ready for implementation  
**Audience:** Backend developers, DevOps engineers, platform architects

---

## Overview

**PowerDNS** is the DNS infrastructure component hosting one authoritative master per region on the control plane, with optional external slave DNS servers managed via AXFR and RNDC.

### Deployment Strategy

- **PHASE 1 (Single Region):** One PowerDNS master on control plane + optional external slaves
- **PHASE 2+ (Multi-Region):** One PowerDNS master per region, bi-directional replication via RNDC

### Three Customer DNS Modes

The platform supports customer choice in DNS management:

| Mode | Role | Use Case | Setup |
|------|------|----------|-------|
| **Primary (Full Delegation)** | Platform is authoritative | Customers delegate domain to `ns1.region.local` | Customer changes registrar nameservers |
| **CNAME (Platform DNS-Agnostic)** | Platform routes traffic, no DNS zone | Customers manage DNS elsewhere (GoDaddy, Route53, Cloudflare) | Customer creates CNAME `www → hosting.platform.com` |
| **Secondary (Backup DNS)** | Platform acts as secondary NS | Customers want redundancy without giving up control | Customer's primary NS stays authoritative, adds ns1.region.local as secondary |

### Core Capabilities

**PowerDNS** provides:
- **Single master per region** — One authoritative master on control plane
- **Record management** — API-driven A/AAAA/CNAME/MX/TXT/SPF/DKIM/ACME validation record updates
- **Zone transfer (AXFR)** — Replication to external slaves (PHASE 1) and regional replicas (PHASE 2+)
- **Remote management (RNDC)** — Configure external slaves, trigger zone syncs, manage inter-region replication
- **High availability** — External slaves optional; Kubernetes pod restart on failure (< 2 min RTO)
- **Performance** — Native caching, sub-millisecond response times
- **Security** — DNSSEC validation, AXFR IP whitelisting, RNDC key-based authentication

This document specifies:
- Architecture and deployment topology (master + external slaves)
- Single-master configuration (PHASE 1)
- Multi-region configuration (PHASE 2+)
- Zone provisioning workflow
- Record management (create/update/delete)
- RNDC external slave configuration
- API failure handling and recovery
- Monitoring and alerting

---

## Architecture Overview

### PHASE 1: Single Region (Current)

```
Frankfurt Cluster (Control Plane)
├── Kubernetes Control Plane Node
│   └── PowerDNS Master Pod
│       ├── ns1.de.local (Port 53, API 8081, RNDC 953)
│       └── PostgreSQL client (read-write)
│
├── PostgreSQL (shared cluster)
│   └── pdns schema (zones, records, domainmetadata)
│
└── Customer Domains
    └── Example: acme.com
        ├── Primary Master: ns1.de.local
        └── Secondary Slaves: ns2.external.com, ns3.external.com (optional)

External Slave DNS Servers (Already In Place)
├── ns2.external.com (separate VM, pulls via AXFR)
├── ns3.external.com (separate VM, pulls via AXFR)
└── nsN.external.com (admin-configurable via RNDC)
```

### PHASE 2+: Multi-Region

```
Frankfurt                  Strasbourg                Ashburn
(Control Plane)           (Control Plane)          (Control Plane)
├── ns1.de.local          ├── ns1.fr.local         ├── ns1.us.local
│   ├── MASTER            │   ├── MASTER           │   ├── MASTER
│   └── API writes        │   └── API writes       │   └── API writes
│
├── PostgreSQL            ├── PostgreSQL           ├── PostgreSQL
│   (primary)             │   (replica)            │   (replica)
│
└── RNDC ◄──────────────► RNDC ◄──────────────► RNDC
    (bi-directional zone transfer)

Zone Replication:
- ns1.de.local ← RNDC → ns1.fr.local ← RNDC → ns1.us.local
  (bidirectional AXFR)
- All masters are read-write for their customers' zones
- Other regions' zones are read-only (pulled via AXFR)
```

---

## PowerDNS Configuration

### PHASE 1: Master Server Configuration (Single Region)

**File:** `/etc/powerdns/pdns.conf` (ns1.de.local in Frankfurt)

```ini
# General
master=yes
slave=no
primary=yes
dnssec=yes
api=yes
api-key=SECURE_API_KEY_PHASE1
api-readonly=no
webserver=yes
webserver-port=8081
webserver-address=0.0.0.0
log-dns-queries=no
log-dns-results=no

# Database backend (PostgreSQL)
launch=gpgsql
gpgsql-host=postgres.k8s.local
gpgsql-port=5432
gpgsql-user=pdns
gpgsql-password=PDNS_DB_PASSWORD
gpgsql-dbname=powerdns
gpgsql-dnssec=yes
gpgsql-soa-edit-api=DEFAULT

# AXFR - Zone Transfer to External Slaves
notify-host=ns2.external.com
notify-host=ns3.external.com
allow-axfr-ips=ns2.external.com,ns3.external.com
allow-unsigned-axfr=no
axfr-master-only=yes

# RNDC - Remote Management for external slave configuration
local-port=953

# Performance
recursive-cache-ttl=10
query-cache-ttl=20
cache-ttl=20
dname-processing=yes
```

### LUA Records Configuration

LUA records are enabled on all PowerDNS masters to support apex domain ALIAS behaviour without CNAME-at-apex spec violations. This is required by the DNS Zone Template (see `DNS_ZONE_TEMPLATES.md` §Default Global Template).

Add to `pdns.conf` on all master nodes:

```ini
# Enable LUA records (required for apex ALIAS behaviour)
lua-records=yes

# Optional: restrict LUA record network calls to localhost only (security hardening)
# lua-records-exec-limit=1000   # max LUA instructions per record evaluation
```

**How apex LUA records work:**

When a resolver queries `customer.com IN A`, PowerDNS evaluates the LUA function `ifportup(80, {'<ingress-ip>'})` at query time. It checks whether port 80 is reachable on each IP in the list and returns only the healthy ones. This achieves the same result as ALIAS/ANAME (dynamic resolution mirroring `ingress.platform.com`) without requiring CNAME at the zone apex.

The DNS Ingress Controller manages `ingress.platform.com` A records. When a worker node joins or leaves, only `ingress.platform.com` is updated — all apex LUA records across all customer zones follow automatically because they evaluate against the live worker IPs at query time. No per-customer DNS update is required when the worker fleet changes.

**Negative impacts:** None significant at this scale. LUA evaluation adds ~1ms per query. The `ifportup()` check opens a TCP socket to port 80 — this adds latency only on the first evaluation; subsequent queries are served from PowerDNS's answer cache (TTL 60s). For very high query volumes (>10k apex queries/second), the socket checks can be disabled by using `pickrandom()` instead of `ifportup()` and relying on TCP timeout for failure detection.

**Alternative if LUA records are disabled:** Maintain a static A record set per customer apex, mirroring `ingress.platform.com`. The DNS Ingress Controller must then update every customer's apex A record whenever the worker fleet changes — this does not scale well beyond ~100 customers.

### PHASE 2: Multi-Region Master Configuration

**File:** `/etc/powerdns/pdns.conf` (ns1.fr.local in Strasbourg)

```ini
# General
master=yes
slave=yes
primary=yes
dnssec=yes
api=yes
api-key=SECURE_API_KEY_STRASBOURG
api-readonly=no
webserver=yes
webserver-port=8081
webserver-address=0.0.0.0

# Database backend (PostgreSQL replica)
launch=gpgsql
gpgsql-host=postgres-replica.fr.local
gpgsql-port=5432
gpgsql-user=pdns_replica
gpgsql-password=PDNS_REPLICA_PASSWORD
gpgsql-dbname=powerdns
gpgsql-dnssec=yes

# Supermaster - Pull zones from Frankfurt master
supermaster=ns1.de.local|ALLOW_AXFR

# AXFR - Zone Transfer to External Slaves
notify-host=ns2.external.com
notify-host=ns3.external.com
allow-axfr-ips=ns1.de.local,ns1.us.local,ns1.sg.local,ns2.external.com,ns3.external.com
allow-unsigned-axfr=no
axfr-master-only=yes

# RNDC - Remote Management
local-port=953

# Performance
recursive-cache-ttl=10
query-cache-ttl=20
cache-ttl=20
dname-processing=yes
```

### RNDC Configuration (Shared Across All Regions)

**File:** `/etc/rndc.conf` (same key in all regions for bi-directional communication)

```bash
key "rndc-key" {
  algorithm hmac-sha256;
  secret "base64_encoded_random_secret_key_generated_once";
};

options {
  default-key "rndc-key";
  default-server 127.0.0.1;
  default-port 953;
};

# Local server (current region)
server 127.0.0.1 {
  key "rndc-key";
};

# Remote servers (PHASE 2+, added as regions deploy)
server ns1.fr.local {
  key "rndc-key";
};

server ns1.us.local {
  key "rndc-key";
};

server ns1.sg.local {
  key "rndc-key";
};
```

**Generate RNDC Key (Once, at deployment):**
```bash
# Run this once, save output
rndc-confgen -a -b 512

# Output goes to /etc/rndc.key
# Copy this key to all regions' PowerDNS masters
```

### Customer DNS Modes

#### 1. Primary Mode (Platform Manages)

Customer delegates to platform nameservers. PowerDNS is authoritative.

```json
{
  "name": "acme.com.",
  "kind": "Native",
  "nameservers": [
    "ns1.de.local.",
    "ns2.external.com.",
    "ns3.external.com."
  ],
  "customer_id": "customer_001",
  "dns_mode": "primary"
}
```

#### 2. CNAME Mode (Customer-Managed DNS)

Customer manages DNS elsewhere; platform provides CNAME target.

```json
{
  "dns_mode": "cname",
  "cname_target": "www.acme.com.customer.hosting.platform.com.",
  "customer_id": "customer_001"
}
```

#### 3. Secondary Mode (Customer's Primary, Platform as Backup)

Platform pulls zones from customer's primary DNS authority.

```json
{
  "name": "acme.com.",
  "kind": "Slave",
  "masters": ["1.2.3.4"],  // Customer's primary NS IP
  "customer_id": "customer_001",
  "dns_mode": "secondary"
}
```

PowerDNS automatically pulls zone via AXFR every 3600 seconds, keeps in sync.

---

## Zone Provisioning Workflow

### 1. New Domain Registration (e.g., acme.com)

#### Step 1: Customer DNS Mode Selection

Admin selects how customer wants to manage DNS:

```json
// Option A: Primary Mode (Platform Manages)
{
  "dns_mode": "primary",
  "customer_id": "customer_001"
}

// Option B: CNAME Mode (Customer-Managed)
{
  "dns_mode": "cname",
  "customer_id": "customer_001"
}

// Option C: Secondary Mode (Backup DNS)
{
  "dns_mode": "secondary",
  "primary_nameserver": "1.2.3.4",  // Customer's primary NS IP
  "customer_id": "customer_001"
}
```

#### Step 2: Create Zone on Master

For PRIMARY mode, create zone on master (ns1.de.local in Frankfurt):

```http
POST /api/v1/zones HTTP/1.1
Host: ns1.de.local:8081
X-API-Key: SECURE_API_KEY
Content-Type: application/json

{
  "name": "acme.com.",
  "kind": "Native",
  "dnssec": true,
  "customer_id": "customer_001",
  "region": "frankfurt",
  "dns_mode": "primary"
}
```

**Note:** PowerDNS API requires trailing dot (`.`) on FQDNs.

#### Step 3: PowerDNS Response

```json
{
  "account": "",
  "dnssec": true,
  "id": "acme.com.",
  "kind": "Native",
  "name": "acme.com.",
  "nameservers": [
    "ns1.de.local.",
    "ns2.external.com.",
    "ns3.external.com."
  ],
  "serial": 2026030101,
  "soa_edit": "AUTO"
}
```

**Database State:**
```sql
-- Zone created in PowerDNS
INSERT INTO zones (name, type, account, customer_id, dns_mode, region, changed_by)
VALUES ('acme.com.', 'NATIVE', 'customer_001', 'customer_001', 'primary', 'frankfurt', 'admin@example.com');

-- SOA record automatically created
INSERT INTO records (zone_id, name, type, ttl, content, change_date)
VALUES (
  (SELECT id FROM zones WHERE name='acme.com.'),
  'acme.com.',
  'SOA',
  3600,
  'ns1.de.local. hostmaster.acme.com. 2026030101 10800 3600 604800 3600',
  NOW()
);

-- NS records created for each nameserver
INSERT INTO records (zone_id, name, type, ttl, content, change_date)
VALUES
  ((SELECT id FROM zones WHERE name='acme.com.'), 'acme.com.', 'NS', 3600, 'ns1.de.local.', NOW()),
  ((SELECT id FROM zones WHERE name='acme.com.'), 'acme.com.', 'NS', 3600, 'ns2.external.com.', NOW()),
  ((SELECT id FROM zones WHERE name='acme.com.'), 'acme.com.', 'NS', 3600, 'ns3.external.com.', NOW());
```

#### Step 4: Apply DNS Zone Template

Immediately after zone creation (SOA + NS only), the **global DNS zone template** is applied. This populates all standard records — web, email, autodiscovery, and security — in a single batch request to PowerDNS.

**Pre-step: Generate DKIM Keypair**

Before applying the template, a DKIM keypair is generated for the domain:

```bash
opendkim-genkey -b 2048 -d acme.com -s default -D /etc/opendkim/keys/acme.com/
# Private key → /etc/opendkim/keys/acme.com/default.private  (OpenDKIM signing)
# Public key  → stored as domain.dkim_public_key for template variable resolution
```

**Template Application**

The Management API resolves all `{{variable}}` placeholders and POSTs the full record set to PowerDNS via a single batch PATCH:

```bash
PATCH /api/v1/zones/acme.com.
Host: ns1.de.local:8081
X-API-Key: SECURE_API_KEY

# Records applied (19 total):
#  A, AAAA          — apex → platform ingress IP
#  CNAME www        — www → apex
#  MX               — inbound mail → platform mail server
#  TXT SPF          — v=spf1 include:mail.platform.com ~all
#  TXT DKIM         — default._domainkey → generated public key
#  TXT DMARC        — _dmarc → p=none reporting policy
#  CNAME webmail    — webmail.acme.com → webmail.platform.com
#  CNAME mail       — mail.acme.com → mail.platform.com
#  CNAME autodiscover — autodiscover.acme.com → mail.platform.com
#  CNAME autoconfig   — autoconfig.acme.com → mail.platform.com
#  SRV _imaps._tcp  — IMAP over TLS (port 993, RFC 6186)
#  SRV _imap._tcp   — IMAP + STARTTLS (port 143, RFC 6186)
#  SRV _submissions._tcp — SMTP implicit TLS (port 465, RFC 8314)
#  SRV _submission._tcp  — SMTP + STARTTLS (port 587, RFC 6186)
#  SRV _autodiscover._tcp — Microsoft Autodiscover (port 443)
#  CAA issue / issuewild / iodef — Let's Encrypt only
```

Per-domain template exclusions are respected — any excluded record types are skipped.

See **`DNS_ZONE_TEMPLATES.md`** for full template specification, variable reference, and complete PowerDNS batch request.

> **Note:** Template application is skipped for CNAME and Secondary DNS modes. In those modes, DNS is managed externally and the platform does not own the zone records.

#### Step 5: Propagate to External Slaves

PowerDNS automatically notifies configured external slaves:

```bash
# ns1.de.local notifies ns2.external.com and ns3.external.com
# External slaves pull full zone via AXFR within 5 minutes

# Verification:
dig @ns1.de.local acme.com SOA       # Should return zone (master)
dig @ns2.external.com acme.com SOA   # Should return zone (after AXFR, ~5min)
dig @ns3.external.com acme.com SOA   # Should return zone (after AXFR, ~5min)
```

#### Step 6: Verify Zone Propagation (Before Activating)

```python
# Management API waits for all nameservers to have zone before returning success
def verify_zone_propagation(zone_name, nameservers, timeout=300):
    import dns.resolver
    import time
    
    start_time = time.time()
    while time.time() - start_time < timeout:
        propagated = []
        
        for ns in nameservers:
            try:
                query = dns.resolver.query(zone_name, "SOA", nameserver=ns)
                propagated.append(ns)
            except:
                pass
        
        if len(propagated) == len(nameservers):
            return True  # All nameservers have zone
        
        time.sleep(5)
    
    return False  # Timeout

# Example: ns1.de.local, ns2.external.com, ns3.external.com
if verify_zone_propagation("acme.com.", ["ns1.de.local", "ns2.external.com", "ns3.external.com"]):
    response = {"status": "active", "nameservers": [...]}
else:
    response = {"status": "pending", "message": "Waiting for DNS propagation to all slaves"}
```

---

### External Slave Configuration (PHASE 1)

Admins can optionally configure external slave DNS servers via the Management API. These are configured via RNDC (Remote Name Daemon Control).

#### Configure External Slaves via API

```http
PUT /api/v1/settings/dns/external-slaves HTTP/1.1
Host: api.platform.com
Authorization: Bearer ADMIN_TOKEN
Content-Type: application/json

{
  "enabled": true,
  "slaves": [
    {
      "hostname": "ns2.example.com",
      "ip": "203.0.113.10",
      "enabled": true
    },
    {
      "hostname": "ns3.example.com",
      "ip": "203.0.113.11",
      "enabled": true
    }
  ]
}
```

#### RNDC Implementation

Management API applies configuration via RNDC:

```bash
#!/bin/bash
# Called by Management API when external slaves updated

RNDC_KEY_FILE="/etc/rndc.conf"
POWERDNS_HOST="ns1.de.local"
POWERDNS_PORT="953"

# Update PowerDNS configuration
rndc -c $RNDC_KEY_FILE -s $POWERDNS_HOST -p $POWERDNS_PORT reload

# Force SOA notify to slaves (triggers AXFR)
rndc -c $RNDC_KEY_FILE -s $POWERDNS_HOST -p $POWERDNS_PORT notify acme.com.

# Verify slave has updated zone
dig @ns2.example.com acme.com SOA
dig @ns3.example.com acme.com SOA
```

#### RNDC Response

```json
{
  "success": true,
  "message": "External slaves configured and updated",
  "slaves": [
    {
      "hostname": "ns2.example.com",
      "ip": "203.0.113.10",
      "status": "active",
      "last_axfr": "2026-03-01T10:05:00Z",
      "zone_count": 45
    },
    {
      "hostname": "ns3.example.com",
      "ip": "203.0.113.11",
      "status": "active",
      "last_axfr": "2026-03-01T10:05:15Z",
      "zone_count": 45
    }
  ]
}
```

---

### 2. DNS Record Editing - Full CRUD Access (Primary Region)

**Who Can Edit DNS Records:**

| Role | Access | Scope |
|------|--------|-------|
| **Customer** | Full CRUD (Create, Read, Update, Delete) | Only their own domains, in primary region |
| **Admin** | Full CRUD (Create, Read, Update, Delete) | Any customer's domains, in primary region |
| **Secondary Region** | Read-only (no editing) | Can view zones, cannot make changes |

**Endpoint Authorization:**
```javascript
// Management API permission check (PHASE 2+)

// Customer editing their own domain
if (user.role === "customer" && user.customerId !== zoneMaster.customerId) {
  return 403 "Cannot edit other customers' domains"
}

// Customer/Admin editing in secondary region
if (user.primaryRegion !== requestRegion) {
  return 403 "Cannot edit DNS for customers in other regions"
}

// Admin can edit any customer in their region
if (user.role === "admin") {
  // Allow (any customer in same region)
}
```

**Full Record Type Support:**
- **A** - IPv4 address
- **AAAA** - IPv6 address
- **CNAME** - Alias
- **MX** - Mail server (with priority)
- **TXT** - Text records (SPF, DKIM, verification)
- **NS** - Nameserver (for delegated subdomains)
- **SRV** - Service records
- **CAA** - Certificate Authority Authorization
- **And all other standard DNS record types**

---

### 3. Create/Update/Delete DNS Records (Full CRUD Examples)

#### Create A Record for acme.com → 192.0.2.15

```http
PATCH /api/v1/zones/acme.com. HTTP/1.1
Host: ns1.k8s.local:8081
X-API-Key: YOUR_API_KEY
Content-Type: application/json

{
  "rrsets": [
    {
      "name": "acme.com.",
      "type": "A",
      "ttl": 300,
      "changetype": "REPLACE",
      "records": [
        {
          "content": "192.0.2.15",
          "disabled": false
        }
      ]
    }
  ]
}
```

**Response (204 No Content)** — Record updated

#### Create CNAME for www.acme.com → acme.com

```json
{
  "rrsets": [
    {
      "name": "www.acme.com.",
      "type": "CNAME",
      "ttl": 300,
      "changetype": "REPLACE",
      "records": [
        {
          "content": "acme.com.",
          "disabled": false
        }
      ]
    }
  ]
}
```

#### Create MX Record for mail

```json
{
  "rrsets": [
    {
      "name": "acme.com.",
      "type": "MX",
      "ttl": 3600,
      "changetype": "REPLACE",
      "records": [
        {
          "content": "10 mail.acme.com.",
          "disabled": false
        }
      ]
    }
  ]
}
```

#### Create TXT Record for SPF Validation

```json
{
  "rrsets": [
    {
      "name": "acme.com.",
      "type": "TXT",
      "ttl": 3600,
      "changetype": "REPLACE",
      "records": [
        {
          "content": "\"v=spf1 include:acme.com ~all\"",
          "disabled": false
        }
      ]
    }
  ]
}
```

#### Create ACME Challenge Record (for Let's Encrypt)

```json
{
  "rrsets": [
    {
      "name": "_acme-challenge.acme.com.",
      "type": "TXT",
      "ttl": 60,
      "changetype": "REPLACE",
      "records": [
        {
          "content": "\"ABC123DEF456GHI789JKL...\"",
          "disabled": false
        }
      ]
    }
  ]
}
```

**Verification:**
```bash
# Check record exists
dig @ns1.k8s.local acme.com A +short
# Output: 192.0.2.15

# Check CNAME
dig @ns1.k8s.local www.acme.com CNAME +short
# Output: acme.com.

# Check propagation to slaves
dig @ns2.k8s.local acme.com A +short
# Output: 192.0.2.15 (after 5min)
```

---

## DNSSEC Support (Optional Per Domain)

### DNSSEC Overview

DNSSEC cryptographically signs DNS records. PowerDNS **automatically manages** DNSSEC when enabled:
- Generates Key Signing Key (KSK) and Zone Signing Key (ZSK)
- Signs all records with RRSIG
- Generates NSEC/NSEC3 records for authenticated denial of existence
- Automatic key rotation (ZSK every 30 days, KSK every 365 days)

### Enable DNSSEC for Zone

**Management API enables DNSSEC:**

```python
# Python example: Enable DNSSEC on zone
import requests

def enable_dnssec(zone_name, api_key):
    url = f"http://ns1.de.local:8081/api/v1/zones/{zone_name}/dnssec"
    
    payload = {
        "dnssec": True,
        "nsec3param": "1 0 1 abcd1234"  # Optional: NSEC3 instead of NSEC
    }
    
    headers = {"X-API-Key": api_key}
    
    response = requests.patch(url, json=payload, headers=headers)
    
    if response.status_code == 204:
        print(f"DNSSEC enabled for {zone_name}")
        return True
    else:
        print(f"Failed to enable DNSSEC: {response.text}")
        return False
```

### Get DNSSEC Keys and DS Records

**Retrieve keys for DS record publishing:**

```bash
# Get all DNSSEC keys for zone
curl -H "X-API-Key: $API_KEY" \
  http://ns1.de.local:8081/api/v1/zones/acme.com./dnssec

# Response: Keys with public key material and DS digest
{
  "zone": "acme.com.",
  "dnssec": true,
  "keys": [
    {
      "id": "12345",
      "flags": "257",      // KSK
      "algorithm": "13",   // ECDSAP256SHA256
      "content": "AwEAA...",  // Public key material
      "keytype": "ksk"
    },
    {
      "id": "12346",
      "flags": "256",      // ZSK
      "algorithm": "13",
      "content": "AwEAA...",
      "keytype": "zsk"
    }
  ],
  "ds_records": [
    {
      "keytag": 12345,
      "algorithm": 13,
      "digest_type": 2,    // SHA256
      "digest": "ABC123DEF456..."
    }
  ]
}
```

### DS Record Publishing

**Customer publishes DS record to parent zone (registrar):**

```
1. Customer enables DNSSEC via API
2. System returns DS record: keytag=12345, algorithm=13, digest=ABC123...
3. Customer logs into domain registrar (GoDaddy, Namecheap, etc.)
4. Customer adds DS record to DNSSEC settings
5. Platform validates DNSSEC chain (resolvers can now validate signatures)
```

### Automatic Key Rotation

**PowerDNS automatically rotates keys on schedule:**

```ini
# In pdns.conf
gpgsql-dnssec=yes
dnssec=yes

# Automatic rotation (default values)
# ZSK rotated every 30 days
# KSK rotated every 365 days
# No admin action required

# Optional: Configure rotation schedule
dnssec-key-cache-ttl=60
```

**Rotation Process:**
1. Pre-publish: New key published in DNSKEY records (1 week)
2. Publish: Key activated and starts signing records (1 week)
3. Activate: Records signed with new key (1 week)
4. Remove: Old key removed from zone (after TTL expires)

### DNSSEC Validation

**Test DNSSEC validation:**

```bash
# Query with DNSSEC validation
dig @ns1.de.local acme.com +dnssec

# Expected response flags:
# - ad (Authenticated Data) = DNSSEC validated
# - RRSIG records in response = zone is signed

# Validate DS chain (from registrar to zone)
dig @ns1.de.local acme.com DS +dnssec
# Should return DS record for KSK

# Check DNSKEY records
dig @ns1.de.local acme.com DNSKEY +dnssec
# Should return both KSK (flag 257) and ZSK (flag 256)
```

### Disable DNSSEC

**Management API disables DNSSEC:**

```python
def disable_dnssec(zone_name, api_key):
    url = f"http://ns1.de.local:8081/api/v1/zones/{zone_name}/dnssec"
    
    payload = {"dnssec": False}
    headers = {"X-API-Key": api_key}
    
    response = requests.patch(url, json=payload, headers=headers)
    
    if response.status_code == 204:
        print(f"DNSSEC disabled for {zone_name}")
        print("Remove DS record from parent zone within 24 hours")
        return True
```

### DNSSEC Monitoring

**Prometheus metrics for DNSSEC:**

```prometheus
# DNSSEC signed zones
pdns_dnssec_zones_signed{zone="acme.com"}

# DNSSEC keys (KSK/ZSK)
pdns_dnssec_keys_total{type="ksk|zsk"}

# Days until key rotation
pdns_dnssec_key_days_to_rotation{key_id="12345"}

# DNSSEC validation failures
pdns_dnssec_validation_failures_total

# DS records published in parent zone
pdns_dnssec_ds_published{zone="acme.com"}
```

**Alerts for DNSSEC:**

```yaml
# Alert: DS record missing in parent zone (prevents DNSSEC validation)
- alert: DNSSECDSRecordMissing
  expr: pdns_dnssec_ds_published == 0
  for: 24h
  annotations:
    summary: "DS record not found in parent zone for {{ $labels.zone }}"
    action: "Customer must add DS record to registrar"

# Alert: Key rotation due in 7 days
- alert: DNSSECKeyRotationDue
  expr: pdns_dnssec_key_days_to_rotation < 7
  annotations:
    summary: "DNSSEC key {{ $labels.key_id }} rotates in {{ $value }} days"

# Alert: Zone DNSSEC validation failed
- alert: DNSSECValidationFailed
  expr: rate(pdns_dnssec_validation_failures_total[5m]) > 0
  for: 5m
  annotations:
    summary: "DNSSEC validation failing for {{ $labels.zone }}"
```

---

## Record Management Operations (Full CRUD)

### 4a. Update Record (Change IP Address)

**Customer or Admin updating a record:**

```http
PATCH /api/v1/customers/{customerId}/domains/acme.com/records HTTP/1.1
Host: api.platform.com
Authorization: Bearer USER_TOKEN
Content-Type: application/json

{
  "rrsets": [
    {
      "name": "acme.com.",
      "type": "A",
      "ttl": 300,
      "changetype": "REPLACE",
      "records": [
        {
          "content": "192.0.2.20",
          "disabled": false
        }
      ]
    }
  ]
}
```

**Response (204 No Content)** — Record updated successfully

---

### 4b. Delete Record

**Customer or Admin removing a record:**

```http
PATCH /api/v1/customers/{customerId}/domains/acme.com/records HTTP/1.1
Host: api.platform.com
Authorization: Bearer USER_TOKEN
Content-Type: application/json

{
  "rrsets": [
    {
      "name": "old-subdomain.acme.com.",
      "type": "CNAME",
      "changetype": "DELETE"
    }
  ]
}
```

**Response (204 No Content)** — Record deleted successfully

---

### 4c. Batch Operations (Multiple Records at Once)

**Customer or Admin updating multiple records in one request:**

```http
PATCH /api/v1/customers/{customerId}/domains/acme.com/records HTTP/1.1
Host: api.platform.com
Authorization: Bearer USER_TOKEN
Content-Type: application/json

{
  "rrsets": [
    {
      "name": "acme.com.",
      "type": "A",
      "ttl": 300,
      "changetype": "REPLACE",
      "records": [
        {"content": "192.0.2.15", "disabled": false}
      ]
    },
    {
      "name": "www.acme.com.",
      "type": "CNAME",
      "ttl": 300,
      "changetype": "REPLACE",
      "records": [
        {"content": "acme.com.", "disabled": false}
      ]
    },
    {
      "name": "mail.acme.com.",
      "type": "A",
      "ttl": 300,
      "changetype": "REPLACE",
      "records": [
        {"content": "192.0.2.16", "disabled": false}
      ]
    },
    {
      "name": "acme.com.",
      "type": "MX",
      "ttl": 3600,
      "changetype": "REPLACE",
      "records": [
        {"content": "10 mail.acme.com.", "disabled": false}
      ]
    },
    {
      "name": "default._domainkey.acme.com.",
      "type": "TXT",
      "ttl": 3600,
      "changetype": "REPLACE",
      "records": [
        {"content": "\"v=DKIM1; k=rsa; p=MIGfMA0GCSq...\"", "disabled": false}
      ]
    }
  ]
}
```

**Response (204 No Content)** — All records updated successfully in single transaction

---

### 4d. List All Records for a Domain

**Customer or Admin viewing all DNS records:**

```http
GET /api/v1/customers/{customerId}/domains/acme.com/records HTTP/1.1
Host: api.platform.com
Authorization: Bearer USER_TOKEN
```

**Response:**
```json
{
  "zone": "acme.com.",
  "records": [
    {
      "name": "acme.com.",
      "type": "A",
      "ttl": 300,
      "content": "192.0.2.15",
      "created_at": "2026-03-01T10:00:00Z",
      "updated_at": "2026-03-01T10:00:00Z"
    },
    {
      "name": "www.acme.com.",
      "type": "CNAME",
      "ttl": 300,
      "content": "acme.com.",
      "created_at": "2026-03-01T10:05:00Z",
      "updated_at": "2026-03-01T10:05:00Z"
    },
    {
      "name": "acme.com.",
      "type": "MX",
      "ttl": 3600,
      "content": "10 mail.acme.com.",
      "created_at": "2026-03-01T10:10:00Z",
      "updated_at": "2026-03-01T10:10:00Z"
    }
  ]
}
```

---

### 4e. Get Single Record Type

**Customer or Admin querying specific record:**

```http
GET /api/v1/customers/{customerId}/domains/acme.com/records?type=MX HTTP/1.1
Host: api.platform.com
Authorization: Bearer USER_TOKEN
```

**Response:**
```json
{
  "zone": "acme.com.",
  "recordType": "MX",
  "records": [
    {
      "name": "acme.com.",
      "type": "MX",
      "ttl": 3600,
      "content": "10 mail.acme.com.",
      "priority": 10
    }
  ]
}
```

---

## Error Handling and Recovery

### Scenario 1: API Timeout (Connection Refused)

**Problem:**
```
POST /api/v1/zones failed: Connection refused
Error: Cannot reach ns1.k8s.local:8081
```

**Detection:**
- API call times out after 5 seconds
- HTTP 500 or connection reset

**Recovery Steps:**

1. **Retry with exponential backoff**
   ```python
   def create_zone_with_retry(zone_name, max_retries=5):
       for attempt in range(max_retries):
           try:
               response = pdns_api.post(f"/zones/{zone_name}", ...)
               return response
           except ConnectionError:
               wait_time = 2 ** attempt  # 1, 2, 4, 8, 16 seconds
               logger.warning(f"API retry {attempt+1}/{max_retries} in {wait_time}s")
               time.sleep(wait_time)
       
       # After all retries fail, escalate
       raise ZoneProvisioningFailed(f"Cannot create zone after {max_retries} attempts")
   ```

2. **Check PowerDNS health**
   ```bash
   # Check if master is responding
   curl -H "X-API-Key: $API_KEY" http://ns1.k8s.local:8081/api/v1/servers/localhost
   # If failed, check logs:
   kubectl logs -f statefulset/powerdns-master
   ```

3. **Failover to slave (read-only mode)**
   ```python
   # If master is down, can query slave for zone records
   # But CANNOT write new records
   # Writes must queue until master recovers
   
   zone_records = pdns_api.get(f"/zones/{zone_name}", server="ns2.k8s.local")
   # Returns: 403 Forbidden (slave is read-only)
   
   # Queue write operation for retry
   db.queue_zone_operation(
       zone_name=zone_name,
       operation="CREATE",
       records=[...],
       retry_count=0
   )
   ```

4. **Alert operations team**
   ```python
   alerting.send(
       level="CRITICAL",
       title="PowerDNS Master Unreachable",
       message=f"Cannot reach ns1.k8s.local:8081 after 5 retries. Zone provisioning blocked.",
       tags=["powerdns", "infrastructure"]
   )
   ```

---

### Scenario 2: Zone Already Exists (Conflict)

**Problem:**
```
POST /api/v1/zones failed: 422 Unprocessable Entity
Error: {
  "error": "Conflict",
  "error_details": "Zone acme.com. already exists"
}
```

**Detection:**
- HTTP 409 or 422 response
- Error contains "already exists"

**Recovery:**
```python
def create_zone_idempotent(zone_name, records):
    try:
        # Try to create zone
        pdns_api.post(f"/zones", {"name": zone_name, ...})
    except ZoneAlreadyExists:
        # Zone exists, verify it's ours
        existing_zone = pdns_api.get(f"/zones/{zone_name}")
        
        if existing_zone.tags.get("customer_id") == current_customer_id:
            # Zone belongs to same customer, it's idempotent
            logger.info(f"Zone {zone_name} already exists for customer")
            return existing_zone
        else:
            # Zone belongs to different customer, error
            raise ZoneNameTaken(f"Zone {zone_name} is already registered")
```

---

### Scenario 3: Database Replication Lag

**Problem:**
```
Zone created on master ns1, but slave ns2 doesn't have records yet
Client updated nameservers to ns1/ns2/ns3, but ns2 is stale
DNS queries to ns2 return NXDOMAIN (no records found)
```

**Root Cause:**
- AXFR transfer takes > 5 minutes
- Database replication lag between master and slaves

**Prevention:**
```python
def verify_zone_propagation(zone_name, nameservers=["ns1", "ns2", "ns3"], timeout=60):
    """
    Wait for zone to propagate to all nameservers before returning to customer
    """
    import time
    import dns.resolver
    
    start_time = time.time()
    
    while time.time() - start_time < timeout:
        propagated = []
        
        for nameserver in nameservers:
            try:
                # Query each nameserver directly
                query = dns.resolver.query(
                    zone_name,
                    "SOA",
                    nameserver=f"{nameserver}.k8s.local"
                )
                propagated.append(nameserver)
                logger.debug(f"Zone found on {nameserver}")
            except dns.resolver.NXDOMAIN:
                logger.debug(f"Zone NOT yet on {nameserver}, retrying...")
            except Exception as e:
                logger.error(f"Error querying {nameserver}: {e}")
        
        # All nameservers have zone
        if len(propagated) == len(nameservers):
            return True
        
        # Wait before retry
        time.sleep(5)
    
    # Timeout reached
    logger.error(f"Zone {zone_name} did not propagate to all nameservers within {timeout}s")
    return False
```

**Response to Customer:**
```json
{
  "success": true,
  "data": {
    "zone_name": "acme.com",
    "status": "provisioning",
    "nameservers": ["ns1.k8s.local", "ns2.k8s.local", "ns3.k8s.local"],
    "propagation": {
      "ns1": "active",
      "ns2": "pending",  // Will check again in 5 minutes
      "ns3": "pending"
    },
    "message": "Please update your domain registrar to use the nameservers above. Propagation may take 5-30 minutes worldwide."
  }
}
```

---

### Scenario 4: API Rate Limiting

**Problem:**
```
POST /api/v1/zones failed: 429 Too Many Requests
Error: {
  "error": "Rate limit exceeded",
  "retry_after": 60
}
```

**Cause:**
- Too many zone provisioning requests in rapid succession
- PowerDNS API rate limit: 100 requests/minute

**Prevention:**
```python
from ratelimit import RateLimiter

# Rate limiter: 10 zones per 10 seconds (600 per minute)
zone_rate_limiter = RateLimiter(max_calls=10, time_period=10)

def create_zone_with_rate_limit(zone_name, ...):
    zone_rate_limiter.try_acquire()  # Raises if rate limited
    return pdns_api.post(f"/zones", ...)
```

**Graceful Degradation:**
```python
def queue_zone_creation_if_rate_limited(zone_name, records):
    try:
        return create_zone_with_rate_limit(zone_name, records)
    except RateLimitExceeded as e:
        # Queue for async processing
        job = celery_app.send_task(
            'tasks.create_zone_async',
            args=[zone_name, records],
            eta=timezone.now() + timedelta(seconds=e.retry_after)
        )
        
        return {
            "status": "queued",
            "job_id": job.id,
            "estimated_wait_seconds": e.retry_after
        }
```

---

## Monitoring and Alerting

### Prometheus Metrics

```prometheus
# Master health
pdns_master_up{region="frankfurt"}

# API response time
pdns_api_response_time_ms

# API errors (by type)
pdns_api_errors_total{error_type="timeout|conflict|rate_limit|internal"}

# Zone count
pdns_zones_total{region="frankfurt"}

# Record count
pdns_records_total{region="frankfurt", type="A|CNAME|MX|TXT|NS|SOA"}

# External slave health (PHASE 1)
pdns_external_slave_healthy{slave="ns2.example.com|ns3.example.com"}

# AXFR transfer success rate (to external slaves)
pdns_axfr_success_rate{slave="ns2.example.com"}

# Zone freshness on external slaves (seconds lag behind master)
pdns_slave_zone_lag_seconds{slave="ns2.example.com", zone="acme.com."}
```

### Alerting Rules

```yaml
groups:
  - name: powerdns
    rules:
      # Master pod down
      - alert: PowerDNSMasterDown
        expr: pdns_master_up{region="frankfurt"} == 0
        for: 1m
        annotations:
          summary: "PowerDNS master pod is down in {{ $labels.region }}"
          action: "kubectl logs -f statefulset/powerdns-master-0"
      
      # API latency high
      - alert: PowerDNSAPILatencyHigh
        expr: pdns_api_response_time_ms > 1000  # > 1 second
        for: 5m
        annotations:
          summary: "PowerDNS API response time > 1 second"
      
      # API errors spiking
      - alert: PowerDNSAPIErrors
        expr: rate(pdns_api_errors_total[5m]) > 0.1  # > 0.1 errors/sec
        for: 2m
        annotations:
          summary: "PowerDNS API errors spiking"
      
      # External slave unreachable (PHASE 1)
      - alert: PowerDNSExternalSlaveDown
        expr: pdns_external_slave_healthy{slave=~"ns.*"} == 0
        for: 5m
        annotations:
          summary: "External DNS slave {{ $labels.slave }} is unreachable"
          action: "Check slave server connectivity"
      
      # AXFR transfers failing
      - alert: PowerDNSAXFRFailure
        expr: rate(pdns_axfr_success_rate{slave=~"ns.*"}[5m]) < 0.5  # < 50% success
        for: 10m
        annotations:
          summary: "AXFR transfers failing to {{ $labels.slave }}"
          action: "Check slave configuration, verify RNDC connectivity"
      
      # Slave zone lag (PHASE 2+)
      - alert: PowerDNSSlaveZoneLagHigh
        expr: pdns_slave_zone_lag_seconds > 300  # > 5 minutes
        for: 10m
        annotations:
          summary: "Zone {{ $labels.zone }} on {{ $labels.slave }} is > 5 minutes behind master"
```

### Health Check Endpoint

```bash
# Check master status (Frankfurt)
curl -s -H "X-API-Key: $API_KEY" http://ns1.de.local:8081/api/v1/servers/localhost | jq '.id, .zone_count, .dnssec'

# List all zones
curl -s -H "X-API-Key: $API_KEY" http://ns1.de.local:8081/api/v1/zones | jq length

# Check external slave zone count (PHASE 1)
dig @ns2.external.com . AXFR | grep -c "^;" 

# Check RNDC connectivity (PHASE 2+)
rndc -c /etc/rndc.conf -s ns1.fr.local status
```

---

## Implementation Checklist

### PHASE 1: Single Region (Weeks 1-4)

#### Week 1: Infrastructure Setup
- [ ] Deploy PowerDNS master pod on Frankfurt control plane (ns1.de.local)
- [ ] Create PostgreSQL backend (pdns schema)
- [ ] Configure PowerDNS API (port 8081, API key)
- [ ] Configure RNDC (port 953, shared key)
- [ ] Configure DNSSEC keys and validation

#### Week 2: Management API
- [ ] Implement zone creation endpoint (Primary/CNAME/Secondary modes)
- [ ] Implement DNS record CRUD endpoints (A, CNAME, MX, TXT, etc.)
- [ ] Implement zone deletion endpoint
- [ ] Add DNS status check endpoint
- [ ] Add zone propagation verification

#### Week 3: External Slave Configuration (PHASE 1 optional)
- [ ] Implement external slave configuration API endpoint
- [ ] Add RNDC command execution for slave updates
- [ ] Implement AXFR monitoring (zone freshness check)
- [ ] Add alerting for slave failures
- [ ] Test AXFR transfers to external slaves

#### Week 4: Testing & Validation
- [ ] Integration tests: zone CRUD operations
- [ ] Test zone propagation to external slaves
- [ ] Test DNS query performance
- [ ] Test API failure handling and recovery
- [ ] Load test: 100+ domains, 1000+ records
- [ ] Manual failover test: restart ns1.de.local pod

### PHASE 2: Multi-Region (Weeks 1-6, after PHASE 1 stable)

#### Week 1: Strasbourg Infrastructure
- [ ] Deploy Kubernetes cluster in Strasbourg
- [ ] Deploy PowerDNS master on Strasbourg control plane (ns1.fr.local)
- [ ] Deploy PostgreSQL replica in Strasbourg
- [ ] Configure pglogical replication (Frankfurt ← → Strasbourg)
- [ ] Configure RNDC bi-directional communication

#### Week 2: Zone Replication
- [ ] Configure AXFR from Frankfurt → Strasbourg
- [ ] Configure AXFR from Strasbourg → external slaves
- [ ] Test zone replication latency (target: < 5 minutes)
- [ ] Test zone convergence after replication break
- [ ] Implement zone sync monitoring

#### Week 3: API Region Validation
- [ ] Implement customer region lookup in DNS API
- [ ] Add region validation: customer's region can edit DNS
- [ ] Add region validation: other regions read-only
- [ ] Test: Edit zone from correct region succeeds
- [ ] Test: Edit zone from wrong region returns 403
- [ ] Add audit logging for DNS changes (user/region/timestamp)

#### Week 4: Customer Migration
- [ ] Implement DNS zone migration workflow
- [ ] Test: Migrate customer Frankfurt → Strasbourg
- [ ] Verify: Nameservers updated (ns1.de → ns1.fr primary)
- [ ] Verify: Old region becomes read-only slave
- [ ] Verify: No DNS downtime during migration

#### Week 5: Multi-Region Failover
- [ ] Test: ns1.de.local pod down → Strasbourg zone read-only
- [ ] Test: Frankfurt region down → Strasbourg customers can edit
- [ ] Test: PostgreSQL replication break → manual recovery
- [ ] Test: RNDC key rotation across regions
- [ ] Load test: 1000+ domains across 2 regions

#### Week 6: Testing & Validation
- [ ] Integration tests: Multi-region DNS operations
- [ ] Chaos testing: Random master failures, zone transfers
- [ ] Performance test: API latency across regions
- [ ] DNS query test: All nameservers respond correctly
- [ ] Validate customer nameserver updates after migration

### Documentation & DNSSEC (All Phases)
- [ ] Write PowerDNS troubleshooting runbook
- [ ] Write zone recovery procedures
- [ ] Write RNDC management procedures
- [ ] Write DNSSEC key rotation procedures
- [ ] Write customer DNS mode selection guide
- [ ] Write region failover procedures (PHASE 2+)
- [ ] Implement DNSSEC enable/disable API endpoints
- [ ] Implement DNSSEC status check endpoint
- [ ] Implement key rotation endpoints (ZSK, KSK)
- [ ] Document DS record publishing process
- [ ] Create DNSSEC customer guide (how to publish DS record)
- [ ] Add DNSSEC monitoring to dashboard
- [ ] Test DNSSEC validation with dig/delv tools
- [ ] Test DS record chain validation

---

## Troubleshooting Guide

### Issue: PowerDNS Master Pod Down

```bash
# 1. Check pod status
kubectl get pod -l app=powerdns-master

# 2. Check logs
kubectl logs -f statefulset/powerdns-master

# 3. Check database connectivity
kubectl exec -it powerdns-master-0 -- psql -U pdns -d powerdns -c "SELECT COUNT(*) FROM zones"

# 4. Restart master (Kubernetes will auto-restart on failure)
kubectl delete pod powerdns-master-0
# Pod restarts automatically, zones loaded from database

# 5. Verify master is healthy
curl -s -H "X-API-Key: $API_KEY" http://ns1.de.local:8081/api/v1/servers/localhost | jq '.dnssec'
```

### Issue: Zone Not Resolving

```bash
# 1. Check zone exists on master
curl -s -H "X-API-Key: $API_KEY" http://ns1.de.local:8081/api/v1/zones/acme.com. | jq .

# 2. Query master directly
dig @ns1.de.local acme.com A

# 3. Query external slave (PHASE 1)
dig @ns2.external.com acme.com A

# 4. Check zone in database
kubectl exec -it postgres-primary -- psql -U pdns -d powerdns -c "SELECT name, type FROM zones WHERE name='acme.com.'"

# 5. Check PowerDNS logs for errors
kubectl logs -f statefulset/powerdns-master | tail -50
```

### Issue: External Slave Not Syncing (PHASE 1)

```bash
# 1. Verify AXFR is configured
curl -s -H "X-API-Key: $API_KEY" http://ns1.de.local:8081/api/v1/settings/dns/external-slaves

# 2. Check slave IP is in allow-axfr-ips
kubectl exec -it powerdns-master-0 -- grep allow-axfr-ips /etc/powerdns/pdns.conf

# 3. Manually trigger zone transfer
rndc -c /etc/rndc.conf -s ns1.de.local notify acme.com.

# 4. Verify zone on slave
dig @ns2.external.com acme.com SOA

# 5. Check if slave can reach master (network issue)
ssh ns2.external.com "dig @ns1.de.local acme.com SOA"
```

### Issue: RNDC Command Fails (PHASE 2+)

```bash
# 1. Check RNDC key exists
cat /etc/rndc.conf | grep -A3 "key \"rndc-key\""

# 2. Verify remote RNDC connectivity
rndc -c /etc/rndc.conf -s ns1.fr.local status

# 3. Check firewall (port 953 open between regions)
nc -zv ns1.fr.local 953

# 4. Verify RNDC key is same in all regions
diff /etc/rndc.conf /etc/rndc.conf.backup

# 5. Restart PowerDNS on remote region
# (If RNDC key was changed)
kubectl delete pod -l app=powerdns-master --context=strasbourg
```

### Issue: Zone Creation Blocked in Secondary Region (PHASE 2+)

```bash
# 1. Verify customer region
curl -s -H "Authorization: Bearer $TOKEN" \
  http://api.strasbourg.com/api/v1/clients/customer_001 | jq '.region'
# Should return "frankfurt" if customer is in Frankfurt

# 2. Customer must edit DNS in their region (Frankfurt)
# Error response should be:
{
  "error": "Forbidden",
  "message": "Cannot edit DNS for customers in other regions",
  "customerRegion": "frankfurt",
  "requestRegion": "strasbourg"
}

# 3. To migrate customer to Strasbourg:
POST /api/v1/clients/customer_001/migrate-region
{
  "target_region": "strasbourg"
}
```

---

## Related Documents

- [`./DISPERSED_DNS_ARCHITECTURE.md`](./DISPERSED_DNS_ARCHITECTURE.md) — Comprehensive DNS architecture (single + multi-region)
- [`./DNS_MODE_SELECTION.md`](./DNS_MODE_SELECTION.md) — Customer DNS mode guide (Primary/CNAME/Secondary)
- [`../04-deployment/MANAGEMENT_API_SPEC.md`](../04-deployment/MANAGEMENT_API_SPEC.md) — API endpoints for zone management
- [`../03-security/SECURITY_ARCHITECTURE.md`](../03-security/SECURITY_ARCHITECTURE.md) — DNS security and DNSSEC

---

**Status:** Updated for single-master + multi-region architecture  
**Estimated Development Time:**
- PHASE 1: 4 weeks (single region + external slaves)
- PHASE 2: 6 weeks (multi-region + RNDC replication)

**Next Phase:** Implement Management API with PowerDNS integration
