# Terraform: DNS / NetBird VPS

> **Status:** Placeholder — servers are already provisioned.  
> This module is reserved for reprovisioning or replacing ns1/ns2 from scratch if ever needed.

The ns1 (Falkenstein) and ns2 (Helsinki) servers are currently managed via **Ansible** (`ansible/`).

Use this Terraform module if you need to:
- Reprovision either server from scratch
- Add a third nameserver
- Automate firewall rules via Hetzner API

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Fill in hcloud_token and server IPs
terraform init
terraform plan
terraform apply
```
