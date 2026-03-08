terraform {
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.47"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

# -----------------------------------------------------------------------
# NOTE: ns1 and ns2 are already provisioned.
# This file is a scaffold for future reprovisioning or expansion.
# Uncomment and adapt the resources below when needed.
# -----------------------------------------------------------------------

# resource "hcloud_server" "ns1" {
#   name        = "ns1"
#   server_type = var.ns1_server_type
#   image       = "debian-12"
#   location    = "nbg1"  # Falkenstein
#   ssh_keys    = [hcloud_ssh_key.platform.id]
#   labels = {
#     role   = "dns-netbird"
#     region = "de"
#   }
# }

# resource "hcloud_server" "ns2" {
#   name        = "ns2"
#   server_type = var.ns2_server_type
#   image       = "debian-12"
#   location    = "hel1"  # Helsinki
#   ssh_keys    = [hcloud_ssh_key.platform.id]
#   labels = {
#     role   = "dns-netbird-peer"
#     region = "fi"
#   }
# }

# resource "hcloud_firewall" "dns" {
#   name = "dns-server"
#
#   rule {
#     direction = "in"
#     protocol  = "tcp"
#     port      = "22"
#     source_ips = var.admin_ssh_ips
#   }
#   rule {
#     direction  = "in"
#     protocol   = "udp"
#     port       = "53"
#     source_ips = ["0.0.0.0/0", "::/0"]
#   }
#   rule {
#     direction  = "in"
#     protocol   = "tcp"
#     port       = "53"
#     source_ips = ["0.0.0.0/0", "::/0"]
#   }
#   # NetBird / WireGuard
#   rule {
#     direction  = "in"
#     protocol   = "udp"
#     port       = "51820"
#     source_ips = ["0.0.0.0/0", "::/0"]
#   }
# }
