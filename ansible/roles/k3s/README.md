# k3s Role

> **Status:** COMPLETE — Ready for deployment  
> **Target:** admin1 and future platform servers ONLY  
> **Purpose:** Kubernetes cluster for Management API, Admin/Client Panels, platform workloads

## Overview

This role deploys k3s (lightweight Kubernetes) on admin1 and future platform servers for hosting:
- Management API (backend)
- Admin Panel (frontend)
- Client Panel (frontend)
- Platform services (monitoring, logging, etc.)

**NOT for customer workloads** — Customer workloads will be deployed separately in Phase 2+.

**Key features:**
- ✅ k3s v1.29.2 (stable Kubernetes)
- ✅ Single-node mode (admin1 only in Phase 1)
- ✅ Disabled unnecessary components (Traefik, ServiceLB, local-storage)
- ✅ Secrets encryption enabled
- ✅ Network policy support
- ✅ Remote kubeconfig for management

## Architecture

```
Phase 1 (Current):
admin1 (46.224.122.58):
├── k3s server (control plane + worker)
├── containerd (container runtime)
├── Workloads:
│   ├── Management API (Node.js + Fastify)
│   ├── Admin Panel (React + Vite)
│   ├── Client Panel (React + Vite)
│   └── Platform services (Prometheus, Grafana, etc.)
└── Kubeconfig: /etc/rancher/k3s/k3s.yaml

Phase 2+ (Future):
admin1: k3s server (control plane + worker)
platform2: k3s server (control plane + worker)
platform3: k3s server (control plane + worker)
└── HA cluster with external etcd or embedded etcd (3+ nodes)
```

## Disabled Components

k3s includes several built-in components that we disable in favor of platform-specific alternatives:

| Component | Disabled? | Replacement | Reason |
|-----------|-----------|-------------|--------|
| **Traefik** | ✅ Yes | Custom ingress controller | Platform-specific routing requirements |
| **ServiceLB** | ✅ Yes | MetalLB | Better load balancer for bare-metal |
| **Local-storage** | ✅ Yes | Longhorn | Distributed storage with replication |
| **Metrics-server** | ❌ No | (Keep built-in) | Required for HPA and resource metrics |

## Network Configuration

```yaml
Pod network (cluster-cidr): 10.42.0.0/16
Service network (service-cidr): 10.43.0.0/16
CoreDNS (cluster-dns): 10.43.0.10
Flannel backend: vxlan
Network policy: Enabled
```

## Requirements

- Debian 13 (trixie)
- 4GB RAM minimum (8GB recommended)
- 40GB disk space minimum
- Docker CE installed (via `common` role)

## Role Variables

### Required Variables

Set in `group_vars/all.yml`:

```yaml
platform_domain: phoenix-host.net
netbird_ip: "100.64.0.3"  # admin1 NetBird IP
```

### Default Variables

See `defaults/main.yml` for all options.

**Key defaults:**
- `k3s_version: "v1.29.2+k3s1"`
- `k3s_server_enabled: true`
- `k3s_cluster_cidr: "10.42.0.0/16"`
- `k3s_service_cidr: "10.43.0.0/16"`
- `k3s_secrets_encryption: true`

## Dependencies

- `common` role — Docker CE, firewall

## Example Playbook

```yaml
- name: Deploy k3s on admin1
  hosts: admin1
  roles:
    - k3s
```

## Deployment

```bash
cd /config/hosting-platform/ansible

# Deploy to admin1
ansible-playbook site.yml --limit admin1 --tags k3s
```

## Post-Deployment

### Verify k3s Installation

```bash
# SSH to admin1
ssh -i ~/phoenix-host.key root@46.224.122.58

# Check k3s service
systemctl status k3s

# Check nodes
kubectl get nodes
# Expected: admin1 Ready control-plane,master

# Check system pods
kubectl get pods -A
# Expected: CoreDNS, metrics-server pods running
```

### Access Cluster Locally

```bash
# On admin1
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes
kubectl cluster-info
```

### Access Cluster Remotely

```bash
# From workstation (connected to NetBird mesh)
scp root@100.64.0.3:/etc/rancher/k3s/k3s-remote.yaml ~/.kube/config-phoenix

# Use kubeconfig
export KUBECONFIG=~/.kube/config-phoenix
kubectl get nodes
```

**Or** edit `k3s-remote.yaml` and replace server IP with NetBird IP:

```yaml
# Change this:
server: https://46.224.122.58:6443

# To this:
server: https://100.64.0.3:6443
```

### Deploy First Workload

```bash
# Create namespace
kubectl create namespace management-api

# Deploy test pod
kubectl run nginx --image=nginx --namespace=management-api

# Verify
kubectl get pods -n management-api
```

## Firewall Ports

k3s uses the following ports:

| Port | Protocol | Service | Access |
|------|----------|---------|--------|
| 6443 | TCP | Kubernetes API | NetBird mesh + localhost |
| 10250 | TCP | Kubelet API | localhost only |
| 2379-2380 | TCP | etcd (embedded) | localhost only |

**Note:** API server is accessible via NetBird mesh for remote kubectl access.

## Upgrading k3s

```bash
# Update version in defaults/main.yml
k3s_version: "v1.30.0+k3s1"

# Re-run Ansible
ansible-playbook site.yml --limit admin1 --tags k3s

# Or manually
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.30.0+k3s1 sh -

# Verify
kubectl version
```

## Adding Worker Nodes (Phase 2+)

When adding additional platform servers:

1. **Get k3s token from admin1:**
```bash
cat /etc/rancher/k3s/.token
```

2. **Add to host_vars/platform2.yml:**
```yaml
k3s_server_enabled: false
k3s_agent_enabled: true
k3s_token: "<token-from-admin1>"
```

3. **Deploy k3s agent:**
```bash
ansible-playbook site.yml --limit platform2 --tags k3s
```

## High Availability (Phase 2+)

For HA k3s cluster (3+ servers):

1. **Deploy external datastore (PostgreSQL or etcd):**
```yaml
k3s_ha_mode: true
k3s_datastore_endpoint: "postgres://user:pass@host:5432/k3s"
```

2. **Deploy k3s on all control plane nodes:**
```bash
ansible-playbook site.yml --limit k3s_servers --tags k3s
```

## Troubleshooting

### k3s service not starting

```bash
# Check logs
journalctl -u k3s -f

# Common issues:
# - Port 6443 already in use
# - Insufficient memory
# - Config file syntax error

# Check config
cat /etc/rancher/k3s/config.yaml
```

### kubectl commands failing

```bash
# Verify kubeconfig
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl cluster-info

# Check API server
curl -k https://localhost:6443/healthz
```

### Pods not starting

```bash
# Check pod status
kubectl get pods -A

# Check pod logs
kubectl logs <pod-name> -n <namespace>

# Check events
kubectl get events -A --sort-by=.metadata.creationTimestamp
```

### Network issues

```bash
# Check Flannel
kubectl get pods -n kube-system | grep flannel

# Check CoreDNS
kubectl get pods -n kube-system | grep coredns

# Test DNS resolution
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup kubernetes.default
```

## Monitoring k3s

```bash
# Node resources
kubectl top nodes

# Pod resources
kubectl top pods -A

# Cluster info
kubectl cluster-info
kubectl get componentstatuses

# System pods
kubectl get pods -n kube-system
```

## Backup and Restore

k3s etcd backups are included in the `backup` role:

```yaml
# In host_vars/admin1.yml
admin1_backup_paths:
  - /etc/rancher/k3s     # k3s configuration
  - /var/lib/rancher/k3s # k3s data (etcd, containers)
```

**Manual backup:**

```bash
# Backup etcd
k3s etcd-snapshot save --name manual-backup

# List snapshots
k3s etcd-snapshot ls

# Restore from snapshot
k3s server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/manual-backup
```

## Security Notes

1. **Secrets encryption:** Enabled by default (AES-CBC encryption)
2. **Network policy:** Enabled (use NetworkPolicy resources to restrict traffic)
3. **RBAC:** Enabled by default (use Role/ClusterRole for access control)
4. **API access:** Restricted to NetBird mesh for remote access
5. **Pod security:** Use PodSecurityAdmission or PodSecurityPolicy

## Performance Tuning

For production workloads:

```yaml
# In defaults/main.yml
k3s_kubelet_args:
  - "--max-pods=250"
  - "--kube-reserved=cpu=1000m,memory=2Gi"
  - "--system-reserved=cpu=1000m,memory=2Gi"
  - "--eviction-hard=memory.available<500Mi"
```

## License

Proprietary — Phoenix Host internal infrastructure

## Author

Phoenix Host Platform Team
