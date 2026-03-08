# Dispersed DNS Architecture (Single + Multi-Region Strategy)

**Document Version:** 1.0  
**Last Updated:** 2026-03-01  
**Status:** FINAL — Ready for implementation  
**Audience:** DevOps engineers, platform architects, DNS administrators

---

## Overview

This document specifies the DNS architecture for the Kubernetes web hosting platform, supporting both current (single-region) and future (multi-region) deployments.

### Core Strategy

**One PowerDNS master per region, hosted on control plane.** Secondary regions receive read-only zone replicas via AXFR/RNDC. Customer's primary region (where hosted) is the authoritative DNS master and only region that can edit DNS records via the admin panel.

### Key Properties

- **Simple:** One master per region, not multi-master replication
- **Clear Authority:** Customer's primary region owns DNS changes
- **Proven Protocols:** AXFR (zone transfer) and RNDC (remote management)
- **Scalable:** Works identically in single and multi-region deployments
- **Optional Redundancy:** External slave DNS servers optionally configured per region via RNDC

---

## PHASE 1: Single Region Deployment (Current)

### Architecture

```
Frankfurt Cluster (Control Plane)
├── Kubernetes Control Plane Node
│   └── PowerDNS Master Pod
│       └── ns1.de.local (Port 53, RNDC 953)
│
├── PostgreSQL (shared, read-write by ns1)
│   └── pdns schema (zones, records, domainmetadata)
│
└── Customer Domains
    └── Example: acme.com (hosted in Frankfurt)
        └── Primary Master: ns1.de.local
        └── Secondary Slaves: ns2.external.com, ns3.external.com (optional)

External Slave DNS Servers (Already In Place)
├── ns2.external.com (separate VM, pulls zones via AXFR)
├── ns3.external.com (separate VM, pulls zones via AXFR)
└── nsN.external.com (optional, admin-configurable via RNDC)
```

### Zone Management

**API Writes:**
- All DNS changes → `ns1.de.local` (via PowerDNS API)
- Management API endpoints accept zone edits
- Records written to PostgreSQL → PowerDNS syncs

**Zone Replication:**
- External slaves pull zones from `ns1.de.local` via AXFR (automatic, every 5 minutes)
- Nameservers returned to customers:
  - `ns1.de.local` (primary master, internal k8s)
  - `ns2.external.com` (external slave, optional)
  - `ns3.external.com` (external slave, optional)
  - `nsN.external.com` (additional external slaves, optional)

**External Slave Configuration:**
```bash
# Admin configures via Management API
PUT /api/v1/settings/dns/external-slaves
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

# RNDC applies configuration to ns1.de.local
# PowerDNS begins AXFR transfers to configured slaves
```

### Failure Scenarios (Single Region)

| Scenario | Impact | Recovery |
|----------|--------|----------|
| **ns1.de.local pod crashes** | All DNS operations fail (no writes) | Kubernetes restarts pod (< 1 minute RTO) |
| **ns1.de.local node fails** | Pod evicted, rescheduled to healthy node (< 2 minutes) | Automatic k8s reschedule |
| **External slave down** | Customers' extra nameservers offline, but primary still works | Restart external slave |
| **PostgreSQL down** | ns1.de.local cannot serve zones | Restore PostgreSQL from backup |
| **Entire Frankfurt region down** | Complete outage (no HA in single region) | Failover to secondary region (once deployed) |

---

## PHASE 2+: Multi-Region Deployment (Future)

### Architecture

```
Frankfurt (Primary Region)       Strasbourg (Primary Region)      Ashburn (Primary Region)
└── Control Plane                └── Control Plane                 └── Control Plane
    ├── ns1.de.local (MASTER)    ├── ns1.fr.local (MASTER)        ├── ns1.us.local (MASTER)
    │   ├── API writes (all.de)  │   ├── API writes (all.fr)      │   ├── API writes (all.us)
    │   └── RNDC listen          │   └── RNDC listen              │   └── RNDC listen
    │                            │                                │
    └── PostgreSQL (primary)     └── PostgreSQL (replica)         └── PostgreSQL (replica)
        ├── Customers: acme.com  │   Customers: corp.fr, srv.be   │   Customers: fast.us, io.us
        ├── (master for zones)   │   (AXFR pulls from Frankfurt)  │   (AXFR pulls from Frankfurt)
        └── Replicates to: all   │                                │
           regions via pglogical │

Zone Replication Flow:
ns1.de.local (MASTER)
    ├─ AXFR/RNDC to ns1.fr.local (SLAVE, bidirectional RNDC link)
    ├─ AXFR/RNDC to ns1.us.local (SLAVE, bidirectional RNDC link)
    └─ AXFR/RNDC to external slaves (optional, all regions)
```

### Zone Assignment by Customer Region

Each customer domain is managed by their **primary region** (where customer is hosted):

```
Customer: acme.com (hosted in Frankfurt)
├── Primary Master: ns1.de.local (Frankfurt) ← CAN EDIT
├── Secondary Slaves:
│   ├── ns1.fr.local (Strasbourg, read-only)
│   ├── ns1.us.local (Ashburn, read-only)
│   └── ns1.sg.local (Singapore, read-only)
└── Nameservers returned: ns1.de.local, ns1.fr.local, ns1.us.local, ns1.sg.local

Customer: corp.fr (hosted in Strasbourg)
├── Primary Master: ns1.fr.local (Strasbourg) ← CAN EDIT
├── Secondary Slaves:
│   ├── ns1.de.local (Frankfurt, read-only)
│   ├── ns1.us.local (Ashburn, read-only)
│   └── ns1.sg.local (Singapore, read-only)
└── Nameservers returned: ns1.fr.local, ns1.de.local, ns1.us.local, ns1.sg.local
```

### Zone Management: Full CRUD Access in Primary Region

**DNS Record Types Fully Editable:**
- A, AAAA (IP addresses)
- CNAME (aliases)
- MX (mail servers)
- TXT (text records for SPF, DKIM, etc.)
- NS (nameservers for subdomains)
- SRV (service records)
- And all other standard DNS record types

**Customer Access (Full CRUD):**
- **Can edit:** All DNS records for their own domains
- **Scope:** Only in their primary region (where they're hosted)
- **Examples:**
  - Add A record for www.acme.com → 1.2.3.4
  - Update MX record for email routing
  - Add DKIM records for email signing
  - Create CNAME for subdomains
  - Delete old records

**Admin Access (Full CRUD):**
- **Can edit:** All DNS records for any customer's domains (in primary region)
- **Scope:** Only customers in their region
- **Additional capability:** Can edit in non-primary regions (read-only view only)

**API Writes (Primary Region Only):**
```
Customer in Frankfurt edits acme.com DNS
  ↓
Request → ns1.de.local API (read-write)
  ↓
Record created/updated/deleted in PostgreSQL
  ↓
Zone updated on ns1.de.local (primary master)
  ↓
AXFR replication → ns1.fr.local, ns1.us.local, ns1.sg.local (read-only)
```

**Cross-Region Editing Blocked (Secondary Region):**
- Customer in Frankfurt tries to edit from Strasbourg admin panel
- System checks: Customer region = Frankfurt, Request region = Strasbourg
- Error 403 Forbidden with message: "Cannot edit DNS for customers in other regions"

```javascript
// Management API validation (PHASE 2+)
if (customerPrimaryRegion !== requestRegion) {
  return 403 {
    "error": "Forbidden",
    "message": "Cannot edit DNS for customers in other regions",
    "details": {
      "customerRegion": "frankfurt",
      "requestRegion": "strasbourg",
      "hint": "Customer is hosted in frankfurt. Log in to frankfurt admin panel to edit DNS."
    }
  };
}
```

**Zone Replication:**
1. Admin edits record in ns1.de.local (Frankfurt master)
2. Record written to Frankfurt PostgreSQL
3. PostgreSQL replicates to Strasbourg, Ashburn, Singapore (pglogical, < 1 second)
4. `ns1.fr.local`, `ns1.us.local`, `ns1.sg.local` pull zone via AXFR (happens within 5 minutes)
5. All regions' nameservers now serve updated zone (read-only in non-primary regions)

**Inter-Region RNDC Communication:**
```bash
# ns1.de.local has RNDC key shared with ns1.fr.local, ns1.us.local, ns1.sg.local
# Allows bi-directional zone transfers

# Frankfurt to Strasbourg
rndc -c /etc/rndc.conf -s ns1.fr.local reload

# Strasbourg to Frankfurt (if needed for troubleshooting)
rndc -c /etc/rndc.conf -s ns1.de.local reload
```

### Multi-Region Failure Scenarios

| Scenario | Impact | Recovery |
|----------|--------|----------|
| **ns1.de.local down** | Frankfurt customers: cannot edit DNS; zones still served by ns1.fr.local (cached) | Kubernetes restarts pod |
| **Frankfurt region down** | Frankfurt customers fail completely; other regions unaffected | Failover to secondary region |
| **ns1.fr.local down** | Strasbourg customers cannot edit DNS; zones cached in other regions | Kubernetes restarts pod |
| **PostgreSQL replication breaks** | New zones don't replicate; existing zones converge slowly (via AXFR) | Restart replication manually |
| **All masters down** | All DNS fails (external slaves have cached zones, but no updates) | Manual recovery from backup |

### Gradual Multi-Region Rollout

**PHASE 2a (Add Strasbourg):**
1. Deploy Kubernetes cluster in Strasbourg
2. Deploy PostgreSQL replica in Strasbourg (read-only)
3. Deploy `ns1.fr.local` PowerDNS master
4. Configure RNDC between Frankfurt and Strasbourg
5. Test zone replication (AXFR from Frankfurt → Strasbourg)
6. Migrate first customers from Frankfurt → Strasbourg
7. Update nameservers for migrated customers

**PHASE 2b (Add Ashburn):**
- Repeat PHASE 2a process
- Customer migration now has 3 options: Frankfurt → Strasbourg, Frankfurt → Ashburn, Strasbourg → Ashburn

**PHASE 2c (Add Singapore):**
- Repeat PHASE 2a process
- Full geographic redundancy achieved

---

## DNS Configuration Details

### PHASE 1: Single Region Master

**PowerDNS Configuration (ns1.de.local):**
```ini
# /etc/powerdns/pdns.conf

[General]
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

[Database Backend - PostgreSQL]
launch=gpgsql
gpgsql-host=postgres.k8s.local
gpgsql-port=5432
gpgsql-user=pdns
gpgsql-password=PDNS_DB_PASSWORD
gpgsql-dbname=powerdns
gpgsql-dnssec=yes

[AXFR - Zone Transfer to External Slaves]
notify-host=ns2.external.com
notify-host=ns3.external.com
allow-axfr-ips=ns2.external.com,ns3.external.com
allow-unsigned-axfr=no
axfr-master-only=yes

[Performance]
recursive-cache-ttl=10
query-cache-ttl=20
cache-ttl=20
dname-processing=yes

[RNDC - Remote Management]
local-port=953
```

**RNDC Configuration (ns1.de.local):**
```bash
# /etc/rndc.conf

key "rndc-key" {
  algorithm hmac-sha256;
  secret "base64_encoded_secret_key";
};

options {
  default-key "rndc-key";
  default-server 127.0.0.1;
  default-port 953;
};

server 127.0.0.1 {
  key "rndc-key";
};

# For remote RNDC access (PHASE 2+)
server ns1.fr.local {
  key "rndc-key";
};

server ns1.us.local {
  key "rndc-key";
};
```

### PHASE 2: Multi-Region Master Configuration

**PowerDNS Configuration (ns1.fr.local in Strasbourg):**
```ini
# /etc/powerdns/pdns.conf

[General]
master=yes
slave=yes
primary=yes
dnssec=yes
api=yes
api-key=SECURE_API_KEY_PHASE2_STRASBOURG
api-readonly=no
webserver=yes
webserver-port=8081
webserver-address=0.0.0.0

[Database Backend - PostgreSQL]
launch=gpgsql
gpgsql-host=postgres-replica.fr.local
gpgsql-port=5432
gpgsql-user=pdns_replica
gpgsql-password=PDNS_REPLICA_PASSWORD
gpgsql-dbname=powerdns
gpgsql-dnssec=yes

[Supermaster Configuration - Replication from Frankfurt]
# Strasbourg pulls zones from Frankfurt master
supermaster=ns1.de.local|ALLOW_AXFR

[AXFR - Zone Transfer to External Slaves]
notify-host=ns2.external.com
notify-host=ns3.external.com
allow-axfr-ips=ns1.de.local,ns1.us.local,ns1.sg.local,ns2.external.com,ns3.external.com
allow-unsigned-axfr=no
axfr-master-only=yes

[RNDC - Remote Management]
local-port=953
```

**Inter-Region RNDC Key Sharing:**
```bash
# Generate RNDC key (once, in Frankfurt)
rndc-confgen -a -b 512

# Copy /etc/rndc.key to all regions' PowerDNS masters
# All regions use same RNDC key for bi-directional communication
```

---

## DNSSEC Support (Optional Per Domain)

### Overview

DNSSEC (DNS Security Extensions) cryptographically signs DNS records to prevent spoofing and cache poisoning. Support is **optional per domain** and can be enabled/disabled by customers or admins.

### DNSSEC Components

**Key Signing Key (KSK):**
- Higher-level key (typically 2048-4096 bits)
- Signs the Zone Signing Keys
- DS record published in parent zone
- Rotated every 1-2 years

**Zone Signing Key (ZSK):**
- Signs the actual DNS records
- Typical strength: 1024-2048 bits
- Rotated every 1-3 months
- Easier to rotate than KSK

**Records Added by DNSSEC:**
- **DNSKEY** — Public keys for zone signing
- **RRSIG** — Signatures for resource record sets
- **DS** — Delegation signer (for parent zone)
- **NSEC3** — Authenticated denial of existence

### Enable DNSSEC for Domain

**Customer or Admin enabling DNSSEC:**

```http
POST /api/v1/customers/{customerId}/domains/{domain}/dnssec/enable HTTP/1.1
Host: api.platform.com
Authorization: Bearer USER_TOKEN
Content-Type: application/json

{
  "algorithm": "ECDSAP256SHA256",  // or RSASHA256, RSASHA512, etc.
  "ksk_bits": 2048,
  "zsk_bits": 1024
}
```

**Response:**
```json
{
  "status": "enabled",
  "zone": "acme.com.",
  "dnssec_enabled": true,
  "keys": {
    "ksk": {
      "id": "12345",
      "algorithm": "ECDSAP256SHA256",
      "bits": 2048,
      "created_at": "2026-03-01T10:00:00Z",
      "next_rotation": "2027-03-01T10:00:00Z"
    },
    "zsk": {
      "id": "12346",
      "algorithm": "ECDSAP256SHA256",
      "bits": 1024,
      "created_at": "2026-03-01T10:00:00Z",
      "next_rotation": "2026-06-01T10:00:00Z"
    }
  },
  "ds_records": [
    {
      "keytag": "12345",
      "algorithm": "ECDSAP256SHA256",
      "digest_type": "SHA256",
      "digest": "ABC123DEF456...",
      "instruction": "Add this DS record to parent zone (your domain registrar)"
    }
  ]
}
```

### Get DNSSEC Status

**Customer or Admin checking DNSSEC status:**

```http
GET /api/v1/customers/{customerId}/domains/{domain}/dnssec HTTP/1.1
Host: api.platform.com
Authorization: Bearer USER_TOKEN
```

**Response:**
```json
{
  "zone": "acme.com.",
  "dnssec_enabled": true,
  "dnssec_valid": true,
  "status": "active",
  "ksk": {
    "id": "12345",
    "algorithm": "ECDSAP256SHA256",
    "bits": 2048,
    "created_at": "2026-03-01T10:00:00Z",
    "next_rotation": "2027-03-01T10:00:00Z",
    "days_until_rotation": 365
  },
  "zsk": {
    "id": "12346",
    "algorithm": "ECDSAP256SHA256",
    "bits": 1024,
    "created_at": "2026-03-01T10:00:00Z",
    "next_rotation": "2026-06-01T10:00:00Z",
    "days_until_rotation": 92
  },
  "ds_records": [
    {
      "keytag": "12345",
      "algorithm": "ECDSAP256SHA256",
      "digest_type": "SHA256",
      "digest": "ABC123DEF456...",
      "status": "published"  // or "pending", "not_published"
    }
  ],
  "dnssec_validation": {
    "dnskey_valid": true,
    "signatures_valid": true,
    "ds_chain_valid": true,
    "validated_at": "2026-03-01T10:05:00Z"
  }
}
```

### Rotate Keys

**Admin or automatic rotation:**

```http
POST /api/v1/customers/{customerId}/domains/{domain}/dnssec/rotate-zsk HTTP/1.1
Host: api.platform.com
Authorization: Bearer ADMIN_TOKEN
```

**Response:**
```json
{
  "status": "rotating",
  "rotation_type": "ZSK",
  "old_key_id": "12346",
  "new_key_id": "12347",
  "rotation_phase": "pre-publish",  // pre-publish → publish → activate → remove
  "estimated_completion": "2026-03-02T10:00:00Z"
}
```

### Disable DNSSEC

**Customer or Admin disabling DNSSEC:**

```http
POST /api/v1/customers/{customerId}/domains/{domain}/dnssec/disable HTTP/1.1
Host: api.platform.com
Authorization: Bearer USER_TOKEN
```

**Response:**
```json
{
  "status": "disabled",
  "zone": "acme.com.",
  "dnssec_enabled": false,
  "message": "DNSSEC has been disabled. Remove DS record from parent zone within 24 hours."
}
```

### DNSSEC Configuration in PowerDNS

**PowerDNS automatically handles DNSSEC when enabled:**

```bash
# In pdns.conf
gpgsql-dnssec=yes                    # Enable DNSSEC support
dnssec=yes                           # Sign zones
nsec3param=1 0 1 abcd1234          # Optional: Use NSEC3 instead of NSEC

# Automatic operations (PowerDNS handles)
# 1. Generate KSK + ZSK on zone creation
# 2. Sign all records with RRSIG
# 3. Generate NSEC/NSEC3 records
# 4. Rotate ZSK automatically (every 30 days, configurable)
# 5. Rotate KSK automatically (every 1 year, configurable)
```

### DNSSEC Validation

**PHASE 2+ Multi-Region:**

When zone replicates to secondary regions:
1. Master region (Frankfurt) signs zone with KSK + ZSK
2. DNSSEC signatures replicate via AXFR to secondary regions
3. Secondary regions serve signed zone (same signatures)
4. Validating resolvers can verify chain: DS → DNSKEY → RRSIG

```bash
# Test DNSSEC validation
dig @ns1.de.local acme.com +dnssec
# Response should include RRSIG records with "ad" (authenticated data) flag

# Verify DS chain
dig @ns1.de.local acme.com DS +dnssec
# Should return DS record pointing to KSK
```

---

## API Endpoints for DNS Management

### PHASE 1 (Single Region)

```bash
# Create/Update DNS records (only in primary region)
PUT /api/v1/clients/{clientId}/domains/{domainId}/records

# List external slave servers
GET /api/v1/settings/dns/external-slaves

# Configure external slave servers
PUT /api/v1/settings/dns/external-slaves

# Check DNS propagation
GET /api/v1/clients/{clientId}/domains/{domainId}/dns-status
```

### PHASE 2+ (Multi-Region)

```bash
# Create/Update DNS records (only in primary region)
# Returns 403 if customer is in different region
PUT /api/v1/clients/{clientId}/domains/{domainId}/records

# Example error for cross-region edit:
{
  "error": "Forbidden",
  "message": "Cannot edit DNS for customers in other regions",
  "details": {
    "customerRegion": "strasbourg",
    "requestRegion": "frankfurt",
    "hint": "Log in to admin panel in strasbourg region"
  }
}

# Get zone status (works in all regions, read-only elsewhere)
GET /api/v1/clients/{clientId}/domains/{domainId}/dns-status

# Example response (read-only in non-primary region):
{
  "zone": "acme.com",
  "primaryRegion": "frankfurt",
  "isPrimary": false,
  "isReadOnly": true,
  "canEdit": false,
  "nameservers": ["ns1.de.local", "ns1.fr.local", "ns1.us.local", "ns1.sg.local"],
  "lastSyncFromPrimary": "2026-03-01T10:00:00Z",
  "message": "Zone is read-only in this region. Edit in frankfurt region."
}
```

### DNSSEC Endpoints (All Phases)

```bash
# Enable DNSSEC for domain (customer or admin, primary region only)
POST /api/v1/clients/{clientId}/domains/{domainId}/dnssec/enable
{
  "algorithm": "ECDSAP256SHA256",
  "ksk_bits": 2048,
  "zsk_bits": 1024
}

# Get DNSSEC status for domain (all regions can read)
GET /api/v1/clients/{clientId}/domains/{domainId}/dnssec

# Rotate ZSK (admin, primary region only)
POST /api/v1/clients/{clientId}/domains/{domainId}/dnssec/rotate-zsk

# Rotate KSK (admin, primary region only)
POST /api/v1/clients/{clientId}/domains/{domainId}/dnssec/rotate-ksk

# Disable DNSSEC for domain (customer or admin, primary region only)
POST /api/v1/clients/{clientId}/domains/{domainId}/dnssec/disable

# Validate DNSSEC chain (all regions, read-only)
POST /api/v1/clients/{clientId}/domains/{domainId}/dnssec/validate
```

---

## Customer-Facing Configuration

### PHASE 1: Nameserver Setup

When customer adds domain in admin panel:

```
Step 1: Select DNS mode
├── Primary (Platform manages)
├── CNAME (Customer-managed)
└── Secondary (Backup DNS)

Step 2: Platform provides nameservers
├── ns1.de.local (Primary, in Kubernetes)
├── ns2.external.com (Slave, external VM)
├── ns3.external.com (Slave, external VM)
└── "Update your domain registrar to point to these nameservers"

Step 3: Verify DNS
├── Check if customer has updated registrar
├── DNSSEC validation
└── Confirm zone is live
```

### PHASE 2+: Regional Nameserver Setup

When customer migrates or is created in new region:

```
Customer: acme.com (hosted in Frankfurt)
Nameservers:
├── ns1.de.local (Frankfurt, PRIMARY)
├── ns1.fr.local (Strasbourg, read-only slave)
├── ns1.us.local (Ashburn, read-only slave)
└── ns1.sg.local (Singapore, read-only slave)

Customer: migrated to Strasbourg
Nameservers updated to:
├── ns1.fr.local (Strasbourg, PRIMARY)
├── ns1.de.local (Frankfurt, read-only slave)
├── ns1.us.local (Ashburn, read-only slave)
└── ns1.sg.local (Singapore, read-only slave)
```

---

## Implementation Checklist

### PHASE 1: Single Region (Weeks 1-4)

- [ ] **Week 1: Infrastructure Setup**
  - [ ] Deploy PowerDNS master on Frankfurt control plane
  - [ ] Configure PostgreSQL pdns schema
  - [ ] Set up AXFR zone transfer to external slaves
  - [ ] Configure RNDC for remote management

- [ ] **Week 2: Management API**
  - [ ] Implement DNS record CRUD endpoints
  - [ ] Add zone creation/deletion endpoints
  - [ ] Implement zone verification (TXT record check)
  - [ ] Add DNS status check endpoint

- [ ] **Week 3: External Slave Configuration**
  - [ ] Implement external slave configuration API
  - [ ] Add RNDC command execution for slave updates
  - [ ] Test AXFR transfers to external slaves
  - [ ] Add monitoring/alerting for slave zone freshness

- [ ] **Week 4: Testing & Validation**
  - [ ] Integration tests: DNS record creation/update/delete
  - [ ] Test zone transfer to external slaves
  - [ ] Test DNS propagation time
  - [ ] Manual failover test: restart ns1.de.local pod
  - [ ] Performance test: 100+ domains, 1000+ records

### PHASE 2: Multi-Region (Weeks 1-6, after PHASE 1 stable)

- [ ] **Week 1: Strasbourg Infrastructure**
  - [ ] Deploy PowerDNS master on Strasbourg control plane
  - [ ] Deploy PostgreSQL replica in Strasbourg
  - [ ] Configure pglogical replication (Frankfurt ← → Strasbourg)
  - [ ] Configure RNDC bi-directional communication

- [ ] **Week 2: AXFR Replication**
  - [ ] Configure AXFR from Frankfurt → Strasbourg
  - [ ] Configure AXFR from Strasbourg → external slaves
  - [ ] Test zone replication latency (target: < 5 minutes)
  - [ ] Test zone convergence after replication break

- [ ] **Week 3: API Validation**
  - [ ] Implement region validation in DNS edit API
  - [ ] Test: Edit zone in Frankfurt works
  - [ ] Test: Edit zone from Strasbourg fails (403) for Frankfurt customers
  - [ ] Test: Edit zone for Strasbourg customers works in Strasbourg API
  - [ ] Add audit logging: who edited what zone in which region

- [ ] **Week 4: Customer Migration**
  - [ ] Implement DNS zone migration workflow
  - [ ] Test: Migrate customer from Frankfurt → Strasbourg
  - [ ] Verify: Nameservers updated (ns1.de → ns1.fr primary)
  - [ ] Verify: Old region becomes read-only slave
  - [ ] Verify: No DNS downtime during migration

- [ ] **Week 5: Multi-Region Failover**
  - [ ] Test: ns1.de.local pod down → Strasbourg takes over
  - [ ] Test: Frankfurt region down → Strasbourg customers can edit
  - [ ] Test: Replication break → zones cached, catch up on recovery
  - [ ] Test: PostgreSQL replication break → manual recovery

- [ ] **Week 6: Testing & Validation**
  - [ ] Integration tests: Multi-region DNS operations
  - [ ] Performance test: 4 regions, 1000+ domains
  - [ ] Chaos engineering: Random master failures, zone transfers
  - [ ] Load test: 100+ concurrent DNS updates across regions

---

## Monitoring & Alerting

### Key Metrics

```yaml
DNS Metrics:
  - ns1.de.local API response time (target: < 100ms)
  - ns1.de.local query response time (target: < 10ms)
  - AXFR transfer duration to external slaves (target: < 5 minutes)
  - Zone replication latency (Frankfurt → other regions)
  - PostgreSQL replication lag (target: < 1 second)
  - RNDC command execution time

Alerts:
  - PowerDNS master pod crash (critical)
  - AXFR transfer failed to external slave (warning)
  - Zone not updated in secondary region (warning, if > 10 minutes)
  - DNS query latency > 100ms (warning)
  - PostgreSQL replication lag > 5 seconds (warning)
  - RNDC key missing/invalid (critical)
```

### Grafana Dashboard

```
DNS Status Dashboard
├── PowerDNS Master Status (per region)
│   ├── API availability
│   ├── Query response time
│   ├── Zone count
│   └── Record count
├── External Slave Status
│   ├── AXFR success rate
│   ├── Zone freshness (last update)
│   └── Transfer duration
└── Replication Status (PHASE 2+)
    ├── RNDC latency (inter-region)
    ├── PostgreSQL replication lag
    └── Zone convergence rate
```

---

## Security Considerations

### AXFR Restrictions

```bash
# Only allow AXFR from known external slave IPs
allow-axfr-ips=203.0.113.10,203.0.113.11,203.0.113.12
```

### RNDC Key Management

```bash
# RNDC key (shared secret for remote management)
# MUST be:
# - Same across all regions (for bi-directional communication)
# - Rotated every 90 days
# - Stored in Sealed Secrets (Kubernetes)
# - Never logged or exposed in plaintext

# RNDC authentication: HMAC-SHA256
key "rndc-key" {
  algorithm hmac-sha256;
  secret "LONG_RANDOM_BASE64_SECRET";
};
```

### API Authentication

```bash
# Management API uses Bearer tokens
# DNS edit endpoints require:
# - Valid token
# - Customer in same region (PHASE 2+)
# - DNS edit permission in admin panel
```

### Audit Logging

```json
{
  "timestamp": "2026-03-01T10:00:00Z",
  "action": "DNS_RECORD_UPDATED",
  "user": "admin@example.com",
  "region": "frankfurt",
  "customer": "acme.com",
  "zone": "acme.com",
  "recordType": "TXT",
  "recordName": "default._domainkey.acme.com",
  "oldValue": "v=DKIM1; k=rsa; p=...",
  "newValue": "v=DKIM1; k=rsa; p=...new",
  "source": "admin_panel",
  "ipAddress": "192.0.2.100"
}
```

---

## Disaster Recovery

### Single-Region Backup & Restore

```bash
# Daily DNS zone backup (to external SFTP)
PowerDNS → Export zones (zone file format) → Offsite server (SSHFS mount)

# Restore (if PostgreSQL corrupted)
External SFTP → Zone file → PowerDNS Import → Reload zones
```

### Multi-Region Backup & Restore

```bash
# Frankfurt primary has zone master data
# Strasbourg/Ashburn/Singapore have zone replicas
# Any region can restore from Frankfurt backup

# If Frankfurt lost completely:
1. Designate Strasbourg as new primary
2. Flip PostgreSQL replication direction
3. Update customer nameservers (or use CNAME alias)
```

---

## Summary

| Aspect | PHASE 1 | PHASE 2+ |
|--------|---------|----------|
| **DNS Masters** | 1 per region (ns1.de.local) | 1 per region (all read-write) |
| **Zone Authority** | Frankfurt primary only | Customer's region (primary) |
| **External Slaves** | Optional (via RNDC) | Optional (via RNDC) |
| **API Writes** | Only in Frankfurt | Only in customer's region |
| **Zone Replication** | AXFR to external slaves | AXFR between regions + RNDC |
| **Database** | Single PostgreSQL primary | Multi-master pglogical |
| **RTO** | 1-2 minutes | 0-5 minutes |
| **RPO** | < 1 second | < 1 second |
| **Cost** | ~€30/month (1 PowerDNS) | ~€120/month (4 regions × €30) |

---

## Next Steps

1. **Deploy PHASE 1** — Single region with external slaves (4 weeks)
2. **Stabilize & monitor** — Verify DNS stability for 1-2 months
3. **Plan PHASE 2** — Identify second region based on customer demand
4. **Add Strasbourg** — Deploy multi-region with RNDC replication
5. **Scale** — Add Ashburn, Singapore as customer base grows
