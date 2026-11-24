# Runs on the L1 host (Ansible role `kubernetes`), against the L1 Proxmox API.
terraform {
  required_version = ">= 1.6"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.123"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.12"
    }
  }
}

provider "proxmox" {
  endpoint = var.proxmox_endpoint
  username = "root@pam"
  password = var.proxmox_password
  insecure = true # Proxmox's self-signed certificate, reached on localhost
}
