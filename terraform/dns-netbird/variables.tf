variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "ns1_server_type" {
  description = "Hetzner server type for ns1 (Falkenstein)"
  type        = string
  default     = "cx22"  # 2 vCPU, 4GB RAM — sufficient for DNS + NetBird
}

variable "ns2_server_type" {
  description = "Hetzner server type for ns2 (Helsinki)"
  type        = string
  default     = "cx22"
}

variable "admin_ssh_ips" {
  description = "CIDR blocks allowed to SSH into DNS servers"
  type        = list(string)
  default     = []  # Fill in via tfvars — never leave open to 0.0.0.0/0
}
